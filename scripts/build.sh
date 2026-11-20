#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
scheme="${1:-MyEnergyMac}"
case "$scheme" in
  MyEnergyMac) destination='platform=macOS' ;;
  MyEnergyiOS) destination='generic/platform=iOS Simulator' ;;
  MyEnergyWatch) destination='generic/platform=watchOS Simulator' ;;
  *) print 'Choose MyEnergyMac, MyEnergyiOS or MyEnergyWatch'; exit 1 ;;
esac
# 已有工程直接构建，保留开发者本地的签名团队和 scheme 设置。
if [[ ! -f MyEnergy.xcodeproj/project.pbxproj ]]; then
  command -v xcodegen >/dev/null || { print 'Install XcodeGen: brew install xcodegen'; exit 1; }
  xcodegen generate
fi
xcodebuild -project MyEnergy.xcodeproj -scheme "$scheme" -configuration Debug \
  -destination "$destination" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
