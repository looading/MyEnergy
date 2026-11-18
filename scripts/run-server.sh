#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}/server"
export MYENERGY_ALLOW_DEV_AUTH=1
export MYENERGY_HOST=127.0.0.1
exec node server.mjs
