# PiKVM-Docker

[日本語](README.ja.md)

Build scripts and configuration for running PiKVM's kvmd in a container, with switching between several targets.

I already had a Raspberry Pi doing other work, and several headless machines that need a keyboard and a screen before an OS is up. Rather than buy a PiKVM for each of them, or a hardware KVM switch, I gave the job to the Pi that was already there.

## Features

- **Switch targets from the web UI.** One button per target. The connection drops and comes back within a few seconds. Stream and HID settings adjusted in the web UI reset on a switch, so put the ones you want kept in `config/override.yaml`.
- **Broken targets are skipped at startup.** A target whose devices will not open is passed over, so a bad one cannot put the container in a restart loop.
- **The selected target is remembered** across restarts and rebuilds. If its devices stop working, the first working target is used instead.
- **Runs unprivileged.** No `--privileged` and no added Linux capability. [OTG mode](#otg-mode) is the only exception.
- **[ATX power control](#atx-power-control)** (optional). Power on, force off, and reset a target.
- **[OTG mode](#otg-mode)** (optional). Show a disk image to a machine as a USB drive.

## Requirements

- Raspberry Pi 4 Model B or 5, aarch64, with USB HDMI capture — the `hdmiusb` platform.
- One USB HDMI capture dongle and one CH9329 USB-serial HID adapter per target.
- Docker 28.0.0 or newer: `docker version --format '{{.Server.Version}}'`.
- cgroup v2: `stat -fc %T /sys/fs/cgroup` must print `cgroup2fs`.

## Build

Extract a rootfs from PiKVM's published disk image. It needs root:

```sh
sudo ./build.sh --platform v2-hdmiusb-rpi4   # or v2-hdmiusb-rpi5
```

`--version` builds a specific PiKVM release instead of the newest one. The published dates are listed under [files.pikvm.org](https://files.pikvm.org/images/). Running it with an earlier date is also how you undo an update; your settings, the login and the selected target are unaffected.

```sh
sudo ./build.sh --platform v2-hdmiusb-rpi4 --version 20260831
docker compose up -d --build
```

`--image` builds from a copy you already have:

```sh
sudo ./build.sh --image ~/v2-hdmiusb-rpi4-aarch64-20260831.img.xz
```

## Usage

### 1. Describe the targets, and make a settings file

```sh
cd config
cp targets.conf.example targets.conf
cp override.yaml.example override.yaml
vim targets.conf
```

`targets.conf`'s format is described in [Configuring targets.conf](#configuring-targetsconf). `override.yaml` holds this deployment's kvmd settings and may stay empty; PiKVM's [settings documentation](https://docs.pikvm.org/config/) lists what can go in it.

### 2. Start it

```sh
docker compose up -d
```

The web UI is then at `https://<your Pi>:8443/`. Change the port in `compose.yml`.

Log in with `admin` / `admin`, and change it before the container is reachable from anywhere you do not control:

```sh
docker exec -it pikvm kvmd-htpasswd set admin
```

The new password is written to the `pikvm-state` volume, so it survives restarts and rebuilds, and is lost if you delete that volume. PiKVM's [authentication documentation](https://docs.pikvm.org/auth/#changing-the-kvm-password) covers the rest, including two-factor authentication.

To add or change a target later, edit `config/targets.conf` and run `docker compose restart`.

## Configuring targets.conf

One target per line, columns separated by whitespace. `#` starts a comment and blank lines are ignored.

| Column | Description |
| :--- | :--- |
| `<name>` | Must match `^[a-z0-9][a-z0-9-]*$`. |
| `<video-device>` | The capture device's `by-path` name, as it appears on the host. |
| `<hid-device>` | The CH9329 adapter's `by-id` name, as it appears on the host. |
| `[label]` | Optional. What the button in the web UI says. Everything left on the line, so spaces are fine. Defaults to `<name>`. |

```
# name       video device                                                     hid device                                        label
workstation  /dev/v4l/by-path/platform-xhci-hcd.1-usb-0:1.4:1.0-video-index0  /dev/serial/by-id/usb-1a86_USB_Serial-if00-port0  Workstation
nas          /dev/v4l/by-path/platform-xhci-hcd.1-usb-0:1.3:1.0-video-index0  /dev/serial/by-id/usb-Prolific_Tech...-if00-port0  NAS
```

The first target listed is the default. It is selected on first start, and selected again whenever the previously used target's devices stop working.

List the names present on the host with `ls -l /dev/v4l/by-path/` and `ls -l /dev/serial/by-id/`, and write them as they appear there. Do not use `/dev/video0` or `/dev/ttyUSB0`: those numbers are handed out in enumeration order, so a replug or a reboot can move one onto another target's hardware.

## What can differ per target

Every target has its own screen, keyboard and mouse. Everything else is shared.

| | Per target |
| :--- | :--- |
| HDMI capture | Yes |
| CH9329 keyboard and mouse | Yes |
| ATX power control | No — one set of GPIO pins, driving the one machine wired to them |
| OTG mass storage | No — one USB device port, serving the one machine cabled to it |

For power control on more than one machine, use user-GPIO buttons on separate pins instead of the built-in ATX widget — see [Adding your own GPIO buttons](#adding-your-own-gpio-buttons).

## ATX power control

kvmd can press a target's power and reset switches and read its power LED through the Pi's GPIO pins. PiKVM's [ATX documentation](https://docs.pikvm.org/atx_board/) covers the wiring.

The GPIO chip's device major differs between hosts and can change with a kernel update, so it has to be looked up and written in.

### 1. Read the major number, and check the chip's group

```sh
$ ls -la /dev/gpiochip0
crw-rw---- 1 root gpio 254, 0 Sep  1 12:00 /dev/gpiochip0
#                 ^^^^ ^^^
#                 |    major number
#                 owning group
```

The chip must not be owned by group `root`. If it is, give it a group of its own on the host:

```sh
sudo groupadd pikvm-gpio
echo 'SUBSYSTEM=="gpio", KERNEL=="gpiochip0", GROUP:="pikvm-gpio", MODE:="0660"' \
  | sudo tee /etc/udev/rules.d/10-pikvm-gpiochip.rules
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=gpio
```

Give it a name of its own rather than the conventional `gpio`. Raspberry Pi images ship rules that hand `gpio` the board's second GPIO chip, `/dev/gpiomem` and the sysfs GPIO and PWM trees as well, and those rules start applying the moment a group by that name exists.

Create the group before writing the rule: udev discards a rule naming a group it cannot resolve.

### 2. Allow that major in `compose.yml`

```yaml
    device_cgroup_rules:
      - 'c 81:* rmw'
      - 'c 166:* rmw'
      - 'c 188:* rmw'
      - 'c 254:* rmw'   # gpiochip — recheck after every kernel update
```

### 3. Turn ATX on in `config/override.yaml`

The container sees the host's `/dev` as `/hostdev`, so name the chip there:

```yaml
kvmd:
    atx:
        type: gpio
        device: /hostdev/gpiochip0
```

The pin numbers default to PiKVM's standard wiring — power switch on BCM 23, reset switch on BCM 27, power LED on BCM 24, HDD LED on BCM 22. If yours differs, add `power_switch_pin`, `reset_switch_pin`, `power_led_pin` and `hdd_led_pin` to the same file.

### 4. Apply it

`compose.yml` changed, so a restart is not enough:

```sh
docker compose up -d
```

Repeat steps 1 and 2 after a kernel update, since the number can change.

## Adding your own GPIO buttons

kvmd's user-GPIO puts buttons in the web UI that do something when pressed — send a wake packet, drive a relay, run a command. The target buttons are on that same view, and you can add your own beside them. PiKVM's [GPIO documentation](https://docs.pikvm.org/gpio/) lists every available driver.

### 1. Define the channel in `config/override.yaml`

A channel is a [driver](https://docs.pikvm.org/gpio/#drivers) plus a [scheme](https://docs.pikvm.org/gpio/#scheme) entry that names it. This one sends [Wake-on-LAN](https://docs.pikvm.org/gpio/#wake-on-lan):

```yaml
kvmd:
    gpio:
        drivers:
            wol_workstation:
                type: wol
                mac: ff:ff:ff:ff:ff:f1
        scheme:
            b_wol:
                driver: wol_workstation
                pin: 0
                mode: output
                switch: false
```

### 2. Put it on the view, in the same file

A [view](https://docs.pikvm.org/gpio/#view) row is a list of cells: `#text` is a heading, `channel|text` is a button. The target buttons go above your rows, in a section of their own.

```yaml
kvmd:
    gpio:
        view:
            table:
                - ["#Power"]
                - ["b_wol|Wake workstation"]
```

### 3. Apply it

```sh
docker compose restart
```

## OTG mode

OTG mode lets you upload a disk image through the web UI and show it to a machine as a USB drive — an OS installer, for instance. It is kvmd's [mass storage drive](https://docs.pikvm.org/msd/) feature, and it is the one mode that runs the container privileged.

Keyboard, mouse and video keep working while OTG is on. The drive is not tied to the selected target: it appears on whichever machine is cabled to the Pi's USB device port, and the Pi has only one.

### Turning it on

```sh
docker compose -f compose.yml -f compose.otg.yml up -d
```

Upload and mount images from the web UI's Drive menu.

### Turning it off

```sh
docker compose up -d
```

## Logs

Startup and target switches appear in `docker logs`:

```sh
docker compose logs -f
```

kvmd's own output stays in the container's journal, and is gone once the container is recreated:

```sh
docker compose exec pikvm journalctl -u kvmd.service -f
```

## Contributing

Issues and pull requests are welcome.

## License

[MIT](LICENSE)
