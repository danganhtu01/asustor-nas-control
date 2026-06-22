#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo -- "$0" "$@"
fi

install -Dm755 scripts/asustorctl /usr/local/bin/asustorctl
install -Dm755 scripts/fanspeed /usr/local/bin/fanspeed

printf 'Installed:\n'
printf '  /usr/local/bin/asustorctl\n'
printf '  /usr/local/bin/fanspeed\n'
printf '\nTry:\n'
printf '  asustorctl status\n'
printf '  fanspeed 200\n'
