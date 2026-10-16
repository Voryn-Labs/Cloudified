#!/bin/bash
# scripts/assemble_tdlib.sh
# Deterministic assembly script for TDLib (pinned commit 42e6a5259551178d1dab54a22ad96d14bd906e20)
# and OpenSSL 3.5.9 (pinned commit 45e844fa2a14ec92d146bd8f5778ac130b6625fb).
# Designed for the selected cloud build runner (macOS-26 / Xcode 26).
# Builds in an owned temporary directory with cleanup trap, targets iOS 26 arm64 device architecture,
# Native recipe has static review only; actual device link gate runs during P7 assembly.
# Seals the native cache per docs/BUILD-CACHE.md; a seal does not prove link correctness.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_COMMIT="42e6a5259551178d1dab54a22ad96d14bd906e20"
TD_REPO_URL="https://github.com/tdlib/td.git"

OPENSSL_PIN_COMMIT="45e844fa2a14ec92d146bd8f5778ac130b6625fb"
OPENSSL_REPO_URL="https://github.com/openssl/openssl.git"

BUILD_ROOT="${CLOUDIFIED_BUILD_ROOT:-$REPO_ROOT/build}"
OUTPUT_DIR="$BUILD_ROOT/tdlib"

echo "=== TDLib Deterministic Assembly ==="
echo "TDLib pinned commit: $PIN_COMMIT"
echo "OpenSSL pinned commit: $OPENSSL_PIN_COMMIT"
echo "Output directory: $OUTPUT_DIR"

# Require Darwin and full Xcode / toolchain
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: Assembling TDLib for iOS requires macOS with Xcode and cmake." >&2
    exit 2
fi

if ! command -v cmake >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
    echo "Error: cmake and ninja are required to assemble TDLib." >&2
    exit 2
fi

# Locate iPhoneOS SDK
IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
if [[ -z "$IPHONEOS_SDK" ]]; then
    echo "Error: iPhoneOS SDK not found. Full Xcode installation with iOS SDK is required." >&2
    exit 4
fi

# Create owned temporary workspace with automatic cleanup trap
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloudified_tdlib_build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT INT TERM

mkdir -p "$BUILD_DIR/src-td" "$BUILD_DIR/src-openssl" "$BUILD_DIR/host-td" "$BUILD_DIR/ios-td" "$BUILD_DIR/ios-openssl" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/include"

echo "1. Fetching pinned TDLib and OpenSSL sources..."
(
    cd "$BUILD_DIR/src-td"
    git init
    git remote add origin "$TD_REPO_URL"
    git fetch --depth 1 origin "$PIN_COMMIT"
    git checkout "$PIN_COMMIT"
    HEAD_COMMIT="$(git rev-parse HEAD)"
    if [[ "$HEAD_COMMIT" != "$PIN_COMMIT" ]]; then
        echo "Error: TDLib commit $HEAD_COMMIT does not match pin $PIN_COMMIT!" >&2
        exit 3
    fi
)

(
    cd "$BUILD_DIR/src-openssl"
    git init
    git remote add origin "$OPENSSL_REPO_URL"
    git fetch --depth 1 origin "$OPENSSL_PIN_COMMIT"
    git checkout "$OPENSSL_PIN_COMMIT"
    HEAD_COMMIT="$(git rev-parse HEAD)"
    if [[ "$HEAD_COMMIT" != "$OPENSSL_PIN_COMMIT" ]]; then
        echo "Error: OpenSSL commit $HEAD_COMMIT does not match pin $OPENSSL_PIN_COMMIT!" >&2
        exit 3
    fi
)

echo "2. Building iOS OpenSSL arm64..."
(
    cd "$BUILD_DIR/src-openssl"
    # Configure OpenSSL for iOS arm64 without shared libraries
    export SDKROOT="$IPHONEOS_SDK"
    ./Configure ios64-xcrun no-shared no-dso no-tests no-engine \
        --prefix="$BUILD_DIR/ios-openssl" --libdir=lib \
        -mios-version-min=26.0
    make -j "$(sysctl -n hw.ncpu || echo 4)" build_libs
    make install_dev
)

echo "3. Host code generation phase (macOS host)..."
(
    cd "$BUILD_DIR/host-td"
    cmake -GNinja "$BUILD_DIR/src-td" \
        -DCMAKE_BUILD_TYPE=Release \
        -DTD_GENERATE_SOURCE_FILES=ON
    cmake --build . --target prepare_cross_compiling -j "$(sysctl -n hw.ncpu || echo 4)"
)

echo "4. Cross-compiling TDLib for iOS arm64 (deployment 26.0)..."
OPENSSL_LIB_DIR="$BUILD_DIR/ios-openssl/lib"
if [[ ! -d "$OPENSSL_LIB_DIR" && -d "$BUILD_DIR/ios-openssl/lib64" ]]; then
    OPENSSL_LIB_DIR="$BUILD_DIR/ios-openssl/lib64"
fi
OPENSSL_CRYPTO="$OPENSSL_LIB_DIR/libcrypto.a"
OPENSSL_SSL="$OPENSSL_LIB_DIR/libssl.a"

(
    cd "$BUILD_DIR/ios-td"
    cmake -GNinja "$BUILD_DIR/src-td" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$IPHONEOS_SDK" \
        -DCMAKE_OSX_ARCHITECTURES="arm64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="26.0" \
        -DOPENSSL_ROOT_DIR="$BUILD_DIR/ios-openssl" \
        -DOPENSSL_FOUND=TRUE \
        -DZLIB_FOUND=TRUE \
        -DZLIB_LIBRARY="$IPHONEOS_SDK/usr/lib/libz.tbd" \
        -DZLIB_LIBRARIES="$IPHONEOS_SDK/usr/lib/libz.tbd" \
        -DTDUTILS_USE_EXTERNAL_DEPENDENCIES=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_Crc32c=TRUE \
        -DTD_WITH_ABSEIL=OFF \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_CRYPTO" \
        -DOPENSSL_SSL_LIBRARY="$OPENSSL_SSL" \
        -DOPENSSL_INCLUDE_DIR="$BUILD_DIR/ios-openssl/include" \
        -DOPENSSL_LIBRARIES="$OPENSSL_CRYPTO;$OPENSSL_SSL" \
        -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR" \
        -DTD_ENABLE_JNI=OFF \
        -DTD_ENABLE_DOTNET=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    cmake --build . --target tdjson_static tdjson_private tdclient tdcore tdapi tdmtproto tddb tdsqlite tdactor tdnet tdutils tde2e -j "$(sysctl -n hw.ncpu || echo 4)"
)

echo "5. Combining complete deterministic static link closure into unified libtdjson.a..."
# Exact deterministic list of required static library targets from pinned td CMake and OpenSSL 3.5.9
REQUIRED_TARGETS=(
    "libtdjson_static.a"
    "libtdjson_private.a"
    "libtdclient.a"
    "libtdcore.a"
    "libtdapi.a"
    "libtdmtproto.a"
    "libtddb.a"
    "libtdsqlite.a"
    "libtdactor.a"
    "libtdnet.a"
    "libtdutils.a"
    "libtde2e.a"
)

REQUIRED_ARCHIVES=()
for target_lib in "${REQUIRED_TARGETS[@]}"; do
    found_matches=()
    while IFS= read -r -d '' match; do
        found_matches+=("$match")
    done < <(find "$BUILD_DIR/ios-td" -name "$target_lib" -type f -print0)

    if [[ ${#found_matches[@]} -eq 0 ]]; then
        echo "Error: Required TDLib member static library $target_lib was not produced!" >&2
        exit 5
    elif [[ ${#found_matches[@]} -gt 1 ]]; then
        echo "Error: Multiple matches found for member library $target_lib: ${found_matches[*]}" >&2
        exit 5
    fi
    REQUIRED_ARCHIVES+=("${found_matches[0]}")
done

# Add OpenSSL static libraries
if [[ ! -s "$OPENSSL_CRYPTO" ]]; then
    echo "Error: Required OpenSSL crypto archive $OPENSSL_CRYPTO is missing or empty!" >&2
    exit 5
fi
if [[ ! -s "$OPENSSL_SSL" ]]; then
    echo "Error: Required OpenSSL ssl archive $OPENSSL_SSL is missing or empty!" >&2
    exit 5
fi
REQUIRED_ARCHIVES+=("$OPENSSL_CRYPTO" "$OPENSSL_SSL")

echo "Deterministic static link closure members (${#REQUIRED_ARCHIVES[@]} total):"
for arch in "${REQUIRED_ARCHIVES[@]}"; do
    if [[ ! -s "$arch" ]]; then
        echo "Error: Archive member $arch is empty or missing!" >&2
        exit 5
    fi
    if [[ "$(xcrun lipo -archs "$arch")" != "arm64" ]]; then
        echo "Error: Archive member $arch does not target arm64 architecture!" >&2
        exit 6
    fi
    echo "  - $(basename "$arch") [arm64]"
done

# Combine exactly the deterministic 14-archive closure into unified libtdjson.a
libtool -static -o "$OUTPUT_DIR/lib/libtdjson.a" "${REQUIRED_ARCHIVES[@]}"

# Copy headers (both flat and nested paths)
mkdir -p "$OUTPUT_DIR/include/td/telegram"
cp "$BUILD_DIR/src-td/td/telegram/td_json_client.h" "$OUTPUT_DIR/include/"
cp "$BUILD_DIR/src-td/td/telegram/td_json_client.h" "$OUTPUT_DIR/include/td/telegram/"
cp "$BUILD_DIR/ios-td/td/telegram/tdjson_export.h" "$OUTPUT_DIR/include/"
cp "$BUILD_DIR/ios-td/td/telegram/tdjson_export.h" "$OUTPUT_DIR/include/td/telegram/"

# Link every member into a device executable, without running it. This checks
# symbol closure and rejects wrong-platform/ABI members before sealing a cache.
cat > "$BUILD_DIR/link-probe.cpp" <<'PROBE'
#define TDJSON_STATIC_DEFINE
#include "td_json_client.h"
int main() {
    auto volatile create = &td_create_client_id;
    auto volatile send = &td_send;
    auto volatile receive = &td_receive;
    auto volatile execute = &td_execute;
    auto volatile callback = &td_set_log_message_callback;
    return create && send && receive && execute && callback ? 0 : 1;
}
PROBE
xcrun --sdk iphoneos clang++ -target arm64-apple-ios26.0 -isysroot "$IPHONEOS_SDK" \
    -I "$OUTPUT_DIR/include" "$BUILD_DIR/link-probe.cpp" \
    -Wl,-all_load "$OUTPUT_DIR/lib/libtdjson.a" -Wl,-fatal_warnings \
    -lz -o "$BUILD_DIR/link-probe"
xcrun vtool -show-build "$BUILD_DIR/link-probe" > "$BUILD_DIR/link-platform.txt"
python3 - "$OUTPUT_DIR" "$BUILD_DIR/link-platform.txt" "${REQUIRED_ARCHIVES[@]}" <<'VERIFY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
lines = [line.split() for line in pathlib.Path(sys.argv[2]).read_text().splitlines()]
if ["platform", "IOS"] not in lines or ["minos", "26.0"] not in lines:
    raise SystemExit("Native closure link probe must target iOS device, deployment 26.0")
def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""): h.update(chunk)
    return h.hexdigest()
members = [{"name": pathlib.Path(name).name, "sha256": sha(pathlib.Path(name)),
            "architecture": "arm64"} for name in sys.argv[3:]]
record = {"schema": 1, "platform": "IOS", "deployment": "26.0",
          "archiveSha256": sha(root / "lib/libtdjson.a"), "members": members,
          "evidence": "clang++ device link with all_load/fatal_warnings and vtool; executable not run"}
(root / "link-validation.json").write_text(json.dumps(record, sort_keys=True) + "\n")
VERIFY

# Keep exact dependency notices with cached native artifacts and later packaging.
mkdir -p "$OUTPUT_DIR/licenses"
cp "$BUILD_DIR/src-td/LICENSE_1_0.txt" "$OUTPUT_DIR/licenses/LICENSE-TDLib.txt"
cp "$BUILD_DIR/src-openssl/LICENSE.txt" "$OUTPUT_DIR/licenses/LICENSE-OpenSSL.txt"
cp "$BUILD_DIR/src-td/sqlite/sqlite/LICENSE" "$OUTPUT_DIR/licenses/LICENSE-TDSQLite.txt"
for notice in "$BUILD_DIR/src-openssl"/NOTICE*; do
    if [[ -f "$notice" ]]; then cp "$notice" "$OUTPUT_DIR/licenses/$(basename "$notice")"; fi
done

# Seal cache provenance per BUILD-CACHE.md
echo "6. Sealing native TDLib cache..."
python3 "$REPO_ROOT/scripts/build_cache.py" seal-tdlib --build-root "$BUILD_ROOT"

echo "=== TDLib assembly complete ==="
echo "Artifact: $OUTPUT_DIR/lib/libtdjson.a"
