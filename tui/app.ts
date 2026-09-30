import {
  BoxRenderable,
  ScrollBoxRenderable,
  TextRenderable,
  bg,
  bold,
  fg,
  t,
  type CliRenderer,
  type KeyEvent,
  type StyledText,
  type TextChunk,
} from "@opentui/core"
import { signalBar, signalLevel, sparkline } from "./chart"
import {
  DEFAULT_SOCKET_PATH,
  PROTOCOL_VERSION,
  describeError,
  type CommandResult,
  type DelucyxClient,
  type Device,
  type NearbyWifi,
  type StartMode,
  type StatusResult,
  type StatusSnapshot,
} from "./ipc"

/** Muted terminal palette — one colour per meaning, no chrome. */
const C = {
  text: "#c9d1d9",
  title: "#e6edf3",
  label: "#6e7681",
  rule: "#30363d",
  accent: "#58a6ff",
  ok: "#3fb950",
  warn: "#d29922",
  bad: "#f85149",
  gw: "#a371f7",
  self: "#79c0ff",
  sel: "#d29922",
  panelBg: "#0d1117",
} as const

const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

/** Samples kept for the chart (2 s poll → 60 s window) and its width in columns. */
const MAX_SAMPLES = 30
const CHART_WIDTH = 16
const ACTIVITY_ROWS = 8

export type ConfirmKind = "cut" | "mitm" | "stop"

export interface AppOptions {
  /** `status` poll period in ms. `0` disables the timer (tests drive `refreshNow()`). */
  pollMs?: number
  /** Wall-clock source in ms, injectable so scan-age labels stay deterministic. */
  now?: () => number
  /** Invoked on `q`. Defaults to destroying this app and the renderer. */
  onQuit?: () => void
  /** Runs `delucyx install` (with sudo) to bring the daemon up. Offline `i` key. */
  onInstallDaemon?: () => Promise<void>
}

export interface AppState {
  connected: boolean
  /** Pane under the cursor: the LAN device table or the Wi-Fi neighbour table. */
  view: "devices" | "wifi"
  cursor: number
  cursorIp: string | null
  /** Row under the cursor in wifi view (`ssid|channel`), else null. */
  cursorAp: string | null
  selected: string[]
  modal: ConfirmKind | null
  action: string
}

export interface AppHandle {
  /** Remove listeners/timers and release the client. Idempotent. */
  destroy(): void
  /** Force one `status` round-trip and wait for it to be applied. */
  refreshNow(): Promise<void>
  state(): AppState
}

interface ActivityEntry {
  clock: string
  text: string
  ok: boolean
}

/** Spoof targets always exclude the gateway, ourselves and the network/broadcast edges. */
function isValidTarget(device: Device): boolean {
  if (device.isGateway || device.isSelf) return false
  return !device.ip.endsWith(".0") && !device.ip.endsWith(".255")
}

function badgeFor(status: StatusSnapshot, lastStart: StartMode): string {
  if (status.hold || status.mode === "hold") return "HOLD"
  if (status.mode === "manual") return lastStart === "mitm" ? "MITM" : "CUT"
  return "AUTO"
}

function ageLabel(lastScan: number, nowMs: number): string {
  if (lastScan <= 0) return "never"
  const seconds = Math.max(0, Math.floor(nowMs / 1000) - lastScan)
  if (seconds < 60) return `${seconds}s ago`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  return `${Math.floor(seconds / 3600)}h ago`
}

function pad(text: string, width: number): string {
  if (text.length >= width) return text.slice(0, width)
  return text + " ".repeat(width - text.length)
}

/** Dim label cell (chunk-level, so it nests inside one `t` template). */
function lbl(text: string, width = 10): TextChunk {
  return fg(C.label)(pad(text, width))
}

export function createApp(renderer: CliRenderer, client: DelucyxClient, options: AppOptions = {}): AppHandle {
  const pollMs = options.pollMs ?? 2_000
  const nowMs = options.now ?? (() => Date.now())
  const socketPath = client.socketPath ?? DEFAULT_SOCKET_PATH

  let snapshot: StatusSnapshot | null = null
  let statusError: string | null = null
  let cursor = 0
  let cursorIp: string | null = null
  let cursorAp: string | null = null
  // "devices" = LAN table with the neighbour list underneath; "wifi" = neighbours only,
  // so every heard AP is reachable with the cursor on a short terminal.
  let view: "devices" | "wifi" = "devices"
  let modal: ConfirmKind | null = null
  let action = "ready"
  let lastStartMode: StartMode = "cut"
  let destroyed = false
  let installing = false
  let inflight: Promise<void> | null = null
  let spinnerFrame = 0
  let spinnerTimer: Timer | undefined
  const activity: ActivityEntry[] = []
  const selected = new Set<string>()
  const samples: { rate: number; targets: number }[] = []
  let lastFramesSent: number | null = null
  let lastSampleMs: number | null = null
  let sampleIntervalMs = pollMs > 0 ? pollMs : 0

  function clock(): string {
    const d = new Date(nowMs())
    const two = (n: number) => String(n).padStart(2, "0")
    return `${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}`
  }

  // ---------------------------------------------------------------- structure
  const root = renderer.root
  root.flexDirection = "column"

  const header = new TextRenderable(renderer, { id: "header", height: 1, content: "", fg: C.text, wrapMode: "none" })

  const banner = new TextRenderable(renderer, { id: "banner", height: 1, content: "", fg: C.warn, visible: false })
  const topRule = new TextRenderable(renderer, { id: "rule-top", height: 1, content: "", fg: C.rule })
  const tableHead = new TextRenderable(renderer, { id: "table-head", height: 1, content: "", fg: C.label })

  const devicePane = new ScrollBoxRenderable(renderer, {
    id: "devices",
    flexGrow: 1,
    scrollY: true,
    scrollX: false,
    viewportCulling: true,
    scrollbarOptions: { showArrows: false, trackOptions: { foregroundColor: C.rule, backgroundColor: C.panelBg } },
  })
  const deviceHint = new TextRenderable(renderer, { id: "devices-hint", height: 1, content: "", fg: C.warn, visible: false })

  const bottomRule = new TextRenderable(renderer, { id: "rule-bottom", height: 1, content: "", fg: C.rule })
  const infoLine = new TextRenderable(renderer, { id: "info", height: 1, content: "", fg: C.text })
  const keybar = new TextRenderable(renderer, { id: "keybar", height: 1, content: "", fg: C.label })

  const onboard = new BoxRenderable(renderer, {
    id: "onboard",
    flexGrow: 1,
    flexDirection: "column",
    border: true,
    borderStyle: "single",
    borderColor: C.rule,
    title: " SETUP ",
    titleColor: C.warn,
    titleAlignment: "left",
    paddingLeft: 2,
    paddingTop: 1,
    visible: false,
  })
  const onboardText = new TextRenderable(renderer, { id: "onboard-text", content: "", fg: C.text })
  onboard.add(onboardText)

  const overlay = new BoxRenderable(renderer, {
    id: "overlay",
    position: "absolute",
    top: 0,
    left: 0,
    width: "100%",
    height: "100%",
    justifyContent: "center",
    alignItems: "center",
    visible: false,
  })
  const modalBox = new BoxRenderable(renderer, {
    id: "modal",
    width: 60,
    flexDirection: "column",
    border: true,
    borderStyle: "single",
    borderColor: C.warn,
    titleColor: C.warn,
    paddingLeft: 2,
    paddingRight: 2,
    paddingTop: 1,
    paddingBottom: 1,
    backgroundColor: C.panelBg,
  })
  const modalText = new TextRenderable(renderer, { id: "modal-text", content: "", fg: C.text })
  modalBox.add(modalText)
  overlay.add(modalBox)

  root.add(header)
  root.add(banner)
  root.add(topRule)
  root.add(tableHead)
  root.add(devicePane)
  root.add(deviceHint)
  root.add(onboard)
  root.add(bottomRule)
  root.add(infoLine)
  root.add(keybar)
  root.add(overlay)

  // ------------------------------------------------------------------- rows
  const rows = new Map<string, TextRenderable>()
  let rowOrder: string[] = []
  let roleWidth = 4

  const WIFI_ROW = "sep:wifi"
  /** Row identity for a neighbour: same SSID on two bands stays two rows. */
  const apKey = (net: NearbyWifi): string => `${net.ssid}|${net.channel}`
  const apRowKey = (net: NearbyWifi): string => `ap:${apKey(net)}`

  /** Keys the cursor walks: LAN devices, or the neighbour list in wifi view. */
  function cursorKeys(devices: Device[], nearby: NearbyWifi[]): string[] {
    return view === "wifi" ? nearby.map(apKey) : devices.map((device) => device.ip)
  }

  /** Keys rendered in the pane: devices view keeps the neighbour list as context. */
  function rowKeys(devices: Device[], nearby: NearbyWifi[]): string[] {
    if (view === "wifi") return nearby.map(apRowKey)
    const separator = nearby.length === 0 ? [] : [WIFI_ROW]
    return [...devices.map((device) => device.ip), ...separator, ...nearby.map(apRowKey)]
  }

  function headerLine(): string {
    return ` ${pad("IP", 15)} ${pad("MAC", 17)} ${pad("HOST", 18)} ${pad("ROLE", roleWidth)}`
  }

  function rowContent(device: Device, isCursor: boolean, isSelected: boolean): StyledText {
    const marker = device.spoofing ? "●" : isSelected ? "◆" : " "
    const role = device.isGateway ? "GW" : device.isSelf ? "SELF" : device.spoofing ? "CUT" : ""
    const roleColor = device.isGateway ? C.gw : device.isSelf ? C.self : C.ok
    const ipColor = device.spoofing ? C.ok : isSelected ? C.sel : C.text
    const cursorMark = isCursor ? "▸" : " "

    return t`${fg(isCursor ? C.accent : C.label)(cursorMark)}${fg(device.spoofing ? C.ok : isSelected ? C.sel : C.label)(marker)} ${fg(ipColor)(pad(device.ip, 15))} ${fg(C.label)(pad(device.mac || "--:--:--:--:--:--", 17))} ${fg(C.text)(pad(device.hostname || "-", 18))} ${fg(roleColor)(pad(role, roleWidth))}`
  }

  /** Neighbour APs share the device columns: SIGNAL cell = meter, CHANNEL cell = channel. */
  function nearbyRowContent(net: NearbyWifi, isCursor: boolean, withTag: boolean): StyledText {
    const signal = net.signal === 0 ? "?" : `${net.signal} dBm`
    const channel = net.channel === 0 ? "-" : `ch ${net.channel}${net.band === "" ? "" : ` ${net.band}`}`
    const security = net.security === "" ? "-" : net.security
    const cursorMark = isCursor ? "▸" : " "
    const nameColor = isCursor ? C.sel : C.accent
    // Devices view tags the row "AP" and appends security; the wifi table has a SEC column.
    const role = withTag ? "AP" : security
    const tail = withTag ? fg(C.label)(` ${security}`) : fg(C.label)("")
    return t`${fg(isCursor ? C.accent : C.label)(cursorMark)}  ${fg(signalColor(net.signal))(pad(signalBar(net.signal), 5))} ${fg(C.label)(pad(signal, 9))} ${fg(C.label)(pad(channel, 17))} ${fg(nameColor)(pad(net.ssid, 18))} ${fg(withTag ? C.gw : C.label)(pad(role, roleWidth))}${tail}`
  }

  /** Green ≥4 blocks, amber ≥3, red below — the meter and the number share one colour. */
  function signalColor(dbm: number): string {
    const level = signalLevel(dbm)
    return level >= 4 ? C.ok : level >= 3 ? C.warn : C.bad
  }

  function syncRows(devices: Device[], nearby: NearbyWifi[]): void {
    const nextRoleWidth = Math.max(2, ...devices.map((d) => (d.isGateway ? 2 : d.isSelf ? 4 : 3)), 2)
    if (nextRoleWidth !== roleWidth) roleWidth = nextRoleWidth

    const wanted = rowKeys(devices, nearby)
    const sameOrder = wanted.length === rowOrder.length && wanted.every((key, index) => rowOrder[index] === key)
    if (!sameOrder) {
      for (const row of rows.values()) {
        devicePane.remove(row)
        row.destroy()
      }
      rows.clear()
      rowOrder = []
      for (const key of wanted) {
        const row = new TextRenderable(renderer, { id: `row:${key}`, content: "", fg: C.text, wrapMode: "none" })
        rows.set(key, row)
        rowOrder.push(key)
        devicePane.add(row)
      }
    }
    const wifiOnly = view === "wifi"
    devices.forEach((device) => {
      if (wifiOnly) return
      const row = rows.get(device.ip)
      if (row !== undefined) row.content = rowContent(device, device.ip === cursorIp, selected.has(device.ip))
    })
    const separator = rows.get(WIFI_ROW)
    if (separator !== undefined) {
      separator.content = t`  ${fg(C.rule)("── nearby wifi ")}${fg(C.gw)(`${nearby.length}`)}${fg(C.rule)(" ──")} ${fg(C.label)("not joined · not cuttable · w to focus")}`
    }
    for (const net of nearby) {
      const row = rows.get(apRowKey(net))
      if (row !== undefined) row.content = nearbyRowContent(net, wifiOnly && apKey(net) === cursorAp, !wifiOnly)
    }
  }

  function revealCursor(): void {
    if (view === "wifi") {
      if (cursorAp !== null) devicePane.scrollChildIntoView(`row:ap:${cursorAp}`)
      return
    }
    if (cursorIp !== null) devicePane.scrollChildIntoView(`row:${cursorIp}`)
  }

  // ----------------------------------------------------------------- render
  function renderHeader(): void {
    const separator = fg(C.rule)(" │ ")
    if (snapshot === null) {
      header.content = t`${bold(fg(C.title)("DELUCYX"))}${separator}${fg(C.bad)("daemon unreachable")}`
      return
    }
    const badge = badgeFor(snapshot, lastStartMode)
    const badgeColor = badge === "HOLD" ? C.warn : badge === "AUTO" ? C.accent : C.ok
    // Keep the strip short: the badge already tells the mode, so only live
    // activity (scanning / cutting) earns extra space.
    const state = snapshot.scanning
      ? `${SPINNER[spinnerFrame % SPINNER.length]} scanning`
      : snapshot.running
        ? `${snapshot.targets.length} active`
        : ""
    const statePart = state === "" ? "" : `${state} │ `
    const link = [snapshot.iface || "no-iface", snapshot.ssid, snapshot.ip || "?"]
      .filter((part) => part !== "")
      .join(" · ")
    // Joined-network strength rides with the SSID: meter + dBm, same colour key as the list.
    const meterText = snapshot.ssid === "" || snapshot.ssidSignal === 0
      ? ""
      : ` ${signalBar(snapshot.ssidSignal)} ${snapshot.ssidSignal} dBm`
    const head = (meter: string): string =>
      `DELUCYX │ [${badge}] │ ${statePart}${link}${meter} · gw ${snapshot.gateway || "?"}`
    const right = `${snapshot.devices.length} dev · ${snapshot.nearby.length} ap · ${snapshot.targets.length} cut · ${selected.size} sel`
    // Counters keep the last columns; on a narrow terminal the signal meter goes first.
    const meterFits = meterText !== "" && usableWidth() - head(meterText).length - right.length >= 1
    const left = head(meterFits ? meterText : "")
    const wifiMeter: TextChunk = meterFits
      ? fg(signalColor(snapshot.ssidSignal))(meterText)
      : fg(C.label)("")
    // Both halves are measured as plain text so the counters sit flush right.
    const gap = usableWidth() - left.length - right.length
    const stateLead: TextChunk = state === "" ? fg(C.rule)("") : separator
    const stateText: TextChunk = fg(snapshot.running ? C.ok : C.text)(state)
    const counters: TextChunk = gap >= 1 ? fg(C.label)(" ".repeat(gap) + right) : fg(C.label)("")

    header.content = t`${bold(fg(C.title)("DELUCYX"))}${separator}${fg(badgeColor)(`[${badge}]`)}${stateLead}${stateText}${separator}${fg(C.text)(snapshot.iface || "no-iface")}${snapshot.ssid === "" ? "" : fg(C.label)(" · ")}${snapshot.ssid === "" ? "" : fg(C.accent)(snapshot.ssid)}${wifiMeter}${fg(C.label)(" · ")}${fg(C.text)(snapshot.ip || "?")}${fg(C.label)(" · gw ")}${fg(C.text)(snapshot.gateway || "?")}${counters}`
  }

  function renderBanner(): void {
    const stale = snapshot !== null && snapshot.protocol !== PROTOCOL_VERSION
    banner.visible = stale
    if (stale) {
      banner.content = t`${fg(C.warn)("!")} ${bg(C.warn)(fg(C.panelBg)(" STALE DAEMON "))} ${fg(C.warn)(`protocol ${snapshot?.protocol === undefined ? "unknown" : String(snapshot.protocol)} — this TUI speaks ${PROTOCOL_VERSION}`)}  ${fg(C.accent)("sudo delucyx upgrade")}`
    }
  }

  function renderRows(): void {
    const devices = snapshot?.devices ?? []
    const wifiOnly = view === "wifi"
    const showHint = snapshot !== null && (wifiOnly ? snapshot.nearby.length === 0 : devices.length === 0)
    deviceHint.visible = showHint
    if (showHint) {
      if (snapshot?.scanning) deviceHint.content = t` ${fg(C.warn)(wifiOnly ? "no networks yet" : "no devices yet")} ${fg(C.label)("— scanning…")}`
      else deviceHint.content = t` ${fg(C.warn)(wifiOnly ? "no networks" : "no devices")} ${fg(C.label)("— press")} ${fg(C.accent)("r")} ${fg(C.label)("to rescan")}`
    }
    tableHead.content = wifiOnly
      ? ` ${pad("SIGNAL", 15)} ${pad("CHANNEL", 17)} ${pad("NETWORK", 18)} ${pad("SEC", roleWidth)}`
      : headerLine()
    syncRows(devices, snapshot?.nearby ?? [])
    devicePane.verticalScrollBar.visible = devicePane.scrollHeight > devicePane.viewport.height
  }

  /** Usable columns: the last cell of a terminal line is unreliable. */
  function usableWidth(): number {
    return Math.max(40, renderer.width - 1)
  }

  function renderInfo(): void {
    const rates = samples.map((sample) => sample.rate)
    const targets = samples.map((sample) => sample.targets)
    const latest = rates.length > 0 ? (rates[rates.length - 1] ?? 0) : 0
    const peak = rates.length > 0 ? Math.max(...rates) : 0
    const rateMax = Math.max(1, Math.ceil(peak * 1.15))
    const targetMax = Math.max(1, snapshot?.devices.length ?? 0)
    const last = activity[activity.length - 1]

    const charts =
      `tx/s ${sparkline(rates, CHART_WIDTH, rateMax)} ${latest.toFixed(0)}/s · peak ${peak.toFixed(0)}/s` +
      `   targets ${sparkline(targets, CHART_WIDTH, targetMax)} ${snapshot?.targets.length ?? 0}/${snapshot?.devices.length ?? 0}`
    const activityText = last === undefined ? "" : `${last.clock} ${last.text}`
    const fits = activityText.length > 0 && charts.length + activityText.length + 3 <= usableWidth()
    const activityChunk: TextChunk = fits
      ? fg(last?.ok === true ? C.text : C.bad)(`   ${activityText}`)
      : fg(C.label)("")

    infoLine.content = t`${lbl("tx/s", 6)}${fg(C.accent)(sparkline(rates, CHART_WIDTH, rateMax))} ${fg(C.text)(`${latest.toFixed(0)}/s`)}${fg(C.label)(` · peak ${peak.toFixed(0)}/s`)}   ${lbl("targets", 8)}${fg(C.ok)(sparkline(targets, CHART_WIDTH, targetMax))} ${fg(C.text)(`${snapshot?.targets.length ?? 0}/${snapshot?.devices.length ?? 0}`)}${activityChunk}`
  }

  function selectedTargets(): string[] {
    return (snapshot?.devices ?? []).filter((device) => selected.has(device.ip)).map((device) => device.ip)
  }

  function renderModal(): void {
    overlay.visible = modal !== null
    if (modal === null) return
    const confirm = `${bg(C.warn)(fg(C.panelBg)(" y "))} ${fg(C.text)("confirm")}   ${fg(C.label)("n / esc")} ${fg(C.text)("cancel")}`
    if (modal === "stop") {
      modalBox.title = " CONFIRM · STOP "
      modalText.content = t`${bold(fg(C.title)("Stop all spoofing and hold?"))}

${fg(C.label)("The daemon stops ARP spoofing, restores the target ARP caches")}
${fg(C.label)("and waits for a new start. It will not restart by itself.")}

    ${confirm}`
      return
    }
    const targets = selectedTargets()
    const shown = targets.slice(0, 5)
    const overflow = targets.length - shown.length
    modalBox.title = modal === "cut" ? " CONFIRM · CUT " : " CONFIRM · MITM "
    modalText.content = t`${bold(fg(C.title)(modal === "cut" ? "Start CUT?" : "Start MITM?"))}   ${fg(C.label)(`${targets.length} target(s)`)}

${fg(C.label)("targets  ")}${fg(C.text)(shown.join(", "))}${overflow > 0 ? fg(C.label)(` +${overflow} more`) : ""}
${fg(C.label)("mode     ")}${fg(C.text)(modal === "cut" ? "intercept, no forwarding" : "intercept with IP forwarding")}

    ${confirm}`
  }

  function ensureSpinner(): void {
    const scanning = snapshot?.scanning === true
    if (scanning && spinnerTimer === undefined) {
      spinnerTimer = setInterval(() => {
        spinnerFrame += 1
        renderHeader()
      }, 150)
    } else if (!scanning && spinnerTimer !== undefined) {
      clearInterval(spinnerTimer)
      spinnerTimer = undefined
    }
  }

  function render(): void {
    if (destroyed) return
    const connected = snapshot !== null
    const ruleWidth = Math.max(0, usableWidth() - 1)
    topRule.content = t` ${fg(C.rule)("─".repeat(ruleWidth))}`
    bottomRule.content = t` ${fg(C.rule)("─".repeat(ruleWidth))}`

    devicePane.visible = connected
    tableHead.visible = connected
    bottomRule.visible = connected
    infoLine.visible = connected
    onboard.visible = !connected
    if (!connected) {
      onboardText.content = t`${bold(fg(C.title)("DELUCYX daemon unreachable"))}

${lbl("socket", 8)}${fg(C.text)(socketPath)}
${lbl("error", 8)}${fg(C.bad)(statusError ?? "unknown")}

${fg(C.label)("Install and start the privileged daemon (runs as root, boots idle):")}
  ${fg(C.accent)("sudo delucyx install")}

${fg(C.warn)("i")} ${fg(C.text)("run that now (asks for your password)")}   ${fg(C.warn)("r")} ${fg(C.text)("retry")}   ${fg(C.warn)("q")} ${fg(C.text)("quit")}

${fg(C.label)("No daemon wanted? Direct root mode:")} ${fg(C.accent)("sudo delucyx menu")}
${fg(C.label)("This TUI is a client only: it never touches ARP/BPF and never needs sudo.")}
${fg(C.label)("Nothing is ever cut automatically — you always confirm each start.")}
`
    }

    renderHeader()
    renderBanner()
    renderRows()
    renderInfo()
    renderModal()
    ensureSpinner()
    keybar.content = connected
      ? t`${fg(C.accent)("↑↓")}${fg(C.label)(" move  ")}${fg(C.accent)("space")}${fg(C.label)(" select  ")}${fg(C.accent)("a")}${fg(C.label)(" all  ")}${fg(C.accent)("c")}${fg(C.label)(" cut  ")}${fg(C.accent)("m")}${fg(C.label)(" mitm  ")}${fg(C.accent)("s")}${fg(C.label)(" stop  ")}${fg(C.accent)("h")}${fg(C.label)(" hold  ")}${fg(C.accent)("u")}${fg(C.label)(" auto  ")}${fg(C.accent)("w")}${fg(C.label)(view === "wifi" ? " devices  " : " wifi  ")}${fg(C.accent)("r")}${fg(C.label)(" refresh  ")}${fg(C.accent)("q")}${fg(C.label)(" quit")}`
      : t`${fg(C.accent)("i")}${fg(C.label)(" install daemon  ")}${fg(C.accent)("r")}${fg(C.label)(" retry  ")}${fg(C.accent)("q")}${fg(C.label)(" quit")}`
  }

  // ------------------------------------------------------------------ status
  /** Rate is derived from the daemon's cumulative frame counter, per wall second. */
  function recordSample(status: StatusSnapshot): void {
    const frames = status.framesSent
    if (frames === undefined) return
    const now = nowMs()
    if (lastFramesSent !== null && lastSampleMs !== null) {
      const elapsed = (now - lastSampleMs) / 1000
      if (elapsed > 0) {
        sampleIntervalMs = elapsed * 1000
        samples.push({
          rate: Math.max(0, (frames - lastFramesSent) / elapsed),
          targets: status.targets.length,
        })
        if (samples.length > MAX_SAMPLES) samples.splice(0, samples.length - MAX_SAMPLES)
      }
    }
    lastFramesSent = frames
    lastSampleMs = now
  }

  function applyStatus(result: StatusResult): void {
    if (!result.ok) {
      statusError = result.error
      snapshot = null
      render()
      return
    }
    statusError = null
    snapshot = result.status
    const devices = result.status.devices
    const nearby = result.status.nearby
    recordSample(result.status)

    const keys = cursorKeys(devices, nearby)
    const wanted = view === "wifi" ? cursorAp : cursorIp
    const atKey = wanted === null ? -1 : keys.indexOf(wanted)
    if (atKey >= 0) cursor = atKey
    if (cursor >= keys.length) cursor = Math.max(0, keys.length - 1)
    if (cursor < 0) cursor = 0
    if (view === "wifi") cursorAp = keys[cursor] ?? null
    else cursorIp = keys[cursor] ?? null

    // Selection survives polls keyed by IP; drop entries whose device is gone
    // (kept while the list is empty, e.g. mid-rescan).
    if (devices.length > 0) {
      const present = new Set(devices.map((device) => device.ip))
      for (const ip of [...selected]) if (!present.has(ip)) selected.delete(ip)
    }
    render()
  }

  function pollOnce(): Promise<void> {
    if (inflight !== null) return inflight
    const task = (async () => {
      let result: StatusResult
      try {
        result = await client.status()
      } catch (err) {
        result = { ok: false, error: describeError(err) }
      }
      applyStatus(result)
    })().finally(() => {
      inflight = null
    })
    inflight = task
    return task
  }

  // ---------------------------------------------------------------- commands
  function pushActivity(ok: boolean, message: string): void {
    activity.push({ clock: clock(), text: message, ok })
    if (activity.length > ACTIVITY_ROWS) activity.splice(0, activity.length - ACTIVITY_ROWS)
  }

  function setAction(ok: boolean, message: string): void {
    action = message
    pushActivity(ok, message)
    render()
  }

  async function runCommand(label: string, run: () => Promise<CommandResult>): Promise<CommandResult> {
    let result: CommandResult
    try {
      result = await run()
    } catch (err) {
      result = { ok: false, error: describeError(err) }
    }
    setAction(result.ok, result.ok ? `${label} — ok` : `${label} — ${result.error}`)
    await pollOnce()
    return result
  }

  /** Reason the daemon cannot be driven right now, or `null` when it can. */
  function daemonReady(): string | null {
    if (snapshot === null) return `daemon unreachable: ${statusError ?? "unknown error"}`
    if (snapshot.protocol !== PROTOCOL_VERSION) return "stale daemon — run: sudo delucyx upgrade"
    return null
  }

  function openConfirm(kind: ConfirmKind): void {
    const blocked = daemonReady()
    if (blocked !== null) {
      setAction(false, blocked)
      return
    }
    if (kind !== "stop" && selectedTargets().length === 0) {
      setAction(false, "no targets selected — use space or a")
      return
    }
    modal = kind
    render()
  }

  async function confirmModal(): Promise<void> {
    const kind = modal
    modal = null
    render()
    if (kind === null) return
    if (kind === "stop") {
      await runCommand("stop", () => client.stop())
      return
    }
    const targets = selectedTargets()
    const result = await runCommand(`${kind} ${targets.length} target(s)`, () => client.start(targets, kind, kind === "mitm"))
    if (result.ok) lastStartMode = kind
  }

  // ------------------------------------------------------------------- input
  function moveCursor(delta: number): void {
    const keys = cursorKeys(snapshot?.devices ?? [], snapshot?.nearby ?? [])
    if (keys.length === 0) return
    cursor = Math.min(keys.length - 1, Math.max(0, cursor + delta))
    setActiveKey(keys[cursor] ?? null)
    revealCursor()
    render()
  }

  function jumpCursor(where: "top" | "bottom"): void {
    const keys = cursorKeys(snapshot?.devices ?? [], snapshot?.nearby ?? [])
    if (keys.length === 0) return
    cursor = where === "top" ? 0 : keys.length - 1
    setActiveKey(keys[cursor] ?? null)
    revealCursor()
    render()
  }

  function setActiveKey(key: string | null): void {
    if (view === "wifi") cursorAp = key
    else cursorIp = key
  }

  function toggleSelect(): void {
    if (view === "wifi") {
      setAction(false, "wifi view — press w for the device list to select targets")
      return
    }
    const device = (snapshot?.devices ?? [])[cursor]
    if (device === undefined) return
    if (selected.has(device.ip)) selected.delete(device.ip)
    else selected.add(device.ip)
    render()
  }

  /** Swaps the pane between the LAN device table and the neighbour (Wi-Fi) table. */
  function switchView(): void {
    view = view === "wifi" ? "devices" : "wifi"
    cursor = 0
    if (view === "wifi") {
      const keys = cursorKeys([], snapshot?.nearby ?? [])
      cursorAp = keys[0] ?? null
      setAction(true, `wifi view — ${snapshot?.nearby.length ?? 0} network(s) heard`)
    } else {
      cursorIp = (snapshot?.devices ?? [])[0]?.ip ?? null
      setAction(true, "device view")
    }
  }

  function deviceOnlyKeys(): boolean {
    const allowed = view === "devices"
    if (!allowed) setAction(false, "wifi view — press w to go back to the device list")
    return allowed
  }

  function handleModalKey(key: KeyEvent): void {
    const name = key.name.toLowerCase()
    if (name === "y") {
      void confirmModal()
      return
    }
    if (name === "n" || name === "escape") {
      modal = null
      setAction(true, "cancelled")
    }
  }

  function handleNavKey(key: KeyEvent): void {
    switch (key.name) {
      case "up":
      case "k":
        moveCursor(-1)
        return
      case "down":
      case "j":
        moveCursor(1)
        return
      case "space":
        toggleSelect()
        return
      case "a":
        if (!deviceOnlyKeys()) return
        selected.clear()
        for (const device of snapshot?.devices ?? []) if (isValidTarget(device)) selected.add(device.ip)
        render()
        return
      case "n":
        selected.clear()
        render()
        return
      case "w":
        switchView()
        return
      case "g":
      case "G":
        jumpCursor(key.name === "G" || key.shift ? "bottom" : "top")
        return
      case "c":
        if (!deviceOnlyKeys()) return
        openConfirm("cut")
        return
      case "m":
        if (!deviceOnlyKeys()) return
        openConfirm("mitm")
        return
      case "s":
        openConfirm("stop")
        return
      case "h": {
        const blocked = daemonReady()
        if (blocked !== null) {
          setAction(false, blocked)
          return
        }
        void runCommand("hold", () => client.hold())
        return
      }
      case "u": {
        const blocked = daemonReady()
        if (blocked !== null) {
          setAction(false, blocked)
          return
        }
        lastStartMode = "cut"
        void runCommand("auto", () => client.resume())
        return
      }
      case "r": {
        const blocked = daemonReady()
        if (blocked !== null) {
          // Offline: `r` retries the connection instead of asking for a rescan.
          void pollOnce()
          return
        }
        void runCommand("refresh", () => client.refresh())
        return
      }
      case "i": {
        if (snapshot !== null) {
          setAction(false, "daemon already reachable — nothing to install")
          return
        }
        const install = options.onInstallDaemon
        if (install === undefined) {
          setAction(false, "install manually: sudo delucyx install")
          return
        }
        if (installing) return
        installing = true
        setAction(true, "installing daemon — finish the sudo prompt in this terminal")
        void (async () => {
          try {
            await install()
            installing = false
            setAction(true, "install finished — connecting")
          } catch (err) {
            installing = false
            setAction(false, `install failed: ${describeError(err)}`)
          }
          await pollOnce()
        })()
        return
      }
      case "q":
        if (options.onQuit !== undefined) options.onQuit()
        else {
          destroy()
          renderer.destroy()
        }
        return
      default:
    }
  }

  function onKey(key: KeyEvent): void {
    if (destroyed) return
    if (modal !== null) handleModalKey(key)
    else handleNavKey(key)
  }

  function destroy(): void {
    if (destroyed) return
    destroyed = true
    clearInterval(timer)
    clearInterval(spinnerTimer)
    renderer.keyInput.off("keypress", onKey)
    client.close()
  }

  renderer.keyInput.on("keypress", onKey)
  const timer = pollMs > 0 ? setInterval(() => {
    if (modal === null && !installing) void pollOnce()
  }, pollMs) : undefined

  render()
  void pollOnce()

  return {
    destroy,
    async refreshNow(): Promise<void> {
      const pending = inflight
      if (pending !== null) await pending
      await pollOnce()
    },
    state(): AppState {
      return {
        connected: snapshot !== null,
        view,
        cursor,
        cursorIp,
        cursorAp,
        selected: [...selected],
        modal,
        action,
      }
    },
  }
}
