# Fan control and the front LCD

Two things this board does not do for itself on Linux: regulate its own fan,
and put anything on its own front panel.

```bash
nas-fand --status          # temperatures, PWM, RPM -- read-only, no root
nas-fand --check           # validate the config and print the curve as a table
nas-lcd-banner --check     # what would be written, touching no hardware
```

Both are installed and **enabled** by `scripts/install.sh`.

## Why there is a fan daemon and not just `pwm1_enable=2`

The IT8625 can regulate its own fans from its own thermal inputs. On this board
those inputs are not connected:

```console
$ for t in /sys/class/hwmon/hwmon3/temp*_input; do echo "$t $(cat $t)"; done
/sys/class/hwmon/hwmon3/temp1_input -128000
/sys/class/hwmon/hwmon3/temp2_input -128000
/sys/class/hwmon/hwmon3/temp3_input -128000
```

(`nas-fand --status` will not show you those rows — it lists only sensors it
would actually use, and −128 °C is outside the plausibility band. That is the
point of the band, but it does mean the raw files are where you go to see the
evidence.)

Handing the chip control would mean regulating against a sensor that does not
exist, and the safe-looking direction of that failure is the fan idling while
the CPU cooks. So the chip stays in manual mode (`pwm1_enable=1`) and the curve
lives in `nas-fand`, driven by sensors that are real — `coretemp`, the NVMe
controllers, the NICs. The hottest reading wins, whatever it belongs to: on a
NAS a cooking NVMe controller deserves the fan as much as the CPU does.

The dead inputs are excluded by a plausibility band (`0..150 °C`), not by naming
the chip, so the same daemon works on a board where they *are* wired.

**What it was doing before.** The board shipped in manual mode pinned at
`pwm1=51` — 20 %, 770 RPM — and never ramped, whatever the temperature. The
package sat at 73–80 °C at idle. At full speed the same box measures 58 °C.

## The curve

Points are `tempC:pwm`, ascending, interpolated linearly between and clamped
outside. The default:

```text
FAN_CURVE="50:60 60:120 70:200 78:255"

   50 C  pwm  60  (23%)      70 C  pwm 200  (78%)
   60 C  pwm 120  (47%)      78 C  pwm 255  (100%)
```

It leans cool rather than quiet, because the alternative on this box was 80 °C
at idle. To trade heat for silence move the temperatures up
(`"60:60 70:120 78:200 85:255"`); to go the other way move them down. Keep the
first PWM at or above 60 — the fan is known to spin there, and a fan that stalls
reports 0 RPM and moves no air at all.

At or above `FAN_CRIT_TEMP` (85 °C) the curve is ignored and the fan goes to
full.

**Hysteresis.** Ramping up is immediate; slowing down requires the temperature
to have fallen `FAN_HYSTERESIS` degrees (4) below the *peak* seen since the
level was last changed. Without this the fan audibly oscillates around every
curve point, which is the most common complaint about fan daemons.

## The refresh timer

`lcd-banner.service` writes the panel during the boot. `lcd-banner-refresh.timer`
runs the same banner again 90 seconds later, from *outside* the boot
transaction, and exists for one reason: `systemctl is-system-running` cannot
answer "degraded" while the boot is still in progress, and a unit that is itself
part of the boot transaction cannot wait for it to finish — `--wait` blocks on a
job queue that the waiting unit is holding open. It waits on itself until
systemd's start timeout kills it, and the panel gets nothing at all.

So the boot-time banner reports what is answerable immediately: the count of
units already failed, which is valid at any moment, and otherwise the address.
The timer catches anything that fails after the panel was first written.

`--simulate` replays a sequence of temperatures through the real decision code,
reading no sensor and writing nothing. It is how the curve and the hysteresis
are tested, and it is the right way to check a curve change before trusting a
fan to it:

```console
$ nas-fand --simulate 62 70 69 68 67 66 60
TEMP    PWM     %      ACTION
62C     136     53%    curve, ramp up
70C     200     78%    curve, ramp up
69C     200     78%    hold (curve says 192, peak seen 70C)
68C     200     78%    hold (curve says 184, peak seen 70C)
67C     200     78%    hold (curve says 176, peak seen 70C)
66C     168     65%    curve, fell 4C from 70C
60C     120     47%    curve, fell 4C from 66C

$ FAN_CURVE="60:60 70:120 78:200 95:255" nas-fand --simulate 60 70 80 86
```

A 2 °C sawtooth around a curve point produces no change at all after the first
climb, which is the property that matters for a machine you sit next to.

Everything is in `/etc/nas-fan/nas-fan.conf`; `scripts/nas-fan.conf.example` is
the annotated copy.

## What it does when the hardware misbehaves

The daemon assumes nothing about the chip staying where it was put.

- **Every write is verified by reading it back.** A write to sysfs can return
  success and still not be what the chip ends up holding, and "I told it to" is
  not the same claim as "it is".
- **A failed write is not recorded as applied.** Otherwise the next cycle sees
  nothing to do, and the fan stays exactly as slow as it already was while the
  log claims a retry is coming.
- **Drift is re-asserted.** Each cycle reads back the duty and the mode; if
  something else has moved either — firmware, another tool, a module reload —
  the daemon says so and puts it back. This box was *found* in mode 0.
- **The controller is re-resolved if it disappears.** `asustor_it87` can be
  reloaded, and the hwmon directory number moves when it is.
- **Sensor reads are bounded** by `FAN_READ_TIMEOUT` (5 s). A wedged NVMe or
  SMBus controller can block a sysfs read indefinitely, and a control loop
  parked in `cat(1)` leaves the fan frozen wherever it was.
- **No usable sensor means full speed**, not "keep the last value".

`FAN_CURVE` is rejected if its duty falls as temperature rises — that is the one
misconfiguration that actively cooks the machine — and if the temperatures are
not ascending, if a PWM exceeds 255, or if fewer than two points are given.

## Stopping the service spins the fan up

Every exit path — clean stop, crash, `SIGKILL`, a config that fails validation —
drives the fan to `FAN_FAILSAFE_PWM`, which is 255.

The daemon traps its own exit, and `ExecStopPost=/usr/local/bin/nas-fand
--failsafe` repeats it from the outside for the `SIGKILL` case that never
reaches a trap. `ExecStartPre=nas-fand --check` means a configuration that would
misdrive a fan stops the unit from starting rather than being discovered at
85 °C — and `--check` genuinely fails on a missing chip, a missing PWM, no
usable sensor, or a PWM that root cannot write.

`StartLimitIntervalSec=300` / `StartLimitBurst=5` let a permanently broken
daemon give up rather than restart every five seconds forever. Giving up is safe
here precisely because `ExecStopPost` has already driven the fan to full: the
box is left loud and obvious, and `nas-status` reports it.

This is deliberate. A fan daemon that is not running must leave a NAS loud, not
silent: silence is the failure you find out about when a disk has already died.
If you want the fan quiet, stop the daemon *and* set a PWM by hand —
`asustorctl fan speed 40%` — rather than expecting the stop to do it for you.

## The front LCD

A 2 × 16 character panel on an internal UART, driven by an MCU that has nothing
to do with `asustorctl` (which does LEDs, fans and the backlight).

**The port.** COM2 on the same IT8625 Super I/O as the fan controller — ACPI
path `\_SB_.PC00.LPCB.SIOI.COM2`, io `0x2F8`, irq 3. On this box that is
`/dev/ttyS1`, but 32 `ttyS` nodes exist and only three are real UARTs, so the
udev rule matches on the hardware address instead of the name. `LCD_PORT`
defaults to `/dev/asustor-lcm` when the rule has created it and falls back to
`/dev/ttyS1` otherwise, so the symlink is actually used rather than merely
existing:

```text
SUBSYSTEM=="tty", KERNEL=="ttyS[0-9]*", ATTR{port}=="0x2F8", ATTR{type}=="4", \
  GROUP="lcm", MODE="0660", SYMLINK+="asustor-lcm"
```

`type==4` is `PORT_16550A`, which excludes the phantom nodes the 8250 driver
registers. The rule creates `/dev/asustor-lcm`, which survives renumbering.

**Permission.** The installer creates a system group `lcm` and adds the
invoking user to it. Log in again, or `newgrp lcm`, for it to take effect —
`lcd-banner.service` runs as root and needs none of this.

Deliberately not used: the `uucp` group, which would hand over every serial
device on the machine including COM1 and any USB serial adapter plugged in
later; a non-system group, which udev warns about and upstream intends to stop
supporting; and `TAG+="uaccess"`, because SSH sessions have no seat so the ACL
never lands.

**The protocol**, verified against `mafredri/lcm`, `phjz/AS6704T`, the tangrs
Lockerstor Gen2 write-up, and ASUSTOR's own captured `lcmd` traffic:

```text
frame = TYPE LEN FUNC [DATA...] CSUM
  TYPE  F0 command, F1 reply
  LEN   counts DATA only, so a frame is 3 + LEN + 1 bytes
  CSUM  plain 8-bit sum of every preceding byte

set text = FUNC 27, LEN 12 (18 = line + indent + 16 chars):
  F0 12 27 <line> <indent> <16 ASCII, space-padded> <csum>

"ArchNAS" on the top row:
  F0 12 27 00 00 41 72 63 68 4E 41 53 20 20 20 20 20 20 20 20 20 A9
```

The panel replies `F1 01 27 00 19` on success and `F1 01 27 04 1D` on error, and
sends unsolicited button presses (`F0 01 80 <1-4> <csum>`) at any time.
`lcdline` does not read replies — binary reads in bash are more fragile than the
problem deserves — so it drains the receive buffer before writing and re-sends
each frame `--retry` times instead. That is adequate for a banner written once
per boot; anything writing on every sync cycle should read ACKs, or become a
client of a daemon that does.

## The boot banner

`lcd-banner.service` is a oneshot ordered after `multi-user.target` and
`network-online.target`, which is what lets the bottom row report on the boot
that just finished:

```text
  ArchNAS
  192.168.0.212
```

Top row is `LCD_LINE0`, defaulting to the hostname. Bottom row is `LCD_LINE1`,
defaulting to `auto`: the address you would SSH to, or — when systemd reports
the boot as degraded — `DEGRADED n fail`.

Getting that second case to be reachable takes a little care. The unit is part
of the boot transaction, so a plain `systemctl is-system-running` answers
`starting` every time and the degraded branch could never fire. The banner uses
`is-system-running --wait`, which blocks until the boot actually settles, under
a `LCD_BOOT_WAIT` timeout (90 s) so a hung unit elsewhere cannot hold the panel
blank indefinitely. A front panel that can say "degraded"
is most of the reason to have a front panel on a headless box. Set
`LCD_LINE1=""` for a blank row, or any fixed string.

**Shutdown matters.** `ExecStop` blanks the panel and drops
`/sys/class/leds/power:lcd/brightness`. Without that power cycle the MCU keeps
displaying the last message while the box is off — it looks powered when it is
not — and does not re-initialise on the next boot. Budget ~6 s after a power
cycle before the panel accepts frames; the unit's `LCD_SETTLE=5` covers a fast
boot.

Do **not** drive the panel's power with `gpioset` on IT87 line 59. That line
*is* `power:lcd` and is already claimed by `leds-gpio`, so it returns `EBUSY`,
and `/dev/gpiochip*` are `0600 root:root` besides.

## Front-panel LEDs

`green:status` can read `brightness=1`, `trigger=[none]` — solid on, as far as
Linux is concerned — and still visibly blink. Nothing in `/sys/class/leds` shows
why, because the blinking is not the LED subsystem's doing:

```console
$ nas-leds --show
blink masks:
  gpled1_blink         47          # bitmask of GPIO LEDs the IT8625 blinks
  gpled1_blink_freq    1 (0.5s OFF 0.5s ON)
leds:
  green:status           brightness=1    trigger=none
```

The IT8625 blinks those LEDs in hardware from its own GPIO register, over the
top of whatever brightness the kernel has set. Clearing the mask hands each LED
back to its brightness value, which is what makes "on" mean on:

```bash
nas-leds --show     # what the panel is doing now
nas-leds --check    # what would be written
```

`nas-leds.service` applies the policy at boot — both controls are volatile.
Defaults are `LED_BLINK1=0`, `LED_BLINK2=0`, and
`LED_ON="green:status blue:power power:front_panel power:lcd"`. The factory
value of group 1 on this box is **47**; set `LED_BLINK1=47` in
`/etc/nas-leds/nas-leds.conf` to put the blinking back.

LEDs driven by a trigger are left alone unless named: `sata*:green:disk` use
`disk-activity` and `red:status` uses `panic`, and forcing those on would fight
the trigger.

## Recovery

```bash
# 1. Unwedge the MCU (fflush, sent twice)
printf '\xf0\x01\x00\x00\xf1\xf0\x01\x00\x00\xf1' > /dev/asustor-lcm

# 2. Logical display cycle
printf '\xf0\x01\x11\x00\x02' > /dev/asustor-lcm; sleep 1
printf '\xf0\x01\x11\x01\x03' > /dev/asustor-lcm

# 3. Real panel power-cycle, no reboot needed        [root]
echo 0 | sudo tee /sys/class/leds/power:lcd/brightness; sleep 1
echo 1 | sudo tee /sys/class/leds/power:lcd/brightness; sleep 6
systemctl restart lcd-banner
```

If the backlight responds but serial stays silent, the panel is alive and only
the link is stuck — go back to step 1.

No frame in this protocol writes firmware or a persistent setting, so the risk
here is a confused panel, not a broken one. Do not fuzz opcodes outside
`{00,11,12,13,21,22,23,25,26,27,80}`; that is the only place unknown behaviour
could plausibly live.

## Where this shows up in `nas-status`

```text
== THERMAL ==
  hottest   58 C  (coretemp/Core 1)
  fan       pwm1=120 (47%)  1840 RPM  manual
  control   nas-fand.service  active  enabled
```

`nas-status` exits 1 at `NAS_STATUS_TEMP_WARN_C` (78) and 2 at
`NAS_STATUS_TEMP_CRIT_C` (85), and exits 1 if `nas-fand` is installed but not
running — the state that put this box at 80 °C to begin with.
