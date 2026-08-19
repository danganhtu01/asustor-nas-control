# Outstanding

Open items on `ArchNAS` that are known, deliberate to leave for now, and would
otherwise only exist in someone's memory. Closed items are deleted, not
archived — `git log` is the history.

Last reviewed 2026-08-19.

## 1. The fan-floor measurement was never completed

`docs/thermal-and-lcd.md` states the achievable idle floor as mid-50s °C. The
supporting evidence is 574 idle samples across 28–44 % fan (flat at 53.5 °C) plus
two spot readings at 100 % and at 20 % under load. What is **missing** is a
controlled five-minute window at 100 % fan on an idle box.

The monitor is written and works; it timed out twice waiting for the fan to be
freed, because `systemctl stop nas-fand` needs a password and cannot be driven
from a non-TTY session.

To finish it, from a real terminal:

```bash
sudo systemctl stop nas-fand    # the fail-safe drives the fan to 100%
sleep 300
echo "$(( $(cat /sys/class/hwmon/hwmon6/temp1_input) / 1000 )) C at 100% fan"
sudo systemctl start nas-fand
```

If the result lands at 56–58 °C, the floor claim is confirmed and the
maximum-cooling preset is worth roughly one degree at idle. If it lands
materially lower, the default curve should be reconsidered.

## 2. The tenant sync loop reports every failure as `exit 0`

`scripts/rclone-onedrive-da-sync-loop.sh` logs

```bash
log "FAILED: ${dest} (rclone exit $?)"
```

in a branch where `$?` is the status of the preceding `failed=$((failed + 1))`,
which is always 0. Every genuine per-drive failure is therefore recorded as
"exit 0", and `nas-status` faithfully reports the nonsense. One-line fix —
capture `$?` into a variable immediately after the `rclone sync` — deliberately
not bundled into the unrelated work that surfaced it.

## 3. The legacy `cloud-nas-*` wrappers are broken

`~/.config/cloud-nas/cloud-nas.conf` still carries the pre-migration paths:

```text
NAS03_MOUNT="/run/media/atdang/NAS_03"
```

The volumes moved to `/srv` on 2026-08-18, so `cloud-nas-status`,
`cloud-nas-progress`, `cloud-nas-watch` and `cloud-nas-sync-now` all point at
directories that no longer exist. Their timers are long gone; the work is done
by the tmux loop scripts now, and `nas-status` supersedes the reporting.

Decision needed: fix the config, or retire the four commands and their README
section. Retiring is the honest option — nothing has driven them since June.

## 4. `OneDrive-Personal` sync is failing authentication

```text
InvalidAuthenticationToken: IDX14100: JWT is not well formed, there are no dots (.)
```

1027 occurrences in the last 3000 log lines. The loop is healthy and retrying
every 10 minutes; the token itself is bad and needs re-minting with
`rclone config reconnect OneDrive-Personal:`. Until then that mirror is stale
and `nas-status` correctly shows `RUNNING / failed`.

## 5. `GoogleDrive-Personal` has a mirror and no job

`/srv/NAS_03/GoogleDrive-Personal` holds 5.1 GiB from the retired cloud-nas
timer set. Nothing refreshes it. `nas-status` reports it as `NO JOB` and lists
the remote as having no job mirroring it.

Either give it a loop script matching the OneDrive-Personal one, or delete the
directory and drop the registry entry. Leaving a stale mirror that looks like a
backup is the worst of the three options.

## 6. `m365-backup.timer` is installed and has never run

The system-level nightly tenant mirror is `disabled` / `never run`. The
user-level `onedrive-da-sync-tmux.service` covers the same tenant hourly, so
this may simply be redundant — but two mechanisms for one job, one of them
dormant and unexplained, is worth a decision rather than a shrug.
