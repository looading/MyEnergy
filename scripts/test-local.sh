#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
umask 077

for tool in node swift; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    print -u2 -- "Required command is unavailable: $tool"
    exit 1
  fi
done
node --input-type=module -e 'if (Number(process.versions.node.split(".")[0]) < 24) { console.error("Node.js 24 or newer is required."); process.exit(1); }'

local_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/myenergy-local.XXXXXX")
service_pid=
test_pid=
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n "$test_pid" ]]; then
    kill -TERM "$test_pid" 2>/dev/null
    wait "$test_pid" 2>/dev/null
  fi
  if [[ -n "$service_pid" ]]; then
    kill -TERM "$service_pid" 2>/dev/null
    wait "$service_pid" 2>/dev/null
  fi
  rm -rf -- "$local_test_dir"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

node scripts/helpers/local-service.mjs "$local_test_dir" >"$local_test_dir/service.log" 2>&1 &
service_pid=$!

# 只读取隔离服务的健康状态；不创建账号，也不输出会话或密钥。
if ! sync_url=$(node --input-type=module - "$local_test_dir/service-url" "$service_pid" <<'NODE'
import { readFile } from 'node:fs/promises';
import { setTimeout } from 'node:timers/promises';

const [urlFile, servicePID] = process.argv.slice(2);
const deadline = Date.now() + 15_000;
while (Date.now() < deadline) {
  try { process.kill(Number(servicePID), 0); }
  catch { console.error('The isolated sync service exited before becoming ready.'); process.exit(1); }
  try {
    const url = (await readFile(urlFile, 'utf8')).trim();
    if (!/^http:\/\/127\.0\.0\.1:[1-9]\d{0,4}$/.test(url)) throw new Error();
    const response = await fetch(`${url}/healthz`, { signal: AbortSignal.timeout(500) });
    const health = await response.json();
    if (response.ok && health.status === 'ok' && health.protocolVersion === 1 && health.developmentAuth === true) {
      process.stdout.write(url);
      process.exit(0);
    }
  } catch { /* 服务启动中，等待下一次有界检查。 */ }
  await setTimeout(100);
}
console.error('Timed out waiting for the isolated sync service health check.');
process.exit(1);
NODE
); then
  cat "$local_test_dir/service.log" >&2
  exit 1
fi

run_check() {
  "$@" &
  test_pid=$!
  local result=0
  wait "$test_pid" || result=$?
  test_pid=
  return "$result"
}

print -- "Running Swift tests with an isolated local development service."
run_check env MYENERGY_TEST_SYNC_URL="$sync_url" swift test --package-path Packages/MyEnergyKit
if ! kill -0 "$service_pid" 2>/dev/null; then
  print -u2 -- "The isolated sync service exited during Swift tests."
  exit 1
fi
print -- "Running sync service tests."
run_check node --test server/test/*.test.mjs
