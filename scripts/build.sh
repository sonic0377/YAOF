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
#   1) 构建期 repositories 仅包含官方源 + QiuSimons 受信源;
#   2) ImmortalWrt 仅作为"兜底下载源": 当包在受信源中缺失时,
#      直接下载 .apk 注入 ImageBuilder 本地受信包目录;
#   3) 不依赖 ImmortalWrt 索引签名信任链, 彻底规避 UNTRUSTED 问题。
# =============================================================================
CUSTOM_FEED_URL="${CUSTOM_FEED_URL:-https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb}"
CUSTOM_KEY_URL="${CUSTOM_KEY_URL:-https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub}"
CLEANUP_SCRIPT_URL="${CLEANUP_SCRIPT_URL:-https://raw.githubusercontent.com/QiuSimons/OpenWrt-Add/master/core/tools/clean-overlay.sh}"

IMMORTALWRT_BASE_URL="${IMMORTALWRT_BASE_URL:-https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/packages/${ARCH}}"
IMMORTALWRT_FEEDS="${IMMORTALWRT_FEEDS:-luci packages}"
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
# ImageBuilder 软件源: 仅注入受信自定义源 (ImmortalWrt 不写入 repositories)
# -----------------------------------------------------------------------------
mkdir -p "${IB_DIR}/keys"

log "Fetching custom feed signing key: ${CUSTOM_KEY_URL}"
curl -fsSL --retry 3 --retry-delay 2 "$CUSTOM_KEY_URL" -o "${IB_DIR}/keys/custom-feed.rsa.pub" || die "Failed to download custom feed signing key"

if ! grep -qxF "$CUSTOM_FEED_URL" "${IB_DIR}/repositories"; then
    sed -i "1i ${CUSTOM_FEED_URL}" "${IB_DIR}/repositories"
fi

# -----------------------------------------------------------------------------
# ImmortalWrt 兜底下载机制 (普通 HTTP, 不经过 apk 信任模型)
# -----------------------------------------------------------------------------
IMM_INDEX_CACHE="${WORK_DIR}/imm-index-cache"
IMM_KEYS_DIR="${WORK_DIR}/imm-keys"
mkdir -p "$IMM_INDEX_CACHE" "$IMM_KEYS_DIR"

imm_index() {
    local feed="$1"
    local f="${IMM_INDEX_CACHE}/${feed}.adb"
    if [ ! -s "$f" ]; then
        curl -fsSL --retry 2 --retry-delay 1 -o "$f" "${IMMORTALWRT_BASE_URL}/${feed}/packages.adb" || { rm -f "$f"; return 1; }
        # 从索引压缩包中提取签名公钥, 供最终固件信任该源使用
        local member
        for member in $(tar -tzf "$f" 2>/dev/null | grep -E '^\.SIGN.*\.(pub|pem)$' || true); do
            tar -xzOf "$f" "$member" > "${IMM_KEYS_DIR}/$(basename "$member")" 2>/dev/null || true
        done
    fi
    echo "$f"
}

imm_fetch_pkg() {
    local pkg="$1"
    local feed adb member ver file
    for feed in $IMMORTALWRT_FEEDS; do
        adb="$(imm_index "$feed" || true)"
        [ -n "$adb" ] || continue
        member="$(tar -tzf "$adb" 2>/dev/null | grep -v '^\.SIGN' | head -n 1 || true)"
        [ -n "$member" ] || continue
        ver="$(tar -xzOf "$adb" "$member" 2>/dev/null | awk -v p="$pkg" '$0=="P:"p{f=1;next} f&&/^V:/{print substr($0,3); exit} f&&/^P:/{f=0}')"
        [ -n "$ver" ] || continue
        file="${pkg}-${ver}.apk"
        if curl -fsSL --retry 2 --retry-delay 1 -o "${IB_DIR}/packages/${file}" "${IMMORTALWRT_BASE_URL}/${feed}/${file}"; then
            log "Downloaded ${file} from ImmortalWrt '${feed}' feed into local repository"
            return 0
        fi
        rm -f "${IB_DIR}/packages/${file}"
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

    # 兜底: 缺失包尝试从 ImmortalWrt 直接下载注入本地受信仓库
    if [ -n "$missing" ] && [ "$fetch_round" -lt "$MAX_FETCH_ROUNDS" ]; then
        fetched_any=0
        for pkg in $missing; do
            if imm_fetch_pkg "$pkg"; then
                fetched_any=1
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

# 将提取到的 ImmortalWrt 签名公钥与源列表写入固件 (设备端可信任并更新该源)
for kfile in "${IMM_KEYS_DIR}"/*.pub "${IMM_KEYS_DIR}"/*.pem; do
    [ -e "$kfile" ] || continue
    cp -af "$kfile" "${OVERLAY_DIR}/etc/apk/keys/"
done
if [ -s "${IMM_INDEX_CACHE}/luci.adb" ] || [ -s "${IMM_INDEX_CACHE}/packages.adb" ]; then
    : > "${OVERLAY_DIR}/etc/apk/repositories.d/immortalwrt-feeds.list"
    for feed in $IMMORTALWRT_FEEDS; do
        if [ -s "${IMM_INDEX_CACHE}/${feed}.adb" ]; then
            echo "${IMMORTALWRT_BASE_URL}/${feed}/packages.adb" >> "${OVERLAY_DIR}/etc/apk/repositories.d/immortalwrt-feeds.list"
        fi
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
