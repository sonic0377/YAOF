#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET="${1:-}"
SUBTARGET="${2:-}"
PROFILE="${3:-}"
PACKAGES_PROFILE="${4:-}"
VERSION="${5:-}"

if [ -z "$TARGET" ] || [ -z "$SUBTARGET" ] || [ -z "$PROFILE" ] || [ -z "$PACKAGES_PROFILE" ]; then
    echo "Usage: $0 <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION]" >&2
    exit 1
fi

log() {
    printf '[%s] %s\n' "$(date +'%T')" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date +'%T')" "$*" >&2
    exit 1
}

resolve_version() {
    local req="${1:-}"
    local default_major="25.12"
    if [ -z "$req" ] || [ "$req" = "latest" ]; then
        req="$default_major"
    fi

    local versions
    versions=$(curl -fsSL --retry 3 https://downloads.openwrt.org/releases/ 2>/dev/null | \
        grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?/"' | \
        sed 's/href="//;s/\///;s/"//' | sort -V || true)

    if [ -z "$versions" ]; then
        versions=$(git ls-remote --tags --refs https://github.com/openwrt/openwrt.git 2>/dev/null | awk -F'/' '{print $NF}' | sed 's/^v//' || true)
    fi

    if echo "$versions" | grep -qx "$req"; then
        echo "$req"
        return
    fi

    local matched
    local escaped_req="${req//./\\.}"
    matched=$(echo "$versions" | grep -E "^${escaped_req}\.[0-9]+" | grep -v 'rc' | sort -V | tail -n 1 || true)
    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    matched=$(echo "$versions" | grep -E "^${escaped_req}" | grep -v 'rc' | sort -V | tail -n 1 || true)
    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    echo "${req:-25.12.6}"
}

VERSION=$(resolve_version "$VERSION")
log "Using OpenWrt release: ${VERSION}"

case "$TARGET" in
    x86)
        ARCH="x86_64"
        ;;
    rockchip)
        ARCH="aarch64_generic"
        ;;
    *)
        die "Unsupported target: ${TARGET}"
        ;;
esac

# =============================================================================
# 定义软件源与工具 URL (支持通过环境变量覆盖)
# 优先级设计: QiuSimons 自定义源 > OpenWrt 官方源 > ImmortalWrt (兜底)
# =============================================================================
CUSTOM_FEED_URL="${CUSTOM_FEED_URL:-https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb}"
CUSTOM_KEY_URL="${CUSTOM_KEY_URL:-https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub}"
CLEANUP_SCRIPT_URL="${CLEANUP_SCRIPT_URL:-https://raw.githubusercontent.com/QiuSimons/OpenWrt-Add/master/core/tools/clean-overlay.sh}"

IMMORTALWRT_BASE_URL="${IMMORTALWRT_BASE_URL:-https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/packages/${ARCH}}"
IMMORTALWRT_FEEDS="${IMMORTALWRT_FEEDS:-packages luci}"
KEYRING_GIT="${KEYRING_GIT:-https://github.com/immortalwrt/keyring.git}"
# =============================================================================

WORK_DIR="${ROOT_DIR}/build_${TARGET}_${SUBTARGET}_${PROFILE}"
OUTPUT_DIR="${ROOT_DIR}/artifact"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

IB_NAME="openwrt-imagebuilder-${VERSION}-${TARGET}-${SUBTARGET}.Linux-x86_64"
IB_DIR="${WORK_DIR}/${IB_NAME}"

if [ ! -d "$IB_DIR" ]; then
    IB_ARCHIVE="${WORK_DIR}/${IB_NAME}.tar.zst"
    IB_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/${IB_NAME}.tar.zst"
    log "Downloading ImageBuilder: ${IB_URL}"
    curl -fsSL --retry 3 --retry-delay 2 "$IB_URL" -o "$IB_ARCHIVE" || die "Failed to download ImageBuilder archive"
    tar --zstd -xf "$IB_ARCHIVE" -C "$WORK_DIR"
    rm -f "$IB_ARCHIVE"
fi

# -----------------------------------------------------------------------------
# 探测 ImmortalWrt 索引文件的真实位置, 返回完整索引 URL
# -----------------------------------------------------------------------------
probe_immortalwrt_index() {
    local feed="$1"
    local candidate
    for candidate in \
        "${IMMORTALWRT_BASE_URL}/${feed}/packages.adb" \
        "${IMMORTALWRT_BASE_URL}/${feed}/APKINDEX.tar.gz"; do
        if curl -fsSL --retry 2 --retry-delay 1 -o /dev/null "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

IMMORTALWRT_REPO_URLS=""
for feed in $IMMORTALWRT_FEEDS; do
    if idx_url="$(probe_immortalwrt_index "$feed")"; then
        log "ImmortalWrt feed '${feed}' resolved to index: ${idx_url}"
        IMMORTALWRT_REPO_URLS="${IMMORTALWRT_REPO_URLS}${IMMORTALWRT_REPO_URLS:+ }${idx_url}"
    else
        log "WARNING: ImmortalWrt feed '${feed}' index not found under ${IMMORTALWRT_BASE_URL}/${feed}/ ; skipping this feed"
    fi
done

# -----------------------------------------------------------------------------
# 配置 ImageBuilder 的软件源与密钥
# -----------------------------------------------------------------------------
mkdir -p "${IB_DIR}/keys"

log "Fetching custom feed signing key: ${CUSTOM_KEY_URL}"
curl -fsSL --retry 3 --retry-delay 2 "$CUSTOM_KEY_URL" -o "${IB_DIR}/keys/custom-feed.rsa.pub" || die "Failed to download custom feed signing key"

# --- 通过浅克隆获取 ImmortalWrt 全部 APK 公钥 (不依赖 GitHub API 配额) ---
log "Fetching ImmortalWrt signing keys from official keyring repository..."
KEYRING_DIR="${WORK_DIR}/immortalwrt-keyring"
rm -rf "$KEYRING_DIR"
IMM_KEY_FILES=""
if git clone --depth 1 --quiet "$KEYRING_GIT" "$KEYRING_DIR" 2>/dev/null; then
    for keyfile in "${KEYRING_DIR}/apk/"*.pub; do
        [ -e "$keyfile" ] || continue
        kname="$(basename "$keyfile")"
        cp -f "$keyfile" "${IB_DIR}/keys/${kname}"
        log "Installed ImmortalWrt signing key: ${kname}"
        IMM_KEY_FILES="${IMM_KEY_FILES}${IMM_KEY_FILES:+ }${kname}"
    done
    rm -rf "$KEYRING_DIR"
else
    log "WARNING: Failed to clone ImmortalWrt keyring; ImmortalWrt indexes will remain UNTRUSTED"
fi

# 自定义源置于首行 (最高优先级)
if ! grep -qxF "$CUSTOM_FEED_URL" "${IB_DIR}/repositories"; then
    sed -i "1i ${CUSTOM_FEED_URL}" "${IB_DIR}/repositories"
fi

# ImmortalWrt 源追加至末行 (最低优先级, 仅作兜底: 仅当其他源均无此包时才使用)
for repo_url in $IMMORTALWRT_REPO_URLS; do
    if ! grep -qxF "$repo_url" "${IB_DIR}/repositories"; then
        printf '%s\n' "$repo_url" >> "${IB_DIR}/repositories"
    fi
done

# -----------------------------------------------------------------------------
# 配置目标固件的 Overlay 目录
# -----------------------------------------------------------------------------
OVERLAY_DIR="${WORK_DIR}/overlay"
rm -rf "$OVERLAY_DIR"
mkdir -p "$OVERLAY_DIR"

if [ -d "${ROOT_DIR}/files" ]; then
    cp -af "${ROOT_DIR}/files/." "$OVERLAY_DIR/"
fi

mkdir -p "${OVERLAY_DIR}/usr/bin"
log "Fetching cleanup utility: ${CLEANUP_SCRIPT_URL}"
curl -fsSL --retry 3 --retry-delay 2 "$CLEANUP_SCRIPT_URL" -o "${OVERLAY_DIR}/usr/bin/clean-overlay" || die "Failed to download cleanup utility"
chmod +x "${OVERLAY_DIR}/usr/bin/clean-overlay"

# 配置 APK 密钥和软件源列表以供最终固件使用
# (repositories.d 按文件名字母序加载: customfeeds < distfeeds < immortalwrt-feeds,
#  与构建期优先级保持一致)
mkdir -p "${OVERLAY_DIR}/etc/apk/keys"
cp -af "${IB_DIR}/keys/custom-feed.rsa.pub" "${OVERLAY_DIR}/etc/apk/keys/"
for kname in $IMM_KEY_FILES; do
    cp -af "${IB_DIR}/keys/${kname}" "${OVERLAY_DIR}/etc/apk/keys/"
done

mkdir -p "${OVERLAY_DIR}/etc/apk/repositories.d"
echo "$CUSTOM_FEED_URL" > "${OVERLAY_DIR}/etc/apk/repositories.d/customfeeds.list"

if [ -n "$IMMORTALWRT_REPO_URLS" ]; then
    : > "${OVERLAY_DIR}/etc/apk/repositories.d/immortalwrt-feeds.list"
    for repo_url in $IMMORTALWRT_REPO_URLS; do
        echo "$repo_url" >> "${OVERLAY_DIR}/etc/apk/repositories.d/immortalwrt-feeds.list"
    done
fi

if [ "$TARGET" = "rockchip" ]; then
    mkdir -p "${OVERLAY_DIR}/etc/apk"
    echo "aarch64_generic" >> "${OVERLAY_DIR}/etc/apk/arch"
fi

load_packages() {
    local file="$1"
    [ -f "$file" ] || die "Package profile not found: $file"
    grep -v '^[[:space:]]*#' "$file" | grep -v '^[[:space:]]*$' | tr '\n' ' '
}

PACKAGES="$(load_packages "${ROOT_DIR}/profiles/packages.common") $(load_packages "${ROOT_DIR}/profiles/${PACKAGES_PROFILE}")"
BUILD_LOG="${WORK_DIR}/build.log"
SKIPPED_PACKAGES=""
MAX_SKIP_ROUNDS=5
MAX_BUILD_RETRIES=2

build_firmware() {
    local packages="$1"
    make -C "$IB_DIR" image \
        PROFILE="$PROFILE" \
        PACKAGES="$packages" \
        FILES="$OVERLAY_DIR" \
        ROOTFS_PARTSIZE="1024" 2>&1 | tee "$BUILD_LOG"
}

missing_packages_from_log() {
    local log_file="$1"
    # apk (OpenWrt 25.x): "<pkg> (no such package):"
    sed -nE 's/^[[:space:]]*([^ ]+) \(no such package\):[[:space:]]*$/\1/p' "$log_file"
    # opkg (OpenWrt 24.x and older): "opkg_install_cmd: Cannot install package <pkg>."
    sed -nE 's/.*opkg_install_cmd: Cannot install package ([^ ]+)\.$/\1/p' "$log_file"
}

log "Assembling firmware for ${PROFILE} (${VERSION})..."
skip_round=0
retry_round=0
while :; do
    if build_firmware "$PACKAGES"; then
        break
    fi

    missing="$(missing_packages_from_log "$BUILD_LOG" | sort -u)"
    kept=""
    skipped=""
    for pkg in $PACKAGES; do
        if printf '%s\n' "$missing" | grep -qxF -- "$pkg"; then
            skipped="${skipped}${skipped:+ }${pkg}"
        else
            kept="${kept}${kept:+ }${pkg}"
        fi
    done

    if [ -z "$skipped" ]; then
        # 未检测到缺失包: 视为瞬时故障 (如 CDN 404/断流), 有限次重试
        retry_round=$((retry_round + 1))
        if [ "$retry_round" -le "$MAX_BUILD_RETRIES" ]; then
            log "WARNING: Build failed without missing packages (transient error?). Retry ${retry_round}/${MAX_BUILD_RETRIES}..."
            sleep 5
            continue
        fi
        die "Firmware build failed (no unavailable package detected). See ${BUILD_LOG}"
    fi

    skip_round=$((skip_round + 1))
    if [ "$skip_round" -gt "$MAX_SKIP_ROUNDS" ]; then
        die "Too many unavailable packages; last skipped: ${skipped}. See ${BUILD_LOG}"
    fi

    log "WARNING: Package(s) not available in repositories, skipping: ${skipped}"
    SKIPPED_PACKAGES="${SKIPPED_PACKAGES}${SKIPPED_PACKAGES:+ }${skipped}"
    PACKAGES="$kept"
done

if [ -n "$SKIPPED_PACKAGES" ]; then
    log "WARNING: Firmware built without unavailable package(s): ${SKIPPED_PACKAGES}"
fi

IB_BIN_DIR="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}"
[ -d "$IB_BIN_DIR" ] || die "Output directory not found: $IB_BIN_DIR"

DATE_STR=$(date +%Y-%m-%d)
PLATFORM_LABEL=$(echo "$PROFILE" | sed 's/^friendlyarm_nanopi-/nanopi-/; s/^generic$/x86-64/')

MATCH_PATTERN="*sysupgrade.img.gz"
if [ "$TARGET" = "x86" ]; then
    MATCH_PATTERN="*combined-efi.img.gz"
fi

find "$IB_BIN_DIR" -type f -name "$MATCH_PATTERN" | while read -r img; do
    fname=$(basename "$img")
    clean_suffix=$(echo "$fname" | sed -E "s/^openwrt-.*-${TARGET}-${SUBTARGET}-${PROFILE}-//")
    out_name="YAOF-${PLATFORM_LABEL}-${VERSION}-${DATE_STR}-${clean_suffix}"
    cp -f "$img" "${OUTPUT_DIR}/${out_name}"
    log "Saved: ${out_name}"
done

log "Build completed successfully for ${PROFILE}."
