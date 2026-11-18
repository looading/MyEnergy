#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh MyEnergyMac
if pgrep -x MyEnergy >/dev/null; then
  print 'MyEnergy 已经运行。当前窗口继续使用原进程；退出再打开应用即可加载刚完成的新构建。'
fi
open build/DerivedData/Build/Products/Debug/MyEnergy.app
