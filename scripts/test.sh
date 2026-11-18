#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift test --package-path Packages/MyEnergyKit
node --test server/test/*.test.mjs
