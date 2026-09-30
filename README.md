```
██████╗ ███████╗██╗     ██╗   ██╗ ██████╗██╗   ██╗██╗  ██╗
██╔══██╗██╔════╝██║     ██║   ██║██╔════╝╚██╗ ██╔╝╚██╗██╔╝
██║  ██║█████╗  ██║     ██║   ██║██║      ╚████╔╝  ╚███╔╝
██║  ██║██╔══╝  ██║     ██║   ██║██║       ╚██╔╝   ██╔██╗
██████╔╝███████╗███████╗╚██████╔╝╚██████╗   ██║   ██╔╝ ██╗
╚═════╝ ╚══════╝╚══════╝ ╚═════╝  ╚═════╝   ╚═╝   ╚═╝  ╚═╝
```

# delucyx

**LAN access control for macOS** — cut or intercept connections on your local network with ARP
spoofing. A background daemon does the work; a terminal UI (`delucyx`), a menubar app, and a CLI
drive it. Nothing is ever cut until you explicitly enable it.

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?style=flat-square)
![daemon](https://img.shields.io/badge/daemon-BPF%20%2F%20root-red?style=flat-square)
![ipc](https://img.shields.io/badge/IPC-protocol%203-58a6ff?style=flat-square)
![tui](https://img.shields.io/badge/TUI-Bun%20%2B%20OpenTUI-f472b6?style=flat-square)
![version](https://img.shields.io/badge/version-v1.0.0-green?style=flat-square)

> [!WARNING]
> **For authorized use only.** Use exclusively on networks you own or have written permission to
> test. ARP spoofing cuts real users off the network.

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Build](#build)
- [Quick start](#quick-start)
- [Daemon](#daemon)
- [Terminal UI (TUI)](#terminal-ui-tui)
- [Menubar GUI](#menubar-gui)
- [IPC (protocol 3)](#ipc-protocol-3)
- [How the device list is built](#how-the-device-list-is-built)
- [Legacy interactive menu](#legacy-interactive-menu)
- [CLI mode](#cli-mode)
- [Attack modes](#attack-modes)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Testing](#testing)

## Features

- Auto-detect interface, gateway, and local devices
- Network scan via ARP (active burst + kernel ARP cache)
- **Multi-target mass deauth** — cut multiple devices simultaneously (`3,4,5` or `all`)
- Two attack modes: cut the connection or full MITM
- **Idle by default** — the daemon never cuts anything on its own; every cut is explicitly enabled
- **Background daemon** — runs on boot, survives disconnect/reconnect, holds until you enable it
- **Terminal UI (OpenTUI)** — device list, multi-select, cut/MITM, hold/resume, live status
- **Wi-Fi awareness** — the joined network (SSID, channel, band, RSSI) plus every network the radio
  hears, with signal meters; `w` swaps to the neighbour table
- **Menubar GUI** — native macOS status bar app with live target list and stop/scan controls
- Graceful ARP restore on exit

## Requirements

| Requirement | Why |
|-------------|-----|
| macOS 13+ | BPF and `system_profiler` interfaces used by the daemon |
| Xcode Command Line Tools | `swiftc` + SDK to build |
| `sudo` | BPF needs root; the LaunchDaemon runs privileged |
| [Bun](https://bun.sh) | Only for the terminal UI (`tui/`) |

## Build

```bash
# CLI + daemon binary only
make

# Menubar GUI only
make ui

# TUI dependencies (OpenTUI via Bun)
make tui-deps

# Everything
make && make app

# CLI on PATH + TUI in ~/.delucyx/tui (no sudo)
make install

# Privileged daemon (installs a LaunchDaemon, starts idle/held)
sudo ./build/delucyx install
```

Outputs:

| Path | What |
|------|------|
| `build/delucyx` | CLI + daemon binary |
| `build/DelucyxUI` | Menubar app binary |
| `build/DelucyxUI.app` | App bundle (after `make app`) |
| `tui/` | OpenTUI terminal interface (run with `make tui`) |

## Quick start

```bash
# 1. Build
make && make app

# 2. Install and start the daemon (root, launches idle/held)
sudo ./build/delucyx install

# 3. Install the menubar app to ~/Applications and open it
make install-app

# 4. Optional: terminal UI (needs Bun)
make install-tui
```

The daemon now runs in the background and only **scans** — cutting waits for you. Drive it from the
menubar icon `🛡`, the terminal UI (`delucyx`), or the CLI (`delucyx status`, no root needed).

## Daemon

### Install

```bash
sudo ./build/delucyx install      # or: sudo delucyx install
```

Installs the LaunchDaemon `/Library/LaunchDaemons/com.delucyx.daemon.plist`
(`RunAtLoad` + `KeepAlive`, so it starts on boot and is restarted if it dies). The job is registered
through `launchctl bootstrap`; the staged binary lives at `/usr/local/libexec/delucyx`.

It starts in **`hold`**: nothing is spoofed until you enable it — TUI `c`/`m` + `y`,
`sudo delucyx resume` (every non-gateway device), or the GUI's *Scan Network*.

### Modes

| Mode | Meaning |
|------|---------|
| `hold` | **Default.** Idle: the daemon scans and serves status, but never spoofs |
| `auto` | Enabled explicitly (`delucyx resume`, TUI `u`, GUI *Scan Network*): cut every non-gateway device |
| `manual` | Enabled explicitly (TUI `c`/`m` + confirm): cut exactly the selected targets |

Cutting is **never** automatic. The daemon boots into `hold`, and a network change drops it back to
`hold`, so a running attack is never carried onto another network.

| Event | Action |
|-------|--------|
| Boot / connect to network | Publish interface, SSID and device list; **nothing is cut** (mode `hold`) |
| Disconnect | Stop spoof, restore ARP tables, back to `hold` |
| Reconnect / new network | Back to `hold`; rescan only |
| Spoof thread crashes while enabled | Restart the enabled targets (30 s backoff after a failed start) |
| User stops via TUI/GUI | `hold` — stays idle until `resume` or a TUI/CLI start |
| Failed start (no BPF, no devices) | Retried with 30 s backoff, no scan storm |

### Commands

```bash
sudo ./build/delucyx install      # register + start the LaunchDaemon
sudo ./build/delucyx uninstall    # stop, unregister, remove plist + staged binary
sudo ./build/delucyx upgrade      # hot-reload the running daemon with the staged binary
sudo ./build/delucyx stop all     # stop spoofing (daemon held)
sudo ./build/delucyx hold         # pause auto-spoof
sudo ./build/delucyx resume       # back to auto mode
delucyx status                    # mode, interface, SSID, targets, devices, neighbours
delucyx tui                       # open the terminal UI
```

`install` / `uninstall` / `upgrade` (and the signal fallback) need root. `stop`, `hold`, `resume`,
`status` and `tui` talk to the running daemon over the IPC socket, which is mode `0666` — they work
as a normal user and fall back to signals when the daemon is unreachable.

### Upgrade

```bash
make && sudo ./build/delucyx upgrade
```

Stops the running daemon cleanly (restores ARP tables), stages the new binary and lets launchd
restart it. It prints the resulting PID, so you can tell success from a silent failure.

### Logs

```bash
tail -f /var/log/delucyx.log
sudo truncate -s 0 /var/log/delucyx.log      # clean slate
```

The daemon reopens the file for every line, so truncating while it runs is safe.

### Uninstall

```bash
sudo ./build/delucyx uninstall
```

## Terminal UI (TUI)

```bash
delucyx                    # default entry point (same as `delucyx tui`)
```

Needs [Bun](https://bun.sh) and the `tui/` sources. Install once (no sudo):

```bash
make install      # delucyx → ~/.local/bin, TUI → ~/.delucyx/tui
```

The TUI is a **client of the daemon** — it never needs root, never touches ARP/BPF, and only
*requests* cuts. With no daemon running it shows an onboarding screen: `i` runs
`sudo delucyx install` for you, `r` retries, `q` quits.

### Layout

One table and one status strip, no panels:

```
DELUCYX │ [CUT] │ 2 active │ en0 · Stigma.Volks ████· -47 dBm · 10.0.0.5 · gw 10.0.0.1   4 dev · 14 ap · 2 cut · 0 sel
 ────────────────────────────────────────────────────────────────────────────────────────────────────
 IP              MAC               HOST               ROLE
▸  10.0.0.1       a4:2b:8c:00:00:01 router             GW
 ● 10.0.0.18      a6:ae:df:73:4f:14 phone              CUT
 ● 10.0.0.5       28:39:26:c8:a3:e1 laptop             CUT
   10.0.0.59      b0:be:83:28:9a:d6 mac                SELF
  ── nearby wifi 14 ── not joined · not cuttable · w to focus
   █████ -19 dBm   ch 6 2.4GHz       fikri              AP   WPA2
   ██··· -74 dBm   ch 161 5GHz       Tiara cakery       AP   WPA2
 ────────────────────────────────────────────────────────────────────────────────────────────────────
tx/s  ▇▁▁▇▇▁ 30/s · peak 283/s   targets  ▅▅▅▅▅▅ 2/4   20:47:25 refresh — ok
↑↓ move  space select  a all  c cut  m mitm  s stop  h hold  u auto  w wifi  r refresh  q quit
```

- **Top strip** — mode badge (`HOLD`/`CUT`/`MITM`/`AUTO`), live activity,
  `interface · joined SSID <signal meter> <dBm> · IP · gw`, and counters
  (`devices · neighbours · cut · selected`) flush right. On a narrow terminal the signal meter is
  dropped before the counters.
- **Device table** — `▸` cursor, `●` being cut, `◆` selected, ROLE `GW`/`SELF`/`CUT`. Scrolls when long.
- **Neighbour list** — every Wi-Fi network the radio hears but is not joined to, strongest first,
  under a `nearby wifi` rule: 5-cell signal meter (`█████` strong → `····` weak, coloured
  green/amber/red), dBm, channel + band, SSID and security. Context only: no IP, never cuttable.
- **`w`** swaps the pane to the neighbour table (`SIGNAL / CHANNEL / NETWORK / SEC`) so the cursor can
  reach every heard network on a short terminal. Cut/MITM and marking are refused there.
- **Bottom strip** — two block charts (`tx/s` with peak, and targets vs. devices) plus the last action.
- `q` quits; `c`/`m` + `y` is the only way a cut starts.

The TUI shows `[HOLD] nothing cut` until you enable cutting, and every start needs a `y` confirmation.

### Keys

| Key | Action |
|-----|--------|
| `↑`/`k`, `↓`/`j` | Move selection |
| `space` | Mark/unmark device |
| `a` / `n` | Mark all valid / clear marks |
| `g` / `G` | Jump to first / last row |
| `w` | Swap the table between LAN devices and nearby Wi-Fi networks |
| `c` | Cut selected devices (asks to confirm) |
| `m` | MITM selected devices (asks to confirm) |
| `s` | Stop all (hold) |
| `h` / `u` | Hold / resume daemon auto-spoof |
| `r` | Rescan devices (also refreshes the Wi-Fi neighbour list) |
| `i` | Install/start the daemon (offline screen only; runs `sudo delucyx install`) |
| `q` | Quit |

Status is polled every 2 s; marks survive rescans. Devices being cut are tagged in the list. If the
TUI sources or Bun are missing, `delucyx` prints a hint and falls back to the legacy menu.

## Menubar GUI

```bash
make install-app
```

Installs `DelucyxUI.app` to `~/Applications` and opens it. No Dock icon — it lives in the menu bar.

### Menu

```
🛡  ← click
─────────────────────────
delucyx v1.0.0
─────────────────────────
🟢 Active
Interface: en0  192.168.1.12
─────────────────────────
Cutting (3 targets):
   · 192.168.1.3
   · 192.168.1.7
   · 192.168.1.11
─────────────────────────
Stop All          ⌘S
Scan Network      ⌘R
─────────────────────────
Open Log…         ⌘L
─────────────────────────
Quit              ⌘Q
```

### Icon states

| Icon | Meaning |
|------|---------|
| `🛡` | Actively spoofing |
| `🟡` | Manually stopped (won't auto-restart until the next network connect) |
| `⚫` | Idle (no network or no targets found) |
| `⚠️` | Daemon not running |

### Stop All behavior

**Stop All** (GUI) or `s` (TUI) sends an IPC `stop` command. The daemon:

1. Stops the spoof loop
2. Restores ARP tables for all targets
3. Enters `hold` — **does not auto-restart** even though the network is still connected

Auto-spoof resumes with **Scan Network** (GUI), `u` in the TUI, or `sudo delucyx resume`.

## IPC (protocol 3)

GUI and TUI talk to the daemon over the Unix socket `/var/run/delucyx.sock` — JSON, one request per
connection, mode `0666` so clients run without root. Override the path with `DELUCYX_SOCKET` (daemon
and clients both honour it).

### Requests

| Request | Effect |
|---------|--------|
| `{"cmd":"status"}` | Full snapshot: mode, interface, gateway, joined Wi-Fi (`ssid`, `ssidChannel`, `ssidBand`, `ssidSignal`), Wi-Fi neighbours (`nearby`), targets, device list, `protocol` |
| `{"cmd":"refresh"}` | Rescan devices, keep the current mode |
| `{"cmd":"scan"}` | Rescan and resume `auto` mode |
| `{"cmd":"start","targets":["192.168.1.7"],"mode":"cut"\|"mitm","forward":false}` | Cut exactly these targets |
| `{"cmd":"stop"}` | Stop spoofing and hold |
| `{"cmd":"hold"}` | Hold (pause auto-spoof) |
| `{"cmd":"resume"}` | Back to `auto` mode |
| `{"cmd":"exit"}` | Shut the daemon down |

Clients must check `status.protocol`; a missing or lower value means the daemon is older than the
binary — run `sudo delucyx upgrade`.

### Status fields

| Field | Meaning |
|-------|---------|
| `mode` | `hold` / `auto` / `manual` |
| `running` | The spoofer thread is active |
| `iface`, `ip`, `gateway` | Interface, our address, gateway IP of the current network |
| `ssid`, `ssidChannel`, `ssidBand`, `ssidSignal` | Joined Wi-Fi network and its RSSI (`0` when unknown) |
| `nearby[]` | Networks the radio hears but is not joined to |
| `devices[]` | `ip`, `mac`, `hostname`, `isGateway`, `isSelf`, `spoofing` |
| `targets[]` | IPs currently being spoofed |
| `framesSent` | Cumulative count of frames handed to the kernel (drives the TUI chart) |

`nearby[]` is sorted strongest first, capped at 24, deduplicated per SSID **and** band:

```json
{"ssid":"Tiara cakery","channel":161,"band":"5GHz","security":"WPA2","signal":-71,"phymode":"ac"}
```

The daemon reads the radio with `system_profiler SPAirPortDataType` at most once every 15 s and
republishes every 30 s, so the neighbour list is a snapshot, not a live sample.

## How the device list is built

Every row in the table has a source — nothing is guessed:

| Row | Source |
|-----|--------|
| `SELF` | `getDefaultInterface()` + `getInterfaceIP(en0)`; hostname from `ProcessInfo.hostName` |
| `GW` | `route -n get default` → gateway IP; MAC from the ARP reply, else the ARP cache |
| Other hosts | Kernel ARP cache (`arp -a`) merged with an active ARP burst over the interface's subnet (e.g. `/24` → `.1`–`.254`, `.0`/`.255` dropped), inside BPF |
| `nearby wifi` rows | `system_profiler SPAirPortDataType` — radio neighbours, which have no IP at all |

Consequences worth knowing:

- A device that is asleep, ignores ARP, or sits behind AP isolation / another VLAN simply will not
  show up. Re-run with `r` (TUI) or `delucyx status` after `{"cmd":"refresh"}` to catch late replies.
- The ARP-cache path needs no root; the active burst does. Without BPF you still get the cached hosts.
- `HOST` stays `-` for other devices: `delucyx` does not do reverse DNS (only `SELF` gets a name).

## Legacy interactive menu

```bash
delucyx menu
```

1. Select network interface
2. Tool scans the network, lists devices
3. Select target(s) — single, comma-separated, or `all`
4. Select attack mode
5. Confirm — spoofing starts
6. `Ctrl+C` to stop and restore ARP tables

### Multi-target selection

```
Pilih target [1-5] / pisah koma (mis: 3,4,5) / "all"  3,4,5
Pilih target [1-5] / pisah koma (mis: 3,4,5) / "all"  all
```

## CLI mode

```bash
sudo ./build/delucyx <victim-ip> [options]
```

| Option | Description |
|--------|-------------|
| `-i, --interface <name>` | Network interface (default: auto-detect) |
| `-g, --gateway <ip>` | Gateway IP (default: auto-detect) |
| `-r, --repeat <secs>` | Spoof interval in seconds (default: 2) |
| `-b, --bidirectional` | Bidirectional spoof (full MITM) |
| `-f, --forward` | Enable IP forwarding (use with `-b`) |
| `-v, --verbose` | Verbose output |

```bash
sudo ./build/delucyx 192.168.1.100
sudo ./build/delucyx 192.168.1.100 -b -f
sudo ./build/delucyx 192.168.1.100 -i en0 -g 192.168.1.1
```

## Attack modes

### Mode 1 — Cut connection

Poisons both ARP caches and drops all traffic. The target loses internet access.

Packets sent per interval:

- Unicast ARP reply to victim: `gateway IP → our MAC`
- Broadcast ARP: `gateway IP → our MAC`
- Unicast to gateway: `victim IP → our MAC`
- Broadcast: `victim IP → our MAC` (bypasses gateway ARP unicast filtering)

### Mode 2 — Full MITM (bidirectional)

Same as Mode 1 plus IP forwarding. Traffic flows through the attacker — intercept, inspect, modify.

### Daemon mode (combined)

The daemon uses `bidirectional=true` + `forwardTraffic=false`: it sends all bidirectional poison
packets but drops the traffic. Strongest cut — both directions poisoned, nothing forwarded.

## How it works

delucyx uses macOS BPF (Berkeley Packet Filter) to send raw Ethernet frames directly. No `libpcap`
dependency — BPF is accessed through `/dev/bpf*`.

```
Victim ARP cache:  gateway IP → attacker MAC  (victim sends to attacker)
Gateway ARP cache: victim IP  → attacker MAC  (gateway sends to attacker)

Without IP forwarding: packets dropped → target loses internet
With IP forwarding:    packets relayed → MITM
```

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Load failed: 5: Input/output error` on `install` | Legacy `launchctl load -w` on an already-registered label. Current builds use `bootout` → `bootstrap` → `kickstart`; re-run `sudo ./build/delucyx install` with the new binary. |
| CLI/TUI says `stale daemon` or stops showing Wi-Fi data | Daemon binary older than the client. `sudo ./build/delucyx upgrade` (protocol 2 daemons have no `nearby`). |
| TUI header shows `no-iface · ? · gw ?` | Daemon has no network identity yet: it publishes interface/SSID on connect and every 30 s. Check `delucyx status`; if the daemon is down the TUI shows the onboarding screen instead. |
| `nearby wifi` empty | No Wi-Fi interface (`system_profiler` reports none), or the radio returned no scan yet — wait 30 s or press `r`. |
| Builder works, installed GUI shows `⚠️` | `build/DelucyxUI.app` is stale: `make app && make install-app`. |
| Cutting has no effect on Wi-Fi | macOS 15.4+ protects ARP on Wi-Fi; packets are sent but the target's cache does not change. See [TESTING.md](TESTING.md). |

## Testing

Manual and automated checks live in [TESTING.md](TESTING.md):

```bash
make tui-test        # headless TUI tests (stub client, no daemon, no root)
make tui-deps        # Bun dependencies for the TUI
```

Daemon protocol checks without root (BPF fails on purpose, the ARP-cache path still works):

```bash
mkdir -p /tmp/delucyx-test
DELUCYX_SOCKET=/tmp/delucyx-test/delucyx.sock ./build/delucyx --daemon &
DELUCYX_SOCKET=/tmp/delucyx-test/delucyx.sock delucyx status
```

`make clean` removes `build/`. Current version: **v1.0.0**.
