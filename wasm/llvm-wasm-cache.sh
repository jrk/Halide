#!/usr/bin/env bash
#
# Cache management for LLVM wasm build artifacts.
#
# The LLVM-for-wasm build takes ~40 minutes and produces ~444MB of static
# libraries. This script packs the essential artifacts into a compressed
# tarball (~200MB) that can be saved to local disk, an HTTP server, or GCS,
# and restored in seconds on a fresh container.
#
# Usage:
#   llvm-wasm-cache.sh save    [options]   Pack and store the build artifacts
#   llvm-wasm-cache.sh restore [options]   Fetch and unpack cached artifacts
#   llvm-wasm-cache.sh key     [options]   Print the cache key (for debugging)
#
# Options:
#   --build-dir DIR       LLVM wasm build directory (required for save/restore)
#   --llvm-src DIR        LLVM source tree (for path fixup on restore)
#   --llvm-version VER    LLVM version string (e.g. "20.1.2")
#   --emsdk-version VER   Emscripten SDK version (e.g. "5.0.2")
#   --targets LIST        LLVM targets (e.g. "WebAssembly;X86" or "all")
#   --build-type TYPE     CMAKE_BUILD_TYPE (default: MinSizeRel)
#   --cache-dir DIR       Local cache directory
#   --cache-url URL       HTTP/HTTPS URL prefix (restore only)
#   --cache-gcs URI       GCS bucket URI (gs://bucket/prefix)
#   --help                Show this help
#
set -euo pipefail

log() { echo "=== [cache] $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Defaults
SUBCOMMAND=""
BUILD_DIR=""
LLVM_SRC=""
LLVM_VERSION=""
EMSDK_VERSION=""
TARGETS="all"
BUILD_TYPE="MinSizeRel"
CACHE_DIR=""
CACHE_URL=""
CACHE_GCS=""

usage() {
    head -n 28 "$0" | tail -n +3 | sed 's/^# \?//'
    exit 0
}

# Parse arguments
[[ $# -gt 0 ]] || usage
SUBCOMMAND="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir)      BUILD_DIR="$2"; shift 2 ;;
        --llvm-src)       LLVM_SRC="$2"; shift 2 ;;
        --llvm-version)   LLVM_VERSION="$2"; shift 2 ;;
        --emsdk-version)  EMSDK_VERSION="$2"; shift 2 ;;
        --targets)        TARGETS="$2"; shift 2 ;;
        --build-type)     BUILD_TYPE="$2"; shift 2 ;;
        --cache-dir)      CACHE_DIR="$2"; shift 2 ;;
        --cache-url)      CACHE_URL="$2"; shift 2 ;;
        --cache-gcs)      CACHE_GCS="$2"; shift 2 ;;
        --help|-h)        usage ;;
        *)                die "Unknown option: $1" ;;
    esac
done

# The set of cmake flags that affect the LLVM wasm build output.
# If any of these change, the cache should be invalidated.
LLVM_CMAKE_FLAGS="LLVM_ENABLE_PROJECTS=clang;lld
LLVM_BUILD_TOOLS=OFF
LLVM_BUILD_UTILS=OFF
LLVM_INCLUDE_TESTS=OFF
LLVM_INCLUDE_BENCHMARKS=OFF
LLVM_INCLUDE_EXAMPLES=OFF
LLVM_INCLUDE_DOCS=OFF
LLVM_ENABLE_TERMINFO=OFF
LLVM_ENABLE_ZLIB=OFF
LLVM_ENABLE_ZSTD=OFF
LLVM_ENABLE_LIBXML2=OFF
LLVM_ENABLE_LIBEDIT=OFF
LLVM_ENABLE_LIBPFM=OFF
LLVM_ENABLE_THREADS=OFF
LLVM_ENABLE_PIC=OFF
LLVM_ENABLE_ASSERTIONS=OFF
LLVM_ENABLE_BACKTRACES=OFF
LLVM_ENABLE_CRASH_OVERRIDES=OFF
LLVM_ENABLE_UNWIND_TABLES=OFF
BUILD_SHARED_LIBS=OFF
CLANG_BUILD_TOOLS=OFF
CLANG_INCLUDE_TESTS=OFF
CLANG_INCLUDE_DOCS=OFF"

# ============================================================================
# Cache key computation
# ============================================================================

compute_cache_key() {
    local llvm_version="${LLVM_VERSION:?--llvm-version required}"
    local emsdk_version="${EMSDK_VERSION:?--emsdk-version required}"
    local targets="${TARGETS}"
    local build_type="${BUILD_TYPE}"

    # Normalize targets: sort semicolon/comma-separated list, join with _
    local norm_targets
    norm_targets="$(echo "${targets}" | tr ';,' '\n' | sort | tr '\n' '_' | sed 's/_$//')"

    # Human-readable prefix
    local prefix="llvm-wasm-${llvm_version}-emsdk${emsdk_version}-${norm_targets}-${build_type}"

    # Hash the full cmake flags for safety (catches flag changes between versions
    # of this script)
    local flags_hash
    flags_hash="$(echo "${LLVM_CMAKE_FLAGS}" | sha256sum | cut -c1-8)"

    echo "${prefix}-${flags_hash}"
}

# ============================================================================
# Compression helpers (prefer zstd, fall back to gzip)
# ============================================================================

tarball_ext() {
    if command -v zstd >/dev/null 2>&1; then
        echo "tar.zst"
    else
        echo "tar.gz"
    fi
}

tar_compress() {
    local archive="$1"; shift
    if [[ "${archive}" == *.tar.zst ]]; then
        tar -I zstd -cf "${archive}" "$@"
    else
        tar -czf "${archive}" "$@"
    fi
}

tar_decompress() {
    local archive="$1"
    local dest="$2"
    if [[ "${archive}" == *.tar.zst ]]; then
        tar -I zstd -xf "${archive}" -C "${dest}"
    else
        tar -xzf "${archive}" -C "${dest}"
    fi
}

# ============================================================================
# Verification
# ============================================================================

verify_cache() {
    local build_dir="$1"
    local ok=true

    for f in \
        "${build_dir}/lib/libLLVMCore.a" \
        "${build_dir}/lib/libLLVMSupport.a" \
        "${build_dir}/lib/libLLVMDemangle.a"; do
        if [[ ! -f "${f}" ]]; then
            log "Verification failed: missing ${f}"
            ok=false
        fi
    done

    for d in \
        "${build_dir}/lib/cmake/llvm" \
        "${build_dir}/lib/cmake/clang" \
        "${build_dir}/include"; do
        if [[ ! -d "${d}" ]]; then
            log "Verification failed: missing ${d}"
            ok=false
        fi
    done

    if ${ok}; then
        local lib_count
        lib_count="$(find "${build_dir}/lib" -name '*.a' | wc -l)"
        log "Cache verification passed (${lib_count} static libraries)"
        return 0
    fi
    return 1
}

# ============================================================================
# Save
# ============================================================================

cmd_save() {
    [[ -n "${BUILD_DIR}" ]] || die "--build-dir required for save"
    [[ -d "${BUILD_DIR}/lib" ]] || die "No lib/ directory in ${BUILD_DIR}"
    [[ -d "${BUILD_DIR}/include" ]] || die "No include/ directory in ${BUILD_DIR}"

    local cache_key
    cache_key="$(compute_cache_key)"
    local ext
    ext="$(tarball_ext)"
    local tarball="${cache_key}.${ext}"
    local tmp_tarball="/tmp/${tarball}"

    # Resolve to absolute path for metadata
    local abs_build_dir
    abs_build_dir="$(cd "${BUILD_DIR}" && pwd)"

    # Detect the LLVM source path from the cmake config (needed for path fixup on restore)
    local llvm_src_path=""
    if [[ -f "${BUILD_DIR}/lib/cmake/llvm/LLVMConfig.cmake" ]]; then
        llvm_src_path="$(grep 'set(LLVM_INCLUDE_DIRS ' "${BUILD_DIR}/lib/cmake/llvm/LLVMConfig.cmake" \
            | grep -oE '"[^"]*llvm/include' | head -1 | sed 's|/llvm/include$||; s|^"||')"
    fi

    # Write metadata file for path fixup on restore
    cat > "${BUILD_DIR}/.cache_metadata" <<METADATA
ORIGINAL_BUILD_DIR=${abs_build_dir}
ORIGINAL_LLVM_SRC=${llvm_src_path}
METADATA

    log "Saving cache: ${cache_key}"
    log "Packing essential artifacts from ${BUILD_DIR}..."

    # Pack lib/, include/, tools/*/include/, and metadata — everything
    # Halide's cmake needs. The tools/ dirs contain generated headers for
    # clang and lld that the cmake configs reference.
    local tar_paths=(lib/ include/ .cache_metadata)
    [[ -d "${BUILD_DIR}/tools/clang/include" ]] && tar_paths+=(tools/clang/include/)
    [[ -d "${BUILD_DIR}/tools/lld/include" ]] && tar_paths+=(tools/lld/include/)
    tar_compress "${tmp_tarball}" -C "${BUILD_DIR}" "${tar_paths[@]}"

    local size
    size="$(du -h "${tmp_tarball}" | cut -f1)"
    log "Tarball created: ${tarball} (${size})"

    local saved=false

    # Save to local cache dir
    if [[ -n "${CACHE_DIR}" ]]; then
        mkdir -p "${CACHE_DIR}"
        cp "${tmp_tarball}" "${CACHE_DIR}/${tarball}"
        log "Saved to local cache: ${CACHE_DIR}/${tarball}"
        saved=true
    fi

    # Upload to GCS
    if [[ -n "${CACHE_GCS}" ]]; then
        if command -v gsutil >/dev/null 2>&1; then
            gsutil cp "${tmp_tarball}" "${CACHE_GCS}/${tarball}"
            log "Uploaded to GCS: ${CACHE_GCS}/${tarball}"
            saved=true
        else
            log "WARNING: gsutil not found, skipping GCS upload"
        fi
    fi

    rm -f "${tmp_tarball}"

    if ! ${saved}; then
        log "WARNING: No cache backend specified. Tarball was created and discarded."
        log "  Use --cache-dir or --cache-gcs to persist the cache."
    fi
}

# ============================================================================
# Restore
# ============================================================================

# ============================================================================
# Path fixup — rewrite hardcoded paths in cmake configs after restore
# ============================================================================

fixup_paths() {
    local build_dir="$1"
    local abs_build_dir
    abs_build_dir="$(cd "${build_dir}" && pwd)"

    local metadata="${build_dir}/.cache_metadata"
    if [[ ! -f "${metadata}" ]]; then
        log "No cache metadata found, skipping path fixup"
        return 0
    fi

    local orig_build_dir orig_llvm_src
    orig_build_dir="$(grep '^ORIGINAL_BUILD_DIR=' "${metadata}" | cut -d= -f2-)"
    orig_llvm_src="$(grep '^ORIGINAL_LLVM_SRC=' "${metadata}" | cut -d= -f2-)"

    # Fix build dir references if path changed
    if [[ -n "${orig_build_dir}" && "${orig_build_dir}" != "${abs_build_dir}" ]]; then
        log "Fixing up build dir paths: ${orig_build_dir} -> ${abs_build_dir}"
        find "${build_dir}/lib/cmake" -name '*.cmake' -exec \
            sed -i "s|${orig_build_dir}|${abs_build_dir}|g" {} +
    fi

    # Fix LLVM source dir references if --llvm-src was provided and path changed
    if [[ -n "${orig_llvm_src}" && -n "${LLVM_SRC}" && "${orig_llvm_src}" != "${LLVM_SRC}" ]]; then
        log "Fixing up LLVM source paths: ${orig_llvm_src} -> ${LLVM_SRC}"
        find "${build_dir}/lib/cmake" -name '*.cmake' -exec \
            sed -i "s|${orig_llvm_src}|${LLVM_SRC}|g" {} +
    fi
}

# ============================================================================
# Restore
# ============================================================================

cmd_restore() {
    [[ -n "${BUILD_DIR}" ]] || die "--build-dir required for restore"

    local cache_key
    cache_key="$(compute_cache_key)"

    # Try both compression formats
    local exts=()
    if command -v zstd >/dev/null 2>&1; then
        exts+=("tar.zst")
    fi
    exts+=("tar.gz")

    for ext in "${exts[@]}"; do
        local tarball="${cache_key}.${ext}"

        # Try local cache
        if [[ -n "${CACHE_DIR}" && -f "${CACHE_DIR}/${tarball}" ]]; then
            log "Cache hit (local): ${tarball}"
            mkdir -p "${BUILD_DIR}"
            tar_decompress "${CACHE_DIR}/${tarball}" "${BUILD_DIR}"
            fixup_paths "${BUILD_DIR}"
            if verify_cache "${BUILD_DIR}"; then
                return 0
            fi
            log "Verification failed after local restore, trying next backend..."
        fi

        # Try HTTP URL
        if [[ -n "${CACHE_URL}" ]]; then
            local url="${CACHE_URL%/}/${tarball}"
            log "Trying HTTP: ${url}"
            if curl -fsSL --retry 3 --retry-delay 2 -o "/tmp/${tarball}" "${url}" 2>/dev/null; then
                log "Cache hit (HTTP): ${tarball}"
                mkdir -p "${BUILD_DIR}"
                tar_decompress "/tmp/${tarball}" "${BUILD_DIR}"
                fixup_paths "${BUILD_DIR}"
                rm -f "/tmp/${tarball}"
                if verify_cache "${BUILD_DIR}"; then
                    return 0
                fi
                log "Verification failed after HTTP restore, trying next backend..."
            fi
        fi

        # Try GCS
        if [[ -n "${CACHE_GCS}" ]]; then
            local gcs_path="${CACHE_GCS%/}/${tarball}"
            log "Trying GCS: ${gcs_path}"
            if command -v gsutil >/dev/null 2>&1 && \
               gsutil cp "${gcs_path}" "/tmp/${tarball}" 2>/dev/null; then
                log "Cache hit (GCS): ${tarball}"
                mkdir -p "${BUILD_DIR}"
                tar_decompress "/tmp/${tarball}" "${BUILD_DIR}"
                fixup_paths "${BUILD_DIR}"
                rm -f "/tmp/${tarball}"
                if verify_cache "${BUILD_DIR}"; then
                    return 0
                fi
                log "Verification failed after GCS restore, trying next backend..."
            fi
        fi
    done

    log "Cache miss: ${cache_key}"
    return 1
}

# ============================================================================
# Key (print cache key)
# ============================================================================

cmd_key() {
    compute_cache_key
}

# ============================================================================
# Main dispatch
# ============================================================================

case "${SUBCOMMAND}" in
    save)    cmd_save ;;
    restore) cmd_restore ;;
    key)     cmd_key ;;
    --help|-h) usage ;;
    *)       die "Unknown subcommand: ${SUBCOMMAND}. Use save, restore, or key." ;;
esac
