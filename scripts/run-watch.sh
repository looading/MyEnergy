#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

if [[ "${1:-}" != '' && "${1:-}" != '--prepare-only' ]]; then
  print -u2 -- '用法：./scripts/run-watch.sh [--prepare-only]'
  exit 1
fi
for tool in node xcodegen xcrun xcodebuild; do
  command -v "$tool" >/dev/null || { print -u2 -- "缺少命令：$tool"; exit 1; }
done

pair_info=$(node scripts/helpers/watch-simulator.mjs)
phone_id=$(print -r -- "$pair_info" | node --input-type=module -e 'let input=""; for await (const chunk of process.stdin) input+=chunk; process.stdout.write(JSON.parse(input).phone);')
watch_id=$(print -r -- "$pair_info" | node --input-type=module -e 'let input=""; for await (const chunk of process.stdin) input+=chunk; process.stdout.write(JSON.parse(input).watch);')
mkdir -p .local
print -r -- "$pair_info" > .local/watch-simulator.json

xcrun simctl bootstatus "$phone_id" -b
xcrun simctl bootstatus "$watch_id" -b
xcodegen generate
# Simulator 使用本地 ad-hoc 签名携带 HealthKit entitlement，不需要 Apple Team。
xcodebuild -project MyEnergy.xcodeproj -scheme MyEnergyiOS -configuration DeviceDebug \
  -destination "platform=iOS Simulator,id=$phone_id" -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build

phone_app=build/DerivedData/Build/Products/DeviceDebug-iphonesimulator/MyEnergy.app
watch_app=build/DerivedData/Build/Products/DeviceDebug-watchsimulator/MyEnergyWatch.app
xcrun simctl install "$phone_id" "$phone_app"
xcrun simctl install "$watch_id" "$watch_app"
if [[ "${1:-}" == '--prepare-only' ]]; then
  print -- 'MyEnergy iPhone 与 Watch 已安装。设备标识见 .local/watch-simulator.json。'
  exit 0
fi

if ! open -a 'Device Hub' 2>/dev/null; then
  open -a Simulator --args -CurrentDeviceUDID "$watch_id"
fi
xcrun simctl launch --terminate-running-process "$phone_id" dev.myenergy.ios
xcrun simctl launch --terminate-running-process "$watch_id" dev.myenergy.ios.watchkitapp
print -- '已启动专用模拟器；模拟器数据与 Mac 本机记录分开。'
