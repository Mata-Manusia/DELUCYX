# delucyx

LAN access control tool for macOS. Cuts or intercepts network connections on your local network via ARP spoofing.

> **For authorized use only.** Use on networks you own or have explicit permission to test.

## Features

- Auto-detect interface, gateway, and local devices
- Network scan via ARP (active + cache)
- **Multi-target mass deauth** — cut multiple devices simultaneously (`3,4,5` or `all`)
- Two attack modes: cut connection or full MITM
- **Idle by default** — the daemon never cuts anything on its own; every cut is explicitly enabled
- **Background daemon** — runs on boot, survives disconnect/reconnect, holds until you enable it
- **Terminal UI (OpenTUI)** — device list, multi-select, cut/MITM, hold/resume, live status
- **Wi-Fi awareness** — the joined network (SSID, channel, band, RSSI) plus every network the radio
  hears, with signal meters; `w` swaps to the neighbour table
- **Menubar GUI** — native macOS status bar app with live target list and stop/scan controls
- Graceful ARP restore on exit

## Requirements

- macOS 13+
- Xcode Command Line Tools
- `sudo` (BPF requires root)
- [Bun](https://bun.sh) — only for the terminal UI (`tui/`)

## Build

```bash
# Build CLI daemon only
make

# Build GUI app only
make ui

# Install TUI dependencies (OpenTUI via Bun)
make tui-deps

# Build everything
make && make ui

# Put `delucyx` on PATH + install the TUI (needs sudo for /usr/local/bin)
make install

# Optional privileged daemon (starts idle, held)
sudo delucyx install
```

Outputs:
- `build/delucyx` — CLI + daemon binary
- `build/DelucyxUI` — GUI binary
- `build/DelucyxUI.app` — macOS app bundle (after `make app`)
- `tui/` — OpenTUI terminal interface (run with `make tui`)

## Quick Start (daemon + GUI + TUI)

```bash
# 1. Build
make && make app

# 2. Install daemon (runs as root on every boot)
sudo ./build/delucyx install

# 3. Install GUI to ~/Applications and open it
make install-app

# 4. Optional: terminal UI (needs Bun)
make tui-deps && make install-tui
```

From that point the daemon runs in the background and only **scans** — cutting waits for you.  
Control via menubar icon `🛡`, the terminal UI (`delucyx`), or the CLI (`sudo delucyx status`).

---

## Daemon

### Install

```bash
sudo ./build/delucyx install
```

Installs a LaunchDaemon (`/Library/LaunchDaemons/com.delucyx.daemon.plist`).  
Runs on boot and on every network connect, but starts in **`hold`**: nothing is spoofed until you
enable it (TUI `c`/`m` + `y`, `sudo delucyx resume` for all devices, or the GUI).

### Daemon behavior

| Mode | Meaning |
|------|---------|
| `hold` | **Default.** Idle: the daemon scans and serves status, but never spoofs |
| `auto` | Enabled explicitly (`delucyx resume`, TUI `u`, GUI *Scan Network*): cut every non-gateway device |
| `manual` | Enabled explicitly (TUI `c`/`m` + confirm): cut exactly the selected targets |

Cutting is **never** automatic. The daemon boots into `hold`, and a network change drops it back to
`hold` so a running attack is never carried onto another network.

| Event | Action |
|-------|--------|
| Boot / connect to network | Scan devices and publish the list; **nothing is cut** (mode `hold`) |
| Disconnect | Stop spoof, restore ARP tables, back to `hold` |
| Reconnect / new network | Back to `hold`; rescan only |
| Spoof thread crashes while enabled | Restart the enabled targets (30 s backoff after a failed start) |
| User stops via TUI/GUI | `hold` — stays idle until `resume` or a TUI/CLI start |
| Failed start (no BPF, no devices) | Retried with 30 s backoff, no scan storm |

### Commands

```bash
sudo ./build/delucyx install      # Install and start daemon
sudo ./build/delucyx uninstall    # Remove daemon
sudo ./build/delucyx upgrade      # Rebuild and hot-reload running daemon
sudo ./build/delucyx stop all     # Stop spoofing (daemon held)
sudo ./build/delucyx hold         # Pause daemon auto-spoof
sudo ./build/delucyx resume       # Resume auto mode
sudo ./build/delucyx status       # Show daemon mode, interface, targets, devices
sudo ./build/delucyx tui          # Open the terminal UI
```

`hold` / `resume` / `stop all` / `status` talk to the running daemon over the IPC socket and
fall back to signals when the daemon is unreachable.

### Upgrade workflow

```bash
make && sudo ./build/delucyx upgrade
```

Stops the running daemon cleanly (restores ARP tables), launchd auto-restarts it with the new binary.

### Logs

```bash
tail -f /var/log/delucyx.log
```

---

## Menubar GUI

```bash
make install-app
```

Installs `DelucyxUI.app` to `~/Applications` and opens it.  
No Dock icon — lives in the menu bar only.

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
| `🟡` | Manually stopped (won't auto-restart until next network connect) |
| `⚫` | Idle (no network or no targets found) |
| `⚠️` | Daemon not running |

### Stop All behavior

Clicking **Stop All** (GUI) or pressing `s` in the TUI sends an IPC `stop` command. The daemon:
1. Stops the spoof loop
2. Restores ARP tables for all targets
3. Enters `hold` — **does not auto-restart** even though network is still connected

Auto-spoof resumes with **Scan Network** (GUI), `u` in the TUI, or `sudo delucyx resume`.

### IPC (protocol 3)

GUI and TUI talk to the daemon over the Unix socket `/var/run/delucyx.sock`
(JSON, one request per connection, mode `0666` so clients run without root).
Override the path with `DELUCYX_SOCKET` (daemon and clients both honour it).

Requests:

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

`status.nearby` is a list of networks the radio hears but is not joined to, strongest first,
capped at 24, deduplicated per SSID and band:

```json
{"ssid":"Tiara cakery","channel":161,"band":"5GHz","security":"WPA2","signal":-71,"phymode":"ac"}
```

The joined network carries the same detail in `status.ssid`, `status.ssidChannel`, `status.ssidBand`
and `status.ssidSignal` (dBm, `0` when unknown). The daemon reads the radio with
`system_profiler SPAirPortDataType` at most once every 15 s and republishes every 30 s, so the
neighbour list is always a snapshot rather than a live sample.

---

## Terminal UI (TUI)

```bash
delucyx                    # default entry point (same as `delucyx tui`)
```

Needs [Bun](https://bun.sh) and the `tui/` sources. Install once (no sudo):

```bash
make install      # delucyx → ~/.local/bin, TUI → ~/.delucyx/tui
```

With no daemon running the TUI shows an onboarding screen: `i` runs `sudo delucyx install` for you,
`r` retries, `q` quits. Prefer no daemon at all? `sudo delucyx menu` spoofs directly as root
(legacy menu).

The TUI is a **client of the daemon** — it never needs root itself. If the daemon is not installed
it shows an onboarding screen with the install command.

Layout — one table, one status strip, nothing else:

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

- Top strip — mode badge (`HOLD`/`CUT`/`MITM`/`AUTO`), live activity, interface · joined SSID with
  its signal meter and dBm, IP/gateway, and counters (devices · neighbours · cut · selected) flush right.
- Table — `▸` cursor, `●` being cut, `◆` selected, ROLE `GW`/`SELF`/`CUT`. Scrolls when long.
- Neighbour list — every Wi-Fi network the radio hears but is not joined to, strongest first, under a
  `nearby wifi` rule: signal meter (`█████` = strong, `··` = weak, coloured green/amber/red), dBm,
  channel + band, SSID and security. These rows are context only: no IP, never cuttable.
- `w` swaps the pane to the neighbour table (`SIGNAL / CHANNEL / NETWORK / SEC`), where the cursor can
  reach every heard network on a short terminal. Cut/MITM and marking are refused there.
- Bottom strip — two block charts (`tx/s` with peak, and targets vs. devices) plus the last action.
- No panels or boxes to read around; `q` quits, `c`/`m` + `y` is the only way a cut starts.

The TUI shows `[HOLD] nothing cut` until you enable cutting, and every start needs a `y` confirmation.

Keys:

| Key | Action |
|-----|--------|
| `↑`/`k`, `↓`/`j` | Move selection |
| `space` | Mark/unmark device |
| `a` / `n` | Mark all valid / clear marks |
| `g` / `G` | Jump to first / last device |
| `w` | Swap the table between LAN devices and nearby Wi-Fi networks |
| `c` | Cut selected devices (asks to confirm) |
| `m` | MITM selected devices (asks to confirm) |
| `s` | Stop all (hold) |
| `h` / `u` | Hold / resume daemon auto-spoof |
| `r` | Rescan devices (also refreshes the Wi-Fi neighbour list) |
| `i` | Install/start the daemon (offline screen only; runs `sudo delucyx install`) |
| `q` | Quit |

Status is polled every 2 s; marks survive rescans. Devices being cut are tagged in the list.

If the TUI sources or Bun are missing, `delucyx` prints a hint and falls back to the legacy menu.
The TUI only *requests* cuts: the daemon stays in `hold` and each start needs the `y` confirmation.

---

## Interactive mode (legacy menu)

```bash
delucyx menu
```

1. Select network interface
2. Tool scans network, lists devices
3. Select target(s) — single, comma-separated, or `all`
4. Select attack mode
5. Confirm — spoofing starts
6. `Ctrl+C` to stop and restore ARP tables

### Multi-target selection

```
Pilih target [1-5] / pisah koma (mis: 3,4,5) / "all"  3,4,5
Pilih target [1-5] / pisah koma (mis: 3,4,5) / "all"  all
```

---

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

---

## Attack modes

### Mode 1 — Cut connection

Poisons both ARP caches, drops all traffic. Target loses internet access.

Packets sent per interval:
- Unicast ARP reply to victim: `gateway IP → our MAC`
- Broadcast ARP: `gateway IP → our MAC`
- Unicast to gateway: `victim IP → our MAC`
- Broadcast: `victim IP → our MAC` (bypasses gateway ARP unicast filtering)

### Mode 2 — Full MITM (bidirectional)

Same as Mode 1 but enables IP forwarding. Traffic flows through attacker — intercept, inspect, or modify.

### Daemon mode (combined)

Daemon uses `bidirectional=true` + `forwardTraffic=false`: sends all bidirectional poison packets but drops traffic. Strongest cut — poisons both directions without forwarding.

---

## How it works

delucyx uses macOS BPF (Berkeley Packet Filter) to send raw Ethernet frames directly. No `libpcap` dependency — BPF accessed via `/dev/bpf*`.

```
Victim ARP cache:  gateway IP → attacker MAC  (victim sends to attacker)
Gateway ARP cache: victim IP  → attacker MAC  (gateway sends to attacker)

Without IP forwarding: packets dropped → target loses internet
With IP forwarding:    packets relayed → MITM
```

---

## Clean

```bash
make clean
```

## Version

v1.0.0
