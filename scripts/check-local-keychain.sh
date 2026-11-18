#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/myenergy-keychain.XXXXXX")"
probe_key="verification-$(uuidgen)"
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -x "$probe_dir/probe" ]]; then "$probe_dir/probe" delete "$probe_key" >/dev/null 2>&1 || true; fi
  rm -rf -- "$probe_dir"
  exit "$result"
}
trap cleanup EXIT
cat > "$probe_dir/main.swift" <<'SWIFT'
import Foundation
import Darwin

// 只访问本测试新建的随机项目；不读取现有账号或应用恢复密钥。
guard CommandLine.arguments.count == 3 else { exit(4) }
let operation = CommandLine.arguments[1]
let key = CommandLine.arguments[2]
let fixture = Data("disposable-keychain-roundtrip".utf8)
do {
  switch operation {
  case "write": try KeychainStore.write(fixture, key: key)
  case "read": guard try KeychainStore.read(key: key) == fixture else { exit(2) }
  case "delete":
    try KeychainStore.delete(key: key)
    guard try KeychainStore.read(key: key) == nil else { exit(3) }
  default: exit(4)
  }
} catch {
  print("Local development Keychain verification failed: \(error.localizedDescription)")
  exit(1)
}
SWIFT
xcrun swiftc -DDEBUG Packages/MyEnergyKit/Sources/MyEnergyPlatform/KeychainStore.swift \
  "$probe_dir/main.swift" -o "$probe_dir/probe"
"$probe_dir/probe" write "$probe_key"
"$probe_dir/probe" read "$probe_key"
"$probe_dir/probe" delete "$probe_key"
print 'Local development Keychain cross-process write/read/delete: PASS'
