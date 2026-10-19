#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${CLOUDIFIED_BUILD_ROOT:-$repo_root/build}"
project_path="$repo_root/Cloudified.xcodeproj"
build_number="${CLOUDIFIED_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo 'Build number must be a positive integer.' >&2
  exit 2
fi

if [[ ! -d "$project_path" ]]; then
  echo 'Cloudified.xcodeproj is not implemented yet. This milestone contains planning and build infrastructure.' >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Building an iOS application requires macOS with full Xcode.' >&2
  exit 2
fi
if [[ -e "$output_root/IPA" || -e "$output_root/Build.xcresult" ]]; then
  echo 'Use a fresh build output directory; existing evidence will not be overwritten.' >&2
  exit 2
fi

mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd)"

python3 "$repo_root/scripts/build_cache.py" prepare --build-root "$output_root"
if ! python3 "$repo_root/scripts/build_cache.py" verify-tdlib --build-root "$output_root"; then
  echo 'Native TDLib cache absent or invalid; assembling the exact pinned dependency.'
  python3 "$repo_root/scripts/build_cache.py" reset-tdlib --build-root "$output_root"
  CLOUDIFIED_BUILD_ROOT="$output_root" bash "$repo_root/scripts/assemble_tdlib.sh"
  python3 "$repo_root/scripts/build_cache.py" verify-tdlib --build-root "$output_root"
fi

xcodebuild -version
xcodebuild -showsdks
xcodebuild \
  -project "$project_path" \
  -scheme Cloudified \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$output_root/DerivedData" \
  -resultBundlePath "$output_root/Build.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  "CURRENT_PROJECT_VERSION=$build_number" \
  "CLOUDIFIED_NATIVE_ROOT=$output_root/tdlib" \
  "CLOUDIFIED_REVISION=$(git -C "$repo_root" rev-parse HEAD)" \
  build 2>&1 | tee "$output_root/xcodebuild.log"

app_path="$output_root/DerivedData/Build/Products/Release-iphoneos/Cloudified.app"
if [[ ! -d "$app_path" ]]; then
  echo 'Build did not produce the expected Cloudified.app.' >&2
  exit 3
fi
mkdir -p "$app_path/ThirdPartyLicenses"
cp "$repo_root/LICENSE" "$app_path/LICENSE.txt"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$app_path/ThirdPartyLicenses/THIRD_PARTY_NOTICES.txt"
for notice in "$repo_root"/licenses/LICENSE-* "$output_root"/tdlib/licenses/NOTICE*; do
  if [[ -f "$notice" ]]; then cp "$notice" "$app_path/ThirdPartyLicenses/"; fi
done
mkdir -p "$output_root/IPA/Payload"
ditto "$app_path" "$output_root/IPA/Payload/Cloudified.app"
ditto -c -k --keepParent "$output_root/IPA/Payload" "$output_root/Cloudified-unsigned.ipa"
(
  cd "$output_root"
  shasum -a 256 Cloudified-unsigned.ipa > Cloudified-unsigned.ipa.sha256
)
echo 'Unsigned IPA prepared. Local SideStore signing and device validation are still required.'
