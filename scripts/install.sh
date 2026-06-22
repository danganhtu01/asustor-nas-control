#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo -- "$0" "$@"
fi

install -Dm755 scripts/asustorctl /usr/local/bin/asustorctl
install -Dm755 scripts/fanspeed /usr/local/bin/fanspeed
install -Dm755 scripts/cloud-nas-status /usr/local/bin/cloud-nas-status
install -Dm755 scripts/cloud-nas-sync-now /usr/local/bin/cloud-nas-sync-now
install -Dm755 scripts/cloud-nas-watch /usr/local/bin/cloud-nas-watch

printf 'Installed:\n'
printf '  /usr/local/bin/asustorctl\n'
printf '  /usr/local/bin/fanspeed\n'
printf '  /usr/local/bin/cloud-nas-status\n'
printf '  /usr/local/bin/cloud-nas-sync-now\n'
printf '  /usr/local/bin/cloud-nas-watch\n'
printf '\nTry:\n'
printf '  asustorctl status\n'
printf '  fanspeed 200\n'
printf '  cloud-nas-status\n'
printf '  cloud-nas-watch\n'
