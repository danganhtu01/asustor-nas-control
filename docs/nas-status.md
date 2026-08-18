# `nas-status`

One screen of truth for the whole NAS. After an SSH login you have four
questions, and until now they took five commands to answer:

- is every volume still mounted, and is anything writing to the OS disk by
  mistake;
- did each sync and backup job last finish, or fail;
- when does each one run next;
- how big has each destination grown.

`nas-status` answers all four, and opens a `btop` pane beside the report.

```bash
nas-status                 # the full report
nas-status --brief         # just the two summary tables
nas-status --watch         # redraw every 30s
nas-status --json | jq     # the same data, for a monitor
```

## What it reports

**Volumes.** Every `LABEL=NAS_*` line in `/etc/fstab`, plus any volume a job
writes to, with device, size, used, free and mountpoint.

The state column matters more than the numbers. An unmounted mountpoint is an
ordinary directory on the root filesystem, so a sync aimed at one fills the OS
disk instead of the array — this is exactly what happened here after the
2026-07-01 power cut. `nas-status` calls that out twice: once as `NOT MOUNTED`,
and again, louder, if the directory already holds data.

**Jobs.** Two independent columns, deliberately:

| column | question |
| --- | --- |
| `STATE` | is the job alive right now |
| `LAST` | did its last completed cycle work |

A job can be `RUNNING` and `failed` at the same time — mid-retry after a bad
cycle — and collapsing that into one word loses the half you needed.

`STATE` is one of:

| state | meaning |
| --- | --- |
| `RUNNING` | a cycle is in flight (an rclone process, or a start with no end logged) |
| `IDLE` | alive and waiting for its next scheduled cycle |
| `STALLED` | a cycle started, never logged an end, and no process is behind it |
| `SCHEDULED` | a systemd timer, enabled, waiting |
| `DISABLED` | a timer that exists but is not enabled |
| `STOPPED` | the unit is not active |
| `NO WORKER` | the unit is up but its tmux window is gone — the failure nothing else notices |
| `NO UNIT` | the registry names a unit that is not installed |
| `NO JOB` | a destination directory with nothing configured to refresh it |
| `DEST UNMOUNTED` | the destination's volume is not mounted |

`STALLED` is the other one. A cycle whose start was logged, whose end never
was, and which has no rclone process behind it did not survive — the loop was
killed, or the tmux server went down mid-transfer. Without a distinct state that
job reads as `RUNNING` forever.

An aborted cycle is also caught in the `LAST` column. Every loop script
announces its own aborts as `[stamp] ERROR: …`, and such a line newer than the
last completed cycle is reported as that job's last result. Otherwise a job that
has been refusing to sync for a week still shows the last *good* cycle as `ok`.

`NO WORKER` is the one worth understanding. These jobs are a systemd user unit
babysitting a tmux window; the unit stays green whether or not the window
inside it survived. A live unit with a dead worker is a job that has silently
stopped syncing, and no other command on the box reports it.

**Destination sizes.** Bytes and file count per destination, de-duplicated by
inode so the hard-linked NAS_02 snapshots report what they occupy rather than a
hundred times it. A destination that is itself a whole volume is measured with
`df` — walking 101 hard-linked snapshots to rediscover a number `df` answers
instantly is minutes of disk for nothing.

**Snapshots.** How many `*_NAS_03_backup` directories exist on NAS_02, the
oldest and newest, the size of the newest, any `.incomplete` leftovers, and
whether free space has dropped below the reserve the backup loop prunes to.

**Thermal.** The hottest sane sensor reading, the fan's PWM and RPM, and
whether anything is actually regulating it. Exit 1 at 78 °C, exit 2 at 85 °C,
and exit 1 if `nas-fand` is installed but not running — the state that had this
box idling at 80 °C. See [`thermal-and-lcd.md`](thermal-and-lcd.md).

**Rclone remotes.** Every remote `rclone config` knows about, and which job
mirrors it. A remote somebody added and never wired to a job looks like it is
being backed up and is not, so it is called out — as is a remote whose registry
entry has no unit behind it, which is what `GoogleDrive-Personal` is today.

**Other units.** Any service or timer on the box matching the NAS/backup/sync
patterns that the registry does not name — a legacy timer nobody disabled, or a
job somebody added. The report should never quietly omit work that is running.

## Sizes, and why the first run is the slow one

Walking a 700 GiB mirror takes seconds warm and minutes cold, so measurements
are cached under `~/.local/state/nas-status/sizes.tsv` for an hour and each walk
runs under a timeout. Past the timeout you get the cached figure, labelled with
its age, rather than a hang or a dash.

```bash
nas-status --fast              # cache only, never walk anything
nas-status --refresh           # ignore the TTL, re-measure everything
nas-status --size-timeout 120  # allow a long cold walk
```

A walk that gives up records the failure, so the next run does not pay the full
timeout again — it retries when the entry ages out. A walk that could not read
part of the tree is labelled `UNDERCOUNT` and is never cached, because a short
figure presented as an accurate one is worse than no figure.

## Options

| flag | meaning |
| --- | --- |
| `-f`, `--fast` | never walk a directory; cached sizes only |
| `--refresh` | re-measure everything, ignoring the cache TTL |
| `--size-timeout N` | give up on one measurement after N seconds (default 25) |
| `--job ID` | report only this job; repeatable, or a comma list. An id that matches nothing is an error, not an all-clear |
| `-e`, `--errors N` | N recent error lines per job (default 3, `0` = none) |
| `-w`, `--watch [N]` | redraw every N seconds (default 30); walks once, then holds |
| `--json` | the whole report as JSON; composes with `--watch` |
| `--btop` | open the btop pane even from outside zellij |
| `--no-btop` | never touch zellij |
| `--btop-floating` | floating pane rather than tiled |
| `--color WHEN` | `auto`, `always` or `never` (`--no-color` is accepted too) |
| `-b`, `--brief` | the volume, job, snapshot and remote tables without the per-job detail blocks |
| `-V`, `--version` | print the version |
| `-h`, `--help` | usage |

`--watch` walks once and then holds the figures: a loop that re-walked the array
every 30 seconds would be a denial of service on the thing it is watching.

## The btop pane

Inside zellij, `nas-status` opens a pane named `nas-btop` running `btop`, then
returns focus to where you were. It is idempotent — a `nas-btop` pane that
already exists is left alone, so running the command in a loop never stacks
monitors. Outside zellij it does nothing unless you pass `--btop`, in which case
it targets the single running session.

```bash
nas-status --no-btop        # never touch zellij
nas-status --btop-floating  # floating pane instead of tiled
```

## Exit status

Made for `watch`, cron and monitors:

| code | meaning |
| --- | --- |
| 0 | every volume mounted, every job healthy |
| 1 | degraded: a job failed its last run, a unit is not active, a worker is gone, or free space is below the backup reserve |
| 2 | critical: a NAS volume is not mounted, or a destination directory is on the root filesystem |

## Configuration

Both files are optional and sourced in order:

```text
/etc/nas-status/nas-status.conf
~/.config/nas-status/nas-status.conf
```

Anything at the top of the script can be overridden. The jobs themselves live in
`NAS_JOBS`, one pipe-separated record each, thirteen fields in this order:

```text
id|title|scope|unit|window|parser|every|sched|log|source|dest|lock|procpat
```

| field | meaning |
| --- | --- |
| `id` | short handle, also what `--job` matches |
| `title` | what it syncs, in words |
| `scope` | `user`, `system` or `none` — which systemctl owns the unit |
| `unit` | systemd unit, or empty |
| `window` | tmux window inside the shared session, or empty |
| `parser` | `rclone-loop`, `tenant-loop`, `snapshot-loop`, `timer` or empty |
| `every` | seconds between cycles, for interval-driven loops |
| `sched` | human schedule, for clock-driven ones |
| `log` | the job's log file |
| `source` | where the data comes from |
| `dest` | where it lands — the directory whose size is reported |
| `lock` | flock file, or empty |
| `procpat` | `pgrep -f` pattern matching the transfer while it runs |

A record with the wrong number of fields is reported on stderr and skipped
rather than silently misread — an off-by-one here once made `procpat` an
alternation that matched every process on the box.

Setting `NAS_JOBS` replaces the built-in five outright. To add one job and keep
them, set `NAS_STATUS_EXTRA_JOBS` instead — it is appended after the defaults:

```bash
# ~/.config/nas-status/nas-status.conf
NAS_STATUS_EXTRA_JOBS=(
"photos|Phone photos -> NAS_01|user|photo-sync.service|photo-sync|rclone-loop|900||$HOME/rclone-logs/photos.log|Photos:|/srv/NAS_01/Photos||rclone sync Photos:"
)
```

The config is read before any default is resolved, so every variable below can
be set there as well as in the environment.

Other useful knobs:

| variable | default | meaning |
| --- | --- | --- |
| `NAS_MOUNT_BASE` | `/srv` | where the volumes are mounted |
| `NAS_VOLUME_GLOB` | `NAS_*` | which fstab labels count as NAS volumes |
| `NAS_STATUS_SIZE_TTL` | `3600` | how long a cached measurement stays usable |
| `NAS_STATUS_SIZE_TIMEOUT` | `25` | seconds one directory walk may take |
| `NAS_STATUS_SNAPSHOT_SUFFIX` | `NAS_03_backup` | snapshot directory suffix |
| `NAS_STATUS_RESERVE_GIB` | `10` | free space the backup loop prunes to |
| `NAS_STATUS_TMUX_SESSION` | `rclone-sync` | the shared tmux session |
| `NAS_STATUS_BTOP_PANE` | `nas-btop` | zellij pane name |
| `NAS_STATUS_DISCOVER_IGNORE` | `*keyring* systemd-* dbus-* *timesync*` | units to leave out of the discovery section |

## Running it as root

`sudo nas-status` works. The jobs are user units, so the command resolves the
owning account from `SUDO_USER`, and reaches that account's systemd manager and
tmux server rather than root's empty ones.

## JSON

`--json` emits the whole report — volumes, jobs, snapshots, discovered units,
severity — with byte counts as numbers and timestamps as epochs.

```bash
nas-status --json --fast | jq -r '.jobs[] | select(.result == "failed") | .id'
nas-status --json | jq '.volumes[] | select(.state != "mounted")'
```
