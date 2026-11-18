import { execFileSync } from 'node:child_process';

// 仅创建本项目专用设备，不重置、删除或改配用户已有的其他模拟器。
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8' }).trim();
const inventory = JSON.parse(simctl('list', '--json'));
const version = value => value.version.split('.').reduce((result, part, index) => result + Number(part) / 100 ** index, 0);
const runtime = platform => inventory.runtimes
  .filter(value => value.isAvailable && value.identifier.includes(`SimRuntime.${platform}-`))
  .sort((a, b) => version(b) - version(a))[0];
const phoneRuntime = runtime('iOS');
const watchRuntime = runtime('watchOS');
if (!phoneRuntime || !watchRuntime) {
  console.error('需要已安装的 iOS 与 watchOS Simulator runtime。可用 Xcode 官方工具准备：');
  if (!watchRuntime) console.error('xcodebuild -downloadPlatform watchOS -architectureVariant arm64');
  if (!phoneRuntime) console.error('xcodebuild -downloadPlatform iOS -architectureVariant arm64');
  process.exit(1);
}
const types = inventory.devicetypes;
const phoneType = types.find(value => value.identifier === 'com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro')
  ?? types.find(value => /^iPhone /.test(value.name));
const watchType = types.find(value => value.identifier === 'com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-12-42mm')
  ?? types.find(value => /^Apple Watch/.test(value.name) && /\((40|41|42)mm\)/.test(value.name));
if (!phoneType || !watchType) throw new Error('当前 Xcode 缺少匹配的 iPhone／Watch 设备类型。');

if (process.argv.includes('--check')) {
  console.log(JSON.stringify({ phoneRuntime: phoneRuntime.name, watchRuntime: watchRuntime.name,
    phoneType: phoneType.name, watchType: watchType.name }));
  process.exit(0);
}

function device(name, type, targetRuntime) {
  const existing = (inventory.devices[targetRuntime.identifier] ?? []).find(value =>
    value.isAvailable && value.name === name && value.deviceTypeIdentifier === type.identifier);
  if (existing) return existing.udid;
  console.error(`创建 ${name}`);
  return simctl('create', name, type.identifier, targetRuntime.identifier);
}

const phone = device(`MyEnergy iPhone (${phoneRuntime.version})`, phoneType, phoneRuntime);
const watch = device(`MyEnergy Watch (${watchRuntime.version})`, watchType, watchRuntime);
const pairs = Object.entries(JSON.parse(simctl('list', 'pairs', '--json')).pairs);
const existingPair = pairs.find(([, value]) => value.watch?.udid === watch);
if (existingPair && existingPair[1].phone?.udid !== phone) {
  throw new Error('本项目 Watch 已与其他 iPhone 配对；保留现有配对，请在 Simulator 中检查。');
}
if (!existingPair) {
  console.error('配对 MyEnergy 专用 iPhone 与 Watch');
  simctl('pair', watch, phone);
} else if (!/\bactive\b/.test(existingPair[1].state ?? '')) {
  simctl('pair_activate', existingPair[0]);
}
console.log(JSON.stringify({ phone, watch, phoneRuntime: phoneRuntime.name, watchRuntime: watchRuntime.name }));
