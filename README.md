# asustor-nas-control

Manual control helpers for ASUSTOR NAS hardware running Linux with
[`mafredri/asustor-platform-driver`](https://github.com/mafredri/asustor-platform-driver).

This was built on an ASUSTOR Lockerstor Gen 2 AS6704 running Arch Linux. The
scripts use the standard Linux sysfs interfaces exposed by the driver:

- fan/PWM control via `/sys/devices/platform/asustor_it87.*/hwmon/hwmon*/pwm*`
- fan RPM readback via `fan*_input`
- LEDs via `/sys/class/leds/*`
- IT87 GPIO LED blink controls via `gpled*_blink*`

The upstream driver README documents AS67xx support, `asustor-it87`, fan
regulation through `pwm1`, and LED controls under `/sys/class/leds/`.

## Install

```bash
git clone https://github.com/danganhtu01/asustor-nas-control.git
cd asustor-nas-control
./scripts/install.sh
```

The installer copies commands into `/usr/local/bin`. Run it normally or with
`sudo`; if needed, it will re-run itself through `sudo`.

```bash
sudo ./scripts/install.sh
```

After installing, these commands should be available from any directory:

```bash
asustorctl status
fanspeed 200
nas-status
nas-fand --status
nas-lcd-banner --check
cloud-nas-status
cloud-nas-sync-now
cloud-nas-watch
cloud-nas-progress
```

If you pull a newer version, reinstall the scripts so `/usr/local/bin` is
updated:

```bash
cd ~/GitHub/asustor-nas-control
git pull
sudo ./scripts/install.sh
```

For a local user-only test without installing:

```bash
./scripts/asustorctl status
./scripts/fanspeed 200
./scripts/nas-status
./scripts/cloud-nas-status
./scripts/cloud-nas-watch --no-follow
./scripts/cloud-nas-progress --once
```

## Common Commands

Set the primary fan PWM value to `200`:

```bash
fanspeed 200
```

Expected output:

```text
pwm1=200
```

Use a percent instead:

```bash
fanspeed 70%
```

Expected output:

```text
pwm1=179
```

Show current fan, PWM, temperature, and LED state:

```bash
asustorctl status
```

List PWM channels:

```bash
asustorctl pwm list
```

Set a specific PWM channel:

```bash
asustorctl pwm set 1 200
```

Expected output:

```text
pwm1=200
```

Set the primary fan mode:

```bash
asustorctl fan mode manual
asustorctl fan mode auto
```

Manual mode writes `pwm1_enable=1`; auto mode writes `pwm1_enable=2`.

List LEDs:

```bash
asustorctl led list
```

Turn LEDs on/off:

```bash
asustorctl led set green:status on
asustorctl led set red:status off
asustorctl led set sata1:green:disk on
```

Set an LED trigger:

```bash
asustorctl led trigger green:usb usb-host
asustorctl led trigger green:status none
```

Show IT87 GPIO blink controls:

```bash
asustorctl blink status
```

Disable IT87 GPIO blink slot 1:

```bash
asustorctl blink set 1 0
```

Set blink slot 1 frequency mode to always-on when supported:

```bash
asustorctl blink freq 1 11
```

## NAS Status

One screen of truth for the whole box — every rclone sync job and backup job,
what each one last did, when it runs next, how big each destination has grown,
and whether every volume is still mounted.

```bash
nas-status
```

```text
== VOLUMES ==
VOLUME    STATE         DEVICE                SIZE       USED       FREE  USE%  MOUNTPOINT
NAS_02    mounted       /dev/nvme0n1p1      1.8TiB   738.8GiB  1000.8GiB   43%  /srv/NAS_02
NAS_03    mounted       /dev/nvme1n1p1      1.8TiB   722.5GiB  1017.1GiB   42%  /srv/NAS_03

== JOBS ==
JOB                   STATE          LAST      LAST RUN             NEXT RUN
onedrive-personal     RUNNING        failed    16:29:07  31m ago    after this cycle
onedrive-da           IDLE           ok        16:40:49  19m ago    17:40  in 40m
nas03-backup          IDLE           ok        15:30:13  1h30m ago  03:30  in 10h29m
```

`STATE` and `LAST` answer two different questions on purpose — whether the job
is alive right now, and whether its last completed cycle worked. A job can be
`RUNNING` and `failed` at the same time, mid-retry after a bad cycle.

It also lists every rclone remote and which job mirrors it, the snapshot set on
NAS_02, and any NAS-ish systemd unit on the box the registry does not name — so
a remote or a job somebody added is never quietly omitted.

Running it inside zellij also opens a pane named `nas-btop` running `btop`, and
gives focus straight back. That is idempotent: a `nas-btop` pane that already
exists is left alone, so running `nas-status` in a loop never stacks monitors.

Common variants:

```bash
nas-status --brief          # the summary tables only
nas-status --watch          # redraw every 30 seconds
nas-status --fast           # cached destination sizes; never walk a tree
nas-status --refresh        # re-measure every destination now
nas-status --job onedrive-da
nas-status --json | jq '.jobs[] | select(.result == "failed")'
nas-status --no-btop        # never touch zellij
```

Exit status is meant for monitors: `0` healthy, `1` degraded, `2` critical — a
volume is not mounted, or a job is writing to the OS disk because its
mountpoint is an empty directory.

Full documentation, including the job registry format and configuration:
[`docs/nas-status.md`](docs/nas-status.md).

## Fan Control and the Front LCD

Two things this board does not do for itself on Linux. `scripts/install.sh`
installs **and enables** both.

**Fan.** The board ships in manual mode pinned at `pwm1=51` — 20 %, 770 RPM —
and never ramps whatever the temperature, so the package idles at 73–80 °C. It
cannot simply be handed to the chip's own automatic mode: the IT8625's thermal
inputs are not connected and read −128 °C, so `pwm1_enable=2` would regulate
against a sensor that does not exist. `nas-fand` keeps the chip in manual mode
and drives the curve from sensors that are real — `coretemp`, the NVMe
controllers, the NICs — hottest reading wins.

```bash
nas-fand --status     # temperatures, PWM, RPM. Read-only, no root.
nas-fand --check      # validate the config; print the curve as a table
nas-fand --dry-run    # decide against the real temperatures, write nothing
nas-fand --simulate 62 70 69 68 67 66 60   # replay temperatures through the
                                           # real decision logic, no hardware
```

```text
FAN_CURVE="50:60 60:120 70:200 78:255"     # /etc/nas-fan/nas-fan.conf
   50 C  pwm  60  (23%)      70 C  pwm 200  (78%)
   60 C  pwm 120  (47%)      78 C  pwm 255  (100%)
```

**Stopping the service spins the fan up, on purpose.** Every exit path — clean
stop, crash, `SIGKILL`, a config that fails validation — drives the fan to full.
A fan daemon that is not running must leave a NAS loud, not silent; silence is
the failure you find out about when a disk has already died.

**LCD.** `lcd-banner.service` writes the machine's identity to the front panel
once the boot has finished:

```text
  ArchNAS
  192.168.0.212
```

Bottom row defaults to the address you would SSH to, or `DEGRADED n fail` when
systemd reports the boot as degraded. A udev rule matched on the port's hardware
address (`0x2F8`, not the node name — 32 `ttyS` nodes exist and three are real)
creates `/dev/asustor-lcm` and grants a system group `lcm` write access.

```bash
nas-lcd-banner --check          # what would be written, touching no hardware
lcdline --dry-run 0 ArchNAS     # the raw frame, checksum and all
```

**LEDs.** A front LED can read `brightness=1`, `trigger=[none]` and still
blink: the IT8625 blinks it in hardware from its own GPIO register, over the top
of whatever the kernel set, and nothing in `/sys/class/leds` shows that.
`nas-leds` clears the blink mask so "on" means solid, and `nas-leds.service`
re-applies it at boot because both controls are volatile.

```bash
nas-leds --show     # blink masks and every LED's real state
nas-leds --check    # what would be written
```

Full details, protocol, tuning and recovery:
[`docs/thermal-and-lcd.md`](docs/thermal-and-lcd.md).

## Cloud NAS Commands

These commands are convenience wrappers for the rclone NAS automation that
syncs all configured rclone remotes into `NAS_03` and creates daily NAS_03
snapshots on `NAS_02`.

They expect the cloud automation files to already exist under:

```text
/home/atdang/.local/bin/cloud-nas-lib
/home/atdang/.local/bin/cloud-nas-sync
/home/atdang/.local/bin/cloud-nas-backup-to-nas02
/home/atdang/.config/cloud-nas/cloud-nas.conf
/home/atdang/.config/systemd/user/cloud-nas-*.service
/home/atdang/.config/systemd/user/cloud-nas-*.timer
```

### Headless Monitoring Workflow

After SSH login, check the whole cloud/NAS pipeline:

```bash
cloud-nas-status
```

Start a fresh sync of every configured rclone remote:

```bash
cloud-nas-sync-now
```

Stream progress for every drive/remoted cloud provider:

```bash
cloud-nas-watch
```

Poll local NAS_03 mirror sizes every 5 seconds and compare with remote sizes:

```bash
cloud-nas-progress
```

The first run may show `remote sizing...` while rclone lists each cloud remote.
When remote totals are available, the command prints local size, remote size,
file count, and local-vs-remote percentage for each configured remote.

If the percentage has a trailing `*`, the remote has objects whose byte size was
not reported by the cloud provider. This is common with Google Drive native
documents or other special objects. In that case, the remote byte total is only
the known-size part of the drive, so the local copy can appear larger than
`100%` even when `rclone check` reports that the comparable files match.

Print one local/remote size snapshot and exit:

```bash
cloud-nas-progress --once
```

Use a different poll interval:

```bash
cloud-nas-progress --interval 10
```

For a quick one-shot view without staying attached to the terminal:

```bash
cloud-nas-watch --no-follow
```

If you want more recent log history before live streaming starts:

```bash
cloud-nas-watch --lines 120
```

Detach safely with `Ctrl-C`; this only stops your log viewer, not the systemd
sync service.

Print sync, timer, disk, remote, error, and backup status:

```bash
cloud-nas-status
```

Stop any active cloud sync and immediately start a fresh all-remotes sync:

```bash
cloud-nas-sync-now
```

Stream the global cloud sync log and each configured remote's rclone log:

```bash
cloud-nas-watch
```

Print recent progress without following:

```bash
cloud-nas-watch --no-follow
```

Show more history before following:

```bash
cloud-nas-watch --lines 120
```

The normal periodic sync timer still runs automatically:

```bash
systemctl --user list-timers 'cloud-nas*' --all
```

You can also watch individual logs directly:

```bash
tail -f /home/atdang/.local/state/cloud-nas/rclone-sync-OneDrive-Personal.log
tail -f /home/atdang/.local/state/cloud-nas/rclone-sync-GoogleDrive-Personal.log
```

## Microsoft 365 Mirror

Nightly read-only mirror of every OneDrive and SharePoint document library in the
tenant, onto the array. No human signs in: a single Entra app registration with
**Application** permissions authenticates as itself.

```bash
m365-backup-preflight     # read-only; run this first
m365-backup-inventory     # rebuild the drive manifest
m365-backup-sync --dry-run
m365-backup-sync
m365-backup-status
```

Requires **rclone v1.69.0 or newer** — app-only OneDrive auth does not exist in
older builds, and distro packages are well behind. The scripts refuse rather than
fail obscurely.

The sync **will not run unless `M365_DEST_ROOT` is a mounted filesystem**. An
unmounted array is an ordinary directory on the OS disk, and a tenant mirror would
fill it.

Full setup, limitations and restore procedure: [`docs/m365-backup.md`](docs/m365-backup.md).


## Documentation

| doc | what is in it |
| --- | --- |
| [`docs/as6704-observed-state.md`](docs/as6704-observed-state.md) | ground truth for this hardware: fan, sensors, LEDs, LCD port, storage — all measured, none of it from a datasheet |
| [`docs/thermal-and-lcd.md`](docs/thermal-and-lcd.md) | fan curve, LED blink register, LCD protocol, tuning and recovery |
| [`docs/nas-status.md`](docs/nas-status.md) | the health command: columns, exit codes, job registry format |
| [`docs/m365-backup.md`](docs/m365-backup.md) | the Microsoft 365 tenant mirror |
| [`docs/outstanding.md`](docs/outstanding.md) | known open items, and what it would take to close each |

## Notes

- `fanspeed 200` means raw PWM value `200`, on a `0..255` scale.
- The script defaults to PWM channel `1`, matching the observed AS6704 fan.
- Override the channel with `ASUSTOR_FAN_PWM=2 fanspeed 180`.
- Write operations require root because sysfs hardware controls are root-owned.
- Write commands print the value they changed. If `fanspeed 200` returns no
  output, you are probably running an old installed copy; run
  `sudo ./scripts/install.sh` again from the repo.
- Wrong GPIO/PWM writes can make hardware behave strangely. Use the status
  command first and change one thing at a time.

## Troubleshooting

Check which copy is being run:

```bash
command -v asustorctl
command -v fanspeed
command -v nas-status
command -v nas-fand
command -v cloud-nas-status
command -v cloud-nas-sync-now
command -v cloud-nas-watch
command -v cloud-nas-progress
```

They should normally be:

```text
/usr/local/bin/asustorctl
/usr/local/bin/fanspeed
/usr/local/bin/nas-status
/usr/local/bin/nas-fand
/usr/local/bin/cloud-nas-status
/usr/local/bin/cloud-nas-sync-now
/usr/local/bin/cloud-nas-watch
/usr/local/bin/cloud-nas-progress
```

Verify the installed scripts match the repo:

```bash
cd ~/GitHub/asustor-nas-control
cmp -s scripts/asustorctl /usr/local/bin/asustorctl && echo asustorctl-ok || echo reinstall-asustorctl
cmp -s scripts/fanspeed /usr/local/bin/fanspeed && echo fanspeed-ok || echo reinstall-fanspeed
cmp -s scripts/nas-status /usr/local/bin/nas-status && echo nas-status-ok || echo reinstall-nas-status
cmp -s scripts/cloud-nas-status /usr/local/bin/cloud-nas-status && echo cloud-nas-status-ok || echo reinstall-cloud-nas-status
cmp -s scripts/cloud-nas-sync-now /usr/local/bin/cloud-nas-sync-now && echo cloud-nas-sync-now-ok || echo reinstall-cloud-nas-sync-now
cmp -s scripts/cloud-nas-watch /usr/local/bin/cloud-nas-watch && echo cloud-nas-watch-ok || echo reinstall-cloud-nas-watch
cmp -s scripts/cloud-nas-progress /usr/local/bin/cloud-nas-progress && echo cloud-nas-progress-ok || echo reinstall-cloud-nas-progress
```

Read current fan/PWM state:

```bash
asustorctl fan status
asustorctl pwm list
```

If a write command prompts for a password, that is expected. It is writing to
root-owned sysfs files such as:

```text
/sys/devices/platform/asustor_it87.*/hwmon/hwmon*/pwm1
```
