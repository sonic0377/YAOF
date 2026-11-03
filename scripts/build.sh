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
# 软件源定义
# 设计原则:
#   1) 构建期 repositories 仅含官方源 + QiuSimons 受信源 (避免优先级劫持);
#   2) ImmortalWrt 仅作兜底: 受信源缺失时, 通过 HTTP 目录列表定位 .apk
#      并注入 ImageBuilder 本地受信包目录;
#   3) 通过浅克隆 keyring 仓库获取 ImmortalWrt 公钥, 写入固件供设备端信任校验。
# =============================================================================
CUSTOM_FEED_URL="${CUSTOM_FEED_URL:-https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb}"
CUSTOM_KEY_URL="${CUSTOM_KEY_URL:-https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub}"
CLEANUP_SCRIPT_URL="${CLEANUP_SCRIPT_URL:-https://raw.githubusercontent.com/QiuSimons/OpenWrt-Add/master/core/tools/clean-overlay.sh}"

IMMORTALWRT_BASE_URL="${IMMORTALWRT_BASE_URL:-https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/packages/${ARCH}}"
IMMORTALWRT_FEEDS="${IMMORTALWRT_FEEDS:-luci packages}"
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
# ImageBuilder 软件源: 仅注入受信自定义源
# -----------------------------------------------------------------------------
mkdir -p "${IB_DIR}/keys"

log "Fetching custom feed signing key: ${CUSTOM_KEY_URL}"
curl -fsSL --retry 3 --retry-delay 2 "$CUSTOM_KEY_URL" -o "${IB_DIR}/keys/custom-feed.rsa.pub" || die "Failed to download custom feed signing key"

if ! grep -qxF "$CUSTOM_FEED_URL" "${IB_DIR}/repositories"; then
    sed -i "1i ${CUSTOM_FEED_URL}" "${IB_DIR}/repositories"
fi

# -----------------------------------------------------------------------------
# ImmortalWrt 兜底下载机制 (基于 HTTP 目录列表, 不解析索引文件)
# -----------------------------------------------------------------------------
IMM_KEYS_DIR="${WORK_DIR}/imm-keys"
mkdir -p "$IMM_KEYS_DIR"

# --- 浅克隆官方 keyring 仓库获取全部 APK 公钥 (不受 GitHub API 限流影响) ---
log "Fetching ImmortalWrt signing keys from official keyring repository (git clone)..."
KEYRING_DIR="${WORK_DIR}/immortalwrt-keyring"
rm -rf "$KEYRING_DIR"
if git clone --depth 1 --quiet "$KEYRING_GIT" "$KEYRING_DIR" 2>/dev/null; then
    key_count=0
    for keyfile in "${KEYRING_DIR}/apk/"*.pub; do
        [ -e "$keyfile" ] || continue
        cp -f "$keyfile" "${IMM_KEYS_DIR}/$(basename "$keyfile")"
        key_count=$((key_count + 1))
    done
    rm -rf "$KEYRING_DIR"
    if [ "$key_count" -gt 0 ]; then
        log "Installed ${key_count} ImmortalWrt signing key(s) from keyring repository"
    else
        log "WARNING: No .pub keys found under apk/ in keyring repository"
    fi
else
    log "WARNING: Failed to clone ImmortalWrt keyring repository; falling back to .apk signature extraction only"
fi

# 兜底: 从注入的 .apk 签名成员中提取公钥 (若 keyring 克隆失败仍有机会获得密钥)
imm_extract_keys() {
    local apkfile="$1"
    local member
    for member in $(tar -tzf "$apkfile" 2>/dev/null | grep -E '^\.SIGN.*\.(pub|pem)$' || true); do
        tar -xzOf "$apkfile" "$member" > "${IMM_KEYS_DIR}/$(basename "$member")" 2>/dev/null || true
    done
    if [ -z "$(ls -A "$IMM_KEYS_DIR" 2>/dev/null || true)" ]; then
        for member in $(tar -t --zstd -f "$apkfile" 2>/dev/null | grep -E '^\.SIGN.*\.(pub|pem)$' || true); do
            tar -x --zstd -Of "$apkfile" "$member" > "${IMM_KEYS_DIR}/$(basename "$member")" 2>/dev/null || true
        done
    fi
}

imm_fetch_pkg() {
    local pkg="$1"
    local feed listing file
    for feed in $IMMORTALWRT_FEEDS; do
        listing="$(curl -fsSL --retry 2 --retry-delay 1 "${IMMORTALWRT_BASE_URL}/${feed}/" 2>/dev/null || true)"
        if [ -z "$listing" ]; then
            log "WARNING: Unable to list ImmortalWrt feed '${feed}' at ${IMMORTALWRT_BASE_URL}/${feed}/"
            continue
        fi
        file="$(printf '%s\n' "$listing" | grep -oE "href=\"${pkg}-[0-9][^\"]*\.apk\"" | head -n 1 | sed 's/^href="//; s/"$//' || true)"
        if [ -z "$file" ]; then
            log "WARNING: Package '${pkg}' not found in ImmortalWrt feed '${feed}'"
            continue
        fi
        if curl -fsSL --retry 2 --retry-delay 1 -o "${IB_DIR}/packages/${file}" "${IMMORTALWRT_BASE_URL}/${feed}/${file}"; then
            log "Downloaded ${file} from ImmortalWrt '${feed}' feed into local repository"
            imm_extract_keys "${IB_DIR}/packages/${file}" || true
            return 0
        fi
        rm -f "${IB_DIR}/packages/${file}"
        log "WARNING: Failed to download ${file} from ImmortalWrt feed '${feed}'"
    done
    return 1
}

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

mkdir -p "${OVERLAY_DIR}/etc/apk/keys"
cp -af "${IB_DIR}/keys/custom-feed.rsa.pub" "${OVERLAY_DIR}/etc/apk/keys/"

mkdir -p "${OVERLAY_DIR}/etc/apk/repositories.d"
echo "$CUSTOM_FEED_URL" > "${OVERLAY_DIR}/etc/apk/repositories.d/customfeeds.list"

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
IMM_PACKAGES=""
MAX_SKIP_ROUNDS=5
MAX_BUILD_RETRIES=2
MAX_FETCH_ROUNDS=3

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
fetch_round=0
while :; do
    if build_firmware "$PACKAGES"; then
        break
    fi

    missing="$(missing_packages_from_log "$BUILD_LOG" | sort -u)"

    # 兜底: 缺失包从 ImmortalWrt 目录列表定位并注入本地受信仓库
    if [ -n "$missing" ] && [ "$fetch_round" -lt "$MAX_FETCH_ROUNDS" ]; then
        fetched_any=0
        for pkg in $missing; do
            if imm_fetch_pkg "$pkg"; then
                fetched_any=1
                IMM_PACKAGES="${IMM_PACKAGES}${IMM_PACKAGES:+ }${pkg}"
            fi
        done
        if [ "$fetched_any" -eq 1 ]; then
            fetch_round=$((fetch_round + 1))
            log "Injected ImmortalWrt package(s) into local repository; rebuilding..."
            continue
        fi
    fi

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

# 将 ImmortalWrt 签名公钥写入固件 (keyring 克隆为主, .apk 签名提取为兜底)
for kfile in "${IMM_KEYS_DIR}"/*.pub "${IMM_KEYS_DIR}"/*.pem; do
    [ -e "$kfile" ] || continue
    cp -af "$kfile" "${OVERLAY_DIR}/etc/apk/keys/"
    log "Installed ImmortalWrt signing key into firmware: $(basename "$kfile")"
done

# 仅在实际注入过 ImmortalWrt 包时, 向固件写入该源列表供设备端使用
if [ -n "$IMM_PACKAGES" ]; then
    : > "${OVERLAY_DIR}/etc/apk/repositories.d/immortalwrt-feeds.list"
    for feed in $IMMORTALWRT_FEEDS; do
        echo "${IMMORTALWRT_BASE_URL}/${feed}/packages.adb" >> "${OVERLAY_DIR}/etc/apk/repositories.d/immortalwrt-feeds.list"
    done
fi

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
