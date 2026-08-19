# AS6704 Observed State

Ground truth for `ArchNAS`, an ASUSTOR Lockerstor 4 Gen 2 AS6704T (Intel Celeron
N5105, Jasper Lake) running Arch Linux instead of ADM. Everything here was
measured on the machine, not taken from a datasheet.

Last verified 2026-08-19.

## Platform

```text
modules: asustor, asustor_it87, asustor_gpio_it87, leds_gpio, gpio_keys_polled
hwmon:   /sys/devices/platform/asustor_it87.2608/hwmon/hwmon3
chip:    it8625
```

**The hwmon index is not stable.** It is assigned in probe order, so `hwmon3` is
this boot's answer and not a contract. Every script here finds the controller by
reading `name` and matching `it8625`/`it87`/`asustor_it87`. Writing a fan PWM to
whatever `hwmon3` happens to be next boot is how you throttle an NVMe controller
by accident.

## Fan

```text
fan1_input   the only fan actually wired
fan2_input   0 RPM
fan3_input   0 RPM
pwm1         drives fan1
pwm2..pwm6   present, drive nothing on this board
```

`pwmN_enable` semantics for this chip: **0 = full on, 1 = manual, 2 = chip
automatic**.

The board was found in **manual mode pinned at `pwm1=51`** — 20 %, ~770 RPM —
never ramping whatever the temperature. `pwm1_enable=1` is *manual*, not
automatic; nothing on this system owned a fan curve until `nas-fand`.

## Thermal — and why the chip cannot regulate itself

```text
it8625   temp1_input   -128000     not connected
it8625   temp2_input   -128000     not connected
it8625   temp3_input   -128000     not connected
```

All three of the IT8625's own thermal inputs read **−128 °C**. Handing the chip
`pwm1_enable=2` would regulate the fan against sensors that do not exist, and the
safe-looking direction of that failure is the fan idling while the CPU cooks.
This is the single most important fact on this page and the entire reason
`nas-fand` exists.

Real temperatures come from elsewhere:

```text
coretemp        Package id 0, Core 0..3      the CPU
nvme            Composite  x2                the two NVMe controllers
r8169_*         temp1      x2                the two NICs
acpitz_0        temp1                        chassis ambient
```

### Measured envelope

| condition | package |
| --- | --- |
| ambient (`acpitz`) | 27 °C |
| idle, fan 30–44 % (1187–1459 RPM), 574 samples over 48 min | **53.5 °C avg** (51–58) |
| idle, fan 100 % (2636 RPM) | 58 °C |
| under load, fan 20 % (768 RPM) | 79–80 °C |
| `Package id 0` critical | 105 °C |

The CPU sits roughly **30 °C above ambient at idle regardless of fan speed** — a
passive heatsink on a 10 W part in a NAS chassis. Across the 28–44 % range the
package temperature is flat at 53.5–53.8 °C. Fan speed buys almost nothing at
idle and a great deal under load (58 °C against 79 °C), so a curve should be
chosen for what it does when the box is busy.

The practical floor is the **mid-50s °C**. Any temperature setpoint below that
saturates a controller at 100 % and is unreachable by moving air.

## LEDs

```text
blue:lan            blue:power          green:status        green:usb
power:front_panel   power:lcd           red:power           red:status
sata{1..4}:green:disk                   sata{1..4}:red:disk
```

Triggers in use: `sata*:green:disk` → `disk-activity`, `red:status` → `panic`.
Everything else is `none`.

**Blinking is not the LED subsystem.** `green:status` can read `brightness=1`,
`trigger=[none]` — solid on, as far as Linux is concerned — and still visibly
blink, because the IT8625 blinks it in hardware from its own GPIO register, over
the top of whatever brightness the kernel set:

```text
gpled1_blink        47      factory value: bitmask of GPIO LEDs the chip blinks
gpled1_blink_freq   1       0.5s off / 0.5s on
gpled2_blink        0
```

Nothing under `/sys/class/leds` shows that. `nas-leds` clears the mask so each
LED follows its brightness; both controls are volatile and re-applied at boot.

`power:lcd` is **IT87 GPIO line 59**, already claimed by `leds-gpio` — `gpioset`
on it returns `EBUSY`, and `/dev/gpiochip*` are `0600 root:root`. Use the LED
node. Its trigger is `none`, so once something writes 0 only userspace restores
it.

## Front LCD

A 2 × 16 character panel on an internal UART, driven by an MCU independent of
`asustorctl`.

```text
/dev/ttyS1     port 0x2F8   type 4 (PORT_16550A)   irq 3
ACPI path      \_SB_.PC00.LPCB.SIOI.COM2
```

COM2 on the same IT8625 Super I/O as the fan controller. **32 `ttyS` nodes exist
and only three are real UARTs** (`ttyS0` 0x3F8, `ttyS1` 0x2F8, `ttyS4` LPSS
MMIO), which is why the udev rule matches on the hardware address rather than
the node name. The node is `root:uucp 0660` out of the box — EACCES for read
*and* write — so even a passive listen needs the group fix.

Protocol, frames and recovery: [`thermal-and-lcd.md`](thermal-and-lcd.md).

## Storage

```text
LABEL=NAS_01   sdb1          447G   ext4   /srv/NAS_01
LABEL=NAS_02   nvme0n1p1     1.8T   ext4   /srv/NAS_02
LABEL=NAS_03   nvme1n1p1     1.8T   ext4   /srv/NAS_03
```

Mounted from `/etc/fstab` with `nofail`. They previously lived under
`/run/media/atdang/`, which is a tmpfs — a failed mount there filled RAM. Under
`/srv` the same failure writes to the root filesystem: still wrong, but visible
and bounded. `nas-mount-migrate` performs the relocation.

## Notes

- The fan helper defaults to `pwm1`. Override with `ASUSTOR_FAN_PWM=2 fanspeed 180`.
- `hostname(1)` is not installed on this system; use `uname -n`.
- `dmesg` is restricted (`kernel.dmesg_restrict=1`) and `/proc/tty/driver/serial`
  needs root, so serial identification goes through `/sys/class/tty/ttyS*/`.
