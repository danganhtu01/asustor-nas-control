#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo -- "$0" "$@"
fi

# The nextcloud-* names are new in this branch. Refuse rather than clobber a
# same-named command that something other than this repo installed.
for name in nextcloud-lib nextcloud-preflight nextcloud-install nextcloud-status \
            nextcloud-occ nextcloud-postflight nextcloud-uninstall; do
  target=/usr/local/bin/$name
  if [[ -e $target ]] && ! grep -qs 'nextcloud-trial' "$target"; then
    printf 'error: checked whether %s is safe to overwrite\n' "$target" >&2
    printf '  found:    an existing file that this repo did not install\n' >&2
    printf '  expected: no file there, or one carrying the nextcloud-trial marker\n' >&2
    printf '  fix:      move it aside, then re-run this installer\n' >&2
    exit 1
  fi
done

install -Dm755 scripts/asustorctl /usr/local/bin/asustorctl
install -Dm755 scripts/fanspeed /usr/local/bin/fanspeed
install -Dm755 scripts/cloud-nas-status /usr/local/bin/cloud-nas-status
install -Dm755 scripts/cloud-nas-sync-now /usr/local/bin/cloud-nas-sync-now
install -Dm755 scripts/cloud-nas-watch /usr/local/bin/cloud-nas-watch
install -Dm755 scripts/cloud-nas-progress /usr/local/bin/cloud-nas-progress
install -Dm755 scripts/nextcloud-lib /usr/local/bin/nextcloud-lib
install -Dm755 scripts/nextcloud-preflight /usr/local/bin/nextcloud-preflight
install -Dm755 scripts/nextcloud-install /usr/local/bin/nextcloud-install
install -Dm755 scripts/nextcloud-status /usr/local/bin/nextcloud-status
install -Dm755 scripts/nextcloud-occ /usr/local/bin/nextcloud-occ
install -Dm755 scripts/nextcloud-postflight /usr/local/bin/nextcloud-postflight
install -Dm755 scripts/nextcloud-uninstall /usr/local/bin/nextcloud-uninstall

printf 'Installed:\n'
printf '  /usr/local/bin/asustorctl\n'
printf '  /usr/local/bin/fanspeed\n'
printf '  /usr/local/bin/cloud-nas-status\n'
printf '  /usr/local/bin/cloud-nas-sync-now\n'
printf '  /usr/local/bin/cloud-nas-watch\n'
printf '  /usr/local/bin/cloud-nas-progress\n'
printf '  /usr/local/bin/nextcloud-lib\n'
printf '  /usr/local/bin/nextcloud-preflight\n'
printf '  /usr/local/bin/nextcloud-install\n'
printf '  /usr/local/bin/nextcloud-status\n'
printf '  /usr/local/bin/nextcloud-occ\n'
printf '  /usr/local/bin/nextcloud-postflight\n'
printf '  /usr/local/bin/nextcloud-uninstall\n'
printf '\nTry:\n'
printf '  asustorctl status\n'
printf '  fanspeed 200\n'
printf '  cloud-nas-status\n'
printf '  cloud-nas-watch\n'
printf '  cloud-nas-progress\n'
printf '\nNextcloud trial (read docs/nextcloud-trial.md first):\n'
printf '  nextcloud-preflight --root /srv/nextcloud   # read-only, safe to run blind\n'
printf '  nextcloud-install --root /srv/nextcloud --tz Asia/Ho_Chi_Minh\n'
printf '  nextcloud-status\n'
printf '  nextcloud-postflight\n'
printf '  nextcloud-occ status\n'
printf '  nextcloud-uninstall --help\n'
