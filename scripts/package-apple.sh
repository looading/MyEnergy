#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 -- 'Usage: ./scripts/package-apple.sh {macos|iphone|watch} [output-directory]'
  exit 2
}

(( $# >= 1 && $# <= 2 )) || usage
platform="$1"
architecture_settings=()
case "$platform" in
  macos)
    scheme=MyEnergyMac
    destination='generic/platform=macOS'
    sdk_platform=MacOSX
    bundle_relative='Release/MyEnergy.app'
    bundle_id=dev.myenergy.mac
    architecture_settings=('ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO)
    ;;
  iphone)
    scheme=MyEnergyiOS
    destination='generic/platform=iOS'
    sdk_platform=iPhoneOS
    bundle_relative='Release-iphoneos/MyEnergy.app'
    bundle_id=dev.myenergy.ios
    ;;
  watch)
    scheme=MyEnergyWatch
    destination='generic/platform=watchOS'
    sdk_platform=WatchOS
    bundle_relative='Release-watchos/MyEnergyWatch.app'
    bundle_id=dev.myenergy.ios.watchkitapp
    ;;
  *) usage ;;
esac

cd "${0:A:h:h}"
artifact_dir="${2:-build/apple-artifacts}"
mkdir -p -- "$artifact_dir"
artifact_dir="$(cd "$artifact_dir" && pwd -P)"
scratch="$(mktemp -d "$artifact_dir/.myenergy-$platform.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

xcodebuild -version
xcodebuild -quiet -project MyEnergy.xcodeproj -scheme "$scheme" -configuration Release \
  -destination "$destination" -derivedDataPath "$scratch/DerivedData" \
  CODE_SIGNING_ALLOWED=NO "${architecture_settings[@]}" build

check_app() {
  local app="$1" expected_platform="$2" expected_id="$3"
  local plist="$app/Info.plist" executable_dir="$app"
  if [[ "$expected_platform" == MacOSX ]]; then
    plist="$app/Contents/Info.plist"
    executable_dir="$app/Contents/MacOS"
  fi

  local actual_platform actual_id executable
  actual_platform="$(plutil -extract CFBundleSupportedPlatforms.0 raw -o - "$plist")"
  actual_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
  executable="$(plutil -extract CFBundleExecutable raw -o - "$plist")"
  if [[ "$actual_platform" != "$expected_platform" || "$actual_id" != "$expected_id" || ! -x "$executable_dir/$executable" ]]; then
    print -u2 -- "Unexpected app bundle at $app (platform: $actual_platform, bundle ID: $actual_id)"
    return 1
  fi
  if [[ "$expected_platform" == MacOSX ]]; then
    local architectures
    architectures="$(xcrun lipo -archs "$executable_dir/$executable")"
    if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
      print -u2 -- "Expected a universal macOS executable, got: $architectures"
      return 1
    fi
  fi
}

app_bundle="$scratch/DerivedData/Build/Products/$bundle_relative"
check_app "$app_bundle" "$sdk_platform" "$bundle_id"
if [[ "$platform" == iphone ]]; then
  check_app "$app_bundle/Watch/MyEnergyWatch.app" WatchOS dev.myenergy.ios.watchkitapp
fi

archive="MyEnergy-$platform.zip"
if [[ -d "$artifact_dir/$archive" ]]; then
  print -u2 -- "Archive path is a directory: $artifact_dir/$archive"
  exit 1
fi
ditto -c -k --keepParent "$app_bundle" "$scratch/$archive"
unzip -tq "$scratch/$archive"
mv -f -- "$scratch/$archive" "$artifact_dir/$archive"
print -- "Packaged $artifact_dir/$archive"
