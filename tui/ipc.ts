/**
 * DELUCYX TUI <-> daemon IPC client.
 *
 * Transport (see the frozen contract): AF_UNIX `SOCK_STREAM`, one request object
 * per connection, one response object + `\n`, then the server closes.
 *
 *   request   {"cmd":"status"}
 *   response  {...snapshot...} | {"ok":true,...} | {"error":"msg"}
 *
 * Every failure — missing socket, refused connection, malformed payload, timeout —
 * is returned as a value so the UI can render it. Nothing here throws.
 */

export const PROTOCOL_VERSION = 3

export const DEFAULT_SOCKET_PATH = "/var/run/delucyx.sock"

/** Request timeout; an unresponsive daemon must not freeze the UI. */
const REQUEST_TIMEOUT_MS = 5_000

/** Daemon-side spoof mode (`status.mode`). */
export type SpoofMode = "auto" | "manual" | "hold"

/** Mode requested by `start`. */
export type StartMode = "cut" | "mitm"

export interface Device {
  ip: string
  mac: string
  hostname: string
  isGateway: boolean
  isSelf: boolean
  /** ip is in `status.targets`. */
  spoofing: boolean
}

/** A Wi-Fi network the radio hears but is not joined to. */
export interface NearbyWifi {
  ssid: string
  /** Primary channel number, 0 when the daemon could not parse it. */
  channel: number
  band: string
  /** Short security label: "WPA2", "WPA3", "WPA2/WPA3", "OPEN", … */
  security: string
  /** dBm (negative), 0 when unknown. */
  signal: number
  phymode: string
}

export interface StatusSnapshot {
  /** `undefined` when the daemon predates protocol 2 (stale daemon). */
  protocol: number | undefined
  running: boolean
  hold: boolean
  mode: SpoofMode
  iface: string
  ip: string
  gateway: string
  /** Wi-Fi network name; "" for wired interfaces or when unknown. */
  ssid: string
  /** Channel and band of the joined network; 0/"" when unknown. */
  ssidChannel: number
  ssidBand: string
  /** RSSI of the joined network in dBm (negative); 0 when unknown. */
  ssidSignal: number
  scanning: boolean
  /** Unix seconds, 0 when never scanned. */
  lastScan: number
  /** Total frames handed to the kernel; absent on protocol 1 daemons. */
  framesSent?: number
  targets: string[]
  devices: Device[]
  /** Neighbouring Wi-Fi networks (heard, not joined); empty before protocol 3. */
  nearby: NearbyWifi[]
}

export type CommandResult = { ok: true; targets: string[] } | { ok: false; error: string }

export type StatusResult = { ok: true; status: StatusSnapshot } | { ok: false; error: string }

/**
 * The only surface `createApp` depends on, so tests can inject a stub.
 * Implementations must never reject; failures come back as `ok:false`.
 */
export interface DelucyxClient {
  /** Path of the daemon socket, for display on the onboarding screen. */
  readonly socketPath?: string
  status(): Promise<StatusResult>
  /** Rescan the network, keep the current mode (`{"cmd":"refresh"}`). */
  refresh(): Promise<CommandResult>
  start(targets: string[], mode: StartMode, forward: boolean): Promise<CommandResult>
  stop(): Promise<CommandResult>
  hold(): Promise<CommandResult>
  resume(): Promise<CommandResult>
  /** Release client-side resources. Safe to call more than once. */
  close(): void
}

type WireResult = { ok: true; value: Record<string, unknown> } | { ok: false; error: string }

export function describeError(err: unknown): string {
  if (err instanceof Error) return err.message || String(err)
  return String(err)
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : ""
}

function parseDevice(raw: unknown): Device | undefined {
  if (typeof raw !== "object" || raw === null) return undefined
  const o = raw as Record<string, unknown>
  const ip = asString(o.ip)
  if (ip === "") return undefined
  return {
    ip,
    mac: asString(o.mac),
    hostname: asString(o.hostname),
    isGateway: o.isGateway === true,
    isSelf: o.isSelf === true,
    spoofing: o.spoofing === true,
  }
}

/**
 * Defensive parse: a stale (protocol 1) daemon may answer with a different shape,
 * and the UI must still render instead of crashing.
 */
export function parseStatus(raw: unknown): StatusSnapshot {
  const o = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>
  const mode = o.mode
  return {
    protocol: typeof o.protocol === "number" ? o.protocol : undefined,
    running: o.running === true,
    hold: o.hold === true,
    mode: mode === "manual" || mode === "hold" ? mode : "auto",
    iface: asString(o.iface),
    ip: asString(o.ip),
    gateway: asString(o.gateway),
    ssid: asString(o.ssid),
    ssidChannel: typeof o.ssidChannel === "number" && Number.isFinite(o.ssidChannel) ? o.ssidChannel : 0,
    ssidBand: asString(o.ssidBand),
    ssidSignal: typeof o.ssidSignal === "number" && Number.isFinite(o.ssidSignal) ? o.ssidSignal : 0,
    scanning: o.scanning === true,
    lastScan: typeof o.lastScan === "number" && Number.isFinite(o.lastScan) ? o.lastScan : 0,
    framesSent:
      typeof o.framesSent === "number" && Number.isFinite(o.framesSent) ? o.framesSent : undefined,
    targets: Array.isArray(o.targets) ? o.targets.filter((t): t is string => typeof t === "string") : [],
    devices: Array.isArray(o.devices)
      ? o.devices.map(parseDevice).filter((d): d is Device => d !== undefined)
      : [],
    nearby: Array.isArray(o.nearby)
      ? o.nearby.map(parseNearby).filter((n): n is NearbyWifi => n !== undefined)
      : [],
  }
}

function parseNearby(raw: unknown): NearbyWifi | undefined {
  if (typeof raw !== "object" || raw === null) return undefined
  const o = raw as Record<string, unknown>
  const ssid = asString(o.ssid)
  if (ssid === "") return undefined
  const num = (value: unknown): number =>
    typeof value === "number" && Number.isFinite(value) ? value : 0
  return {
    ssid,
    channel: num(o.channel),
    band: asString(o.band),
    security: asString(o.security),
    signal: num(o.signal),
    phymode: asString(o.phymode),
  }
}

function commandResult(wire: WireResult): CommandResult {
  if (!wire.ok) return { ok: false, error: wire.error }
  const err = wire.value.error
  if (typeof err === "string") return { ok: false, error: err }
  const targets = Array.isArray(wire.value.targets)
    ? wire.value.targets.filter((t): t is string => typeof t === "string")
    : []
  return { ok: true, targets }
}

/** Talks to the privileged daemon over the AF_UNIX socket. Never needs sudo. */
export class UnixSocketDelucyxClient implements DelucyxClient {
  readonly socketPath: string

  constructor(socketPath: string = process.env.DELUCYX_SOCKET ?? DEFAULT_SOCKET_PATH) {
    this.socketPath = socketPath
  }

  private send(payload: Record<string, unknown>): Promise<WireResult> {
    return new Promise<WireResult>((resolve) => {
      let settled = false
      let conn: { end(): void } | undefined
      let buffer = ""
      const decoder = new TextDecoder()

      const timer = setTimeout(() => {
        finish({ ok: false, error: `daemon did not answer within ${REQUEST_TIMEOUT_MS}ms` })
      }, REQUEST_TIMEOUT_MS)
      timer.unref()

      function finish(result: WireResult): void {
        if (settled) return
        settled = true
        clearTimeout(timer)
        try {
          conn?.end()
        } catch {
          // socket already gone
        }
        resolve(result)
      }

      /** Returns a result once the buffer holds a complete JSON object. */
      const takeResponse = (): WireResult | undefined => {
        const text = buffer.trim()
        if (text === "") return undefined
        let parsed: unknown
        try {
          parsed = JSON.parse(text)
        } catch {
          return undefined // still incomplete
        }
        if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
          return { ok: false, error: "daemon sent a non-object response" }
        }
        return { ok: true, value: parsed as Record<string, unknown> }
      }

      try {
        Bun.connect({
          unix: this.socketPath,
          socket: {
            open(socket) {
              conn = socket
              socket.write(`${JSON.stringify(payload)}\n`)
            },
            data(_socket, chunk) {
              buffer += decoder.decode(chunk, { stream: true })
              const result = takeResponse()
              if (result !== undefined) finish(result)
            },
            close() {
              const result = takeResponse()
              finish(result ?? { ok: false, error: "daemon closed the connection without answering" })
            },
            error(_socket, err) {
              finish({ ok: false, error: describeError(err) })
            },
            connectError(_socket, err) {
              finish({ ok: false, error: describeError(err) })
            },
          },
        })
          .then(
            (socket) => {
              conn = socket
              if (settled) {
                try {
                  socket.end()
                } catch {
                  // already closed
                }
              }
            },
            (err: unknown) => {
              finish({ ok: false, error: describeError(err) })
            },
          )
          .catch(() => {
            // a throwing socket callback cannot escape; the request is already settled
          })
      } catch (err) {
        finish({ ok: false, error: describeError(err) })
      }
    })
  }

  async status(): Promise<StatusResult> {
    const wire = await this.send({ cmd: "status" })
    if (!wire.ok) return { ok: false, error: wire.error }
    if (typeof wire.value.error === "string") return { ok: false, error: wire.value.error }
    return { ok: true, status: parseStatus(wire.value) }
  }

  async refresh(): Promise<CommandResult> {
    return commandResult(await this.send({ cmd: "refresh" }))
  }

  async start(targets: string[], mode: StartMode, forward: boolean): Promise<CommandResult> {
    return commandResult(await this.send({ cmd: "start", targets, mode, forward }))
  }

  async stop(): Promise<CommandResult> {
    return commandResult(await this.send({ cmd: "stop" }))
  }

  async hold(): Promise<CommandResult> {
    return commandResult(await this.send({ cmd: "hold" }))
  }

  async resume(): Promise<CommandResult> {
    return commandResult(await this.send({ cmd: "resume" }))
  }

  close(): void {
    // One connection per request: nothing is held open between commands.
  }
}
