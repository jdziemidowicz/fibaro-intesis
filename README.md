# fibaro-intesis

A Fibaro QuickApp for controlling [Intesis WiFi AC gateways](https://www.intesis.com/products/ac-interfaces/wifi-controllers) from a Fibaro Home Center 3.

This is a from-scratch replacement for the IntesisAC QuickApp from the Fibaro Marketplace.

## Improvements over the Marketplace QuickApp

- **Persistent connection:** one TCP connection is kept open and reused, instead of a new connection for every command.
- **Instant updates:** the gateway pushes state changes as they happen, instead of the QuickApp polling each setting in a 10–12 s cycle. Changes made with the IR remote show up in Fibaro immediately.
- **Security support:** works with the gateway's security level `ALL`, using PIN login and an AES-128 encrypted session.
- **Proper offline handling:** the device is marked dead in Fibaro when the gateway is unreachable and reconnects automatically.
- **Gateway clock sync:** the gateway's date and time are set from the HC3 on every connect.
- **Simpler setup:** only the `IP` variable, plus `PIN` if security is enabled.
- **Native UI:** uses Fibaro's built-in thermostat tile, with two extra buttons for vane and fan speed.

## Features

- Control AC mode: Cool, Fan, Dry, Heat, Auto, Off
- Set temperature setpoint (18–30°C)
- Adjust vane/louver position (Auto, Swing)
- Control fan speed (Auto, 1, 2, 3, 4)
- Real-time, push-based status updates
- PIN-based authentication with AES-128 encrypted communication

## Requirements

- Fibaro Home Center 3
- Intesis WiFi AC gateway accessible on the local network (TCP port 3310)
- Device PIN (only if security level is set to `ALL`)

## Installation

1. Download `intesis-ac.fqa` from the [latest release](../../releases/latest).
2. In Fibaro Home Center 3, go to **Devices** → **Add Device** → **Upload QuickApp**.
3. Upload the `.fqa` file.
4. Open the QuickApp's **Variables** panel and configure:

   | Variable | Required | Description |
   |----------|----------|-------------|
   | `IP`     | Yes      | IP address or hostname of the Intesis gateway |
   | `PIN`    | No       | Device PIN (only needed if security is enabled) |

5. Save and restart the QuickApp. The AC unit will appear as a thermostat device.

## Building from Source

Requires [`jq`](https://jqlang.github.io/jq/).

```bash
# Ubuntu/Debian
sudo apt-get install jq

# macOS
brew install jq

# Build the .fqa package
make
```

This assembles `main.lua`, `aes.lua`, `md5.lua`, and `pin.lua` into `intesis-ac.fqa`.

## Security Level Configuration

The Intesis gateway supports three security levels: `NONE`, `CFGONLY`, and `ALL`. If you need to change the security level, use the included Python utility:

```bash
pip install pycryptodome
python3 intesis_securitylevel.py <device_ip> <pin> <NONE|CFGONLY|ALL>
```

Example:
```bash
python3 intesis_securitylevel.py 192.168.1.100 12345678 ALL
```

## Protocol

The QuickApp communicates using the **Intesis WMP (WiFi Module Protocol)** over TCP port 3310.

- On connect, the QuickApp sends `ID` to learn the gateway's MAC address and security level, then logs in if needed.
- Pre-login traffic is plain text.
- Post-login traffic is AES-128-CBC encrypted with a session key derived from the device PIN and MAC address.
- After login, the current state is read once. From then on the gateway pushes `CHN,…` notifications whenever something changes.
- Commands are serialized: each one waits for the previous response before it's sent.
- A `PING` is sent every 10 seconds to keep the connection alive.
- On connection loss, the device is marked dead and the QuickApp automatically reconnects after 30 seconds.
