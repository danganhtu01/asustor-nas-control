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

The installer copies commands into `/usr/local/bin`, so it uses `sudo`.

For a local user-only test without installing:

```bash
./scripts/asustorctl status
./scripts/fanspeed 200
```

## Common Commands

Set the primary fan PWM value to `200`:

```bash
fanspeed 200
```

Use a percent instead:

```bash
fanspeed 70%
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

Set the primary fan mode:

```bash
asustorctl fan mode manual
asustorctl fan mode auto
```

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

## Notes

- `fanspeed 200` means raw PWM value `200`, on a `0..255` scale.
- The script defaults to PWM channel `1`, matching the observed AS6704 fan.
- Override the channel with `ASUSTOR_FAN_PWM=2 fanspeed 180`.
- Write operations require root because sysfs hardware controls are root-owned.
- Wrong GPIO/PWM writes can make hardware behave strangely. Use the status
  command first and change one thing at a time.

## Publish This Repo

This machine did not have GitHub CLI auth or SSH auth available when the repo
was created. To publish it later:

```bash
sudo pacman -S github-cli
gh auth login
gh repo create danganhtu01/asustor-nas-control --public --source . --remote origin --push
```

Or create an empty repository at GitHub, then:

```bash
git remote add origin git@github.com:danganhtu01/asustor-nas-control.git
git push -u origin main
```

