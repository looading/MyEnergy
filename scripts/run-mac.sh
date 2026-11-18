#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh MyEnergyMac
open build/DerivedData/Build/Products/Debug/MyEnergy.app
