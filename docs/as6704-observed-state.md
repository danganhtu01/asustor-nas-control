# AS6704 Observed State

Observed on `ArchNAS`, ASUSTOR Lockerstor Gen 2 AS6704:

```text
modules: asustor, asustor_it87, asustor_gpio_it87, leds_gpio, gpio_keys_polled
hwmon:   /sys/devices/platform/asustor_it87.2608/hwmon/hwmon3
chip:    it8625
fan:     fan1_input
pwm:     pwm1 appears to control the main fan
```

Current ASUSTOR LEDs exposed by the platform driver:

```text
blue:lan
blue:power
green:status
green:usb
power:front_panel
power:lcd
red:power
red:status
sata1:green:disk
sata1:red:disk
sata2:green:disk
sata2:red:disk
sata3:green:disk
sata3:red:disk
sata4:green:disk
sata4:red:disk
```

The fan helper defaults to `pwm1`. Override it with:

```bash
ASUSTOR_FAN_PWM=2 fanspeed 180
```

