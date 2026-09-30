import { expect, test } from "bun:test"
import { createTestRenderer } from "@opentui/core/testing"
import { createApp, type AppHandle, type AppOptions } from "./app"
import { installArgv } from "./install"
import { signalBar, signalLevel, sparkline } from "./chart"
import { DEFAULT_SOCKET_PATH, PROTOCOL_VERSION } from "./ipc"
import type { CommandResult, DelucyxClient, StartMode, StatusResult, StatusSnapshot } from "./ipc"
import type { TestRendererSetup } from "@opentui/core/testing"

class StubClient implements DelucyxClient {
  readonly socketPath = DEFAULT_SOCKET_PATH
  readonly calls: { method: string; args: unknown[] }[] = []
  statusResult: StatusResult

  constructor(statusResult: StatusResult) {
    this.statusResult = statusResult
  }

  async status(): Promise<StatusResult> {
    this.calls.push({ method: "status", args: [] })
    return this.statusResult
  }

  async refresh(): Promise<CommandResult> {
    this.calls.push({ method: "refresh", args: [] })
    return { ok: true, targets: [] }
  }

  async start(targets: string[], mode: StartMode, forward: boolean): Promise<CommandResult> {
    this.calls.push({ method: "start", args: [targets, mode, forward] })
    return { ok: true, targets }
  }

  async stop(): Promise<CommandResult> {
    this.calls.push({ method: "stop", args: [] })
    return { ok: true, targets: [] }
  }

  async hold(): Promise<CommandResult> {
    this.calls.push({ method: "hold", args: [] })
    return { ok: true, targets: [] }
  }

  async resume(): Promise<CommandResult> {
    this.calls.push({ method: "resume", args: [] })
    return { ok: true, targets: [] }
  }

  close(): void {
    this.calls.push({ method: "close", args: [] })
  }
}

function makeStatus(overrides: Partial<StatusSnapshot> = {}): StatusSnapshot {
  return {
    protocol: PROTOCOL_VERSION,
    running: true,
    hold: false,
    mode: "auto",
    iface: "en0",
    ip: "192.168.1.5",
    gateway: "192.168.1.1",
    ssid: "KopiRumah",
    ssidChannel: 44,
    ssidBand: "5GHz",
    ssidSignal: -46,
    scanning: false,
    // 2025-09-30T00:00:00Z
    lastScan: 1759190400,
    targets: ["192.168.1.20"],
    devices: [
      {
        ip: "192.168.1.1",
        mac: "aa:bb:cc:00:00:01",
        hostname: "router",
        isGateway: true,
        isSelf: false,
        spoofing: false,
      },
      {
        ip: "192.168.1.10",
        mac: "aa:bb:cc:00:00:10",
        hostname: "laptop",
        isGateway: false,
        isSelf: false,
        spoofing: false,
      },
      {
        ip: "192.168.1.5",
        mac: "aa:bb:cc:00:00:05",
        hostname: "self",
        isGateway: false,
        isSelf: true,
        spoofing: false,
      },
      {
        ip: "192.168.1.20",
        mac: "aa:bb:cc:00:00:20",
        hostname: "",
        isGateway: false,
        isSelf: false,
        spoofing: true,
      },
    ],
    nearby: [
      {
        ssid: "KopiTetangga",
        channel: 6,
        band: "2.4GHz",
        security: "WPA2",
        signal: -58,
        phymode: "n",
      },
      {
        ssid: "KopiTetangga-5G",
        channel: 149,
        band: "5GHz",
        security: "WPA2/WPA3",
        signal: -71,
        phymode: "ac",
      },
    ],
    ...overrides,
  }
}

/** Boots the app on a test renderer with polling disabled so tests stay deterministic. */
async function boot(
  client: DelucyxClient,
  options: Partial<AppOptions> = {},
): Promise<{ setup: TestRendererSetup; app: AppHandle }> {
  const setup = await createTestRenderer({ width: 140, height: 24 })
  const app = createApp(setup.renderer, client, { pollMs: 0, now: () => 1759190460_000, ...options })
  await app.refreshNow()
  await setup.renderOnce()
  return { setup, app }
}

/** Moves the cursor off the gateway row and back, returning the row under the cursor. */
async function selectLaptop(setup: TestRendererSetup, app: AppHandle): Promise<void> {
  setup.mockInput.pressArrow("down")
  setup.mockInput.pressKey(" ")
  await setup.flush()
  expect(app.state().cursorIp).toBe("192.168.1.10")
}

test("renders device rows, header and badge", async () => {
  const client = new StubClient({ ok: true, status: makeStatus() })
  const { setup, app } = await boot(client)
  try {
    const frame = setup.captureCharFrame()
    expect(frame).toContain("DELUCYX")
    expect(frame).toContain("[AUTO]")
    expect(frame).toContain("en0")
    expect(frame).toContain("192.168.1.1")
    expect(frame).toContain("192.168.1.10")
    expect(frame).toContain("192.168.1.20")
    expect(frame).toContain("router")
    expect(frame).toContain("laptop")
    // one flat table: columns, roles and markers, no panel chrome
    expect(frame).toContain("IP")
    expect(frame).toContain("MAC")
    expect(frame).toContain("HOST")
    expect(frame).toContain("ROLE")
    expect(frame).toContain("●") // currently spoofing
    expect(frame).toContain("GW")
    expect(frame).toContain("SELF")
    expect(frame).toContain("tx/s")
    expect(frame).toContain("dev ·")
    expect(frame).not.toContain("┌─ DEVICES")
  } finally {
    app.destroy()
    setup.renderer.destroy()
  }
})

test("nearby wifi rows render but never take the cursor or selection", async () => {
  const client = new StubClient({ ok: true, status: makeStatus() })
  const { setup, app } = await boot(client)
  try {
    const frame = setup.captureCharFrame()
    expect(frame).toContain("nearby wifi")
    expect(frame).toContain("KopiTetangga")
    expect(frame).toContain("AP")
    expect(frame).toContain("ch 149 5GHz")
    expect(frame).toContain("2 ap")
    // Signal meters: filled blocks scaled to RSSI, joined network included in the header.
    expect(frame).toContain(`${signalBar(-58)} -58 dBm`)
    expect(frame).toContain(`${signalBar(-71)} -71 dBm`)
    expect(frame).toContain(`${signalBar(-46)} -46 dBm`)
    expect(signalLevel(-58)).toBeGreaterThan(signalLevel(-71))

    // `a` marks LAN devices only — an AP has no IP and must never enter a cut request.
    setup.mockInput.pressKey("a")
    await setup.flush()
    expect(app.state().selected.sort()).toEqual(["192.168.1.10", "192.168.1.20"])

    // Cursor walks the device list and stops at the last device, not the AP rows.
    for (let i = 0; i < 6; i++) setup.mockInput.pressArrow("down")
    await setup.flush()
    expect(app.state().cursorIp).toBe("192.168.1.20")

    setup.mockInput.pressKey("c")
    await setup.renderOnce()
    setup.mockInput.pressKey("y")
    await setup.flush()
    expect(client.calls.find((call) => call.method === "start")?.args).toEqual([
      ["192.168.1.10", "192.168.1.20"],
      "cut",
      false,
    ])
  } finally {
    app.destroy()
    setup.renderer.destroy()
  }
})

test("space selects a device and c then y starts cut without forwarding", async () => {
  const client = new StubClient({ ok: true, status: makeStatus() })
  const { setup, app } = await boot(client)
  try {
    await selectLaptop(setup, app)
    expect(app.state().selected).toEqual(["192.168.1.10"])
    expect(setup.captureCharFrame()).toContain("◆")

    setup.mockInput.pressKey("c")
    await setup.renderOnce()
    expect(app.state().modal).toBe("cut")
    expect(setup.captureCharFrame()).toContain("Start CUT?")

    setup.mockInput.pressKey("y")
    await setup.flush()

    expect(client.calls.find((call) => call.method === "start")?.args).toEqual([["192.168.1.10"], "cut", false])
    expect(app.state().modal).toBeNull()
  } finally {
    app.destroy()
    setup.renderer.destroy()
  }
})

test("m then y starts mitm with forwarding", async () => {
  const client = new StubClient({ ok: true, status: makeStatus() })
  const { setup, app } = await boot(client)
  try {
    await selectLaptop(setup, app)

    setup.mockInput.pressKey("m")
    await setup.renderOnce()
    expect(app.state().modal).toBe("mitm")

    setup.mockInput.pressKey("y")
    await setup.flush()

    expect(client.calls.find((call) => call.method === "start")?.args).toEqual([["192.168.1.10"], "mitm", true])
  } finally {
    app.destroy()
    setup.renderer.destroy()
  }
})

test("h holds and u resumes", async () => {
  const client = new StubClient({ ok: true, status: makeStatus() })
  const { setup, app } = await boot(client)
  try {
    setup.mockInput.pressKey("h")
    await setup.flush()
    expect(client.calls.some((call) => call.method === "hold")).toBe(true)

    setup.mockInput.pressKey("u")
    await setup.flush()
    expect(client.calls.some((call) => call.method === "resume")).toBe(true)
  } finally {
    app.destroy()
    setup.renderer.destroy()
  }
})

test("renders the onboarding view when the socket is unreachable", async () => {
  const client = new StubClient({
    ok: false,
    error: "Failed to connect to /var/run/delucyx.sock: ConnectionRefused",
  })
  const { setup, app } = await boot(client)
  try {
    const frame = setup.captureCharFrame()
    expect(frame).toContain("daemon unreachable")
    expect(frame).toContain("ConnectionRefused")
    expect(frame).toContain("sudo delucyx install")
    expect(app.state().connected).toBe(false)

    // Every key must stay harmless while the daemon is down.
    setup.mockInput.pressKey("c")
    setup.mockInput.pressKey("h")
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressKey(" ")
    await setup.flush()
    expect(app.state().modal).toBeNull()
    expect(app.state().connected).toBe(false)
    expect(client.calls.some((call) => call.method === "start")).toBe(false)
    expect(client.calls.some((call) => call.method === "hold")).toBe(false)
    expect(client.calls.some((call) => call.method === "refresh")).toBe(false)

    // `r` re-probes the socket instead of sending a command.
    const before = client.calls.filter((call) => call.method === "status").length
    setup.mockInput.pressKey("r")
    await setup.flush()
    expect(client.calls.filter((call) => call.method === "status").length).toBe(before + 1)
  } finally {
    app.destroy()
    setup.renderer.destroy()
  }
})

test("offline i runs the installer and offline keys stay harmless", async () => {
  const client = new StubClient({ ok: false, error: "Failed to connect: ECONNREFUSED" })
  let installs = 0
  const { setup, app } = await boot(client, {
    onInstallDaemon: async () => {
      installs += 1
    },
  })
  try {
    expect(setup.captureCharFrame()).toContain("install daemon")

    setup.mockInput.pressKey("i")
    await setup.flush()
    expect(installs).toBe(1)
    expect(app.state().action).toContain("install finished")

    // No cut/mitm request may leave the app while the daemon is unreachable.
    expect(client.calls.some((call) => call.method === "start")).toBe(false)
  } finally {
    app.destroy()
    setup.renderer.destroy()
  }
})

test("i is refused when the daemon is already reachable", async () => {
  const client = new StubClient({ ok: true, status: makeStatus() })
  let installs = 0
  const { setup, app } = await boot(client, {
    onInstallDaemon: async () => {
      installs += 1
    },
  })
  try {
    setup.mockInput.pressKey("i")
    await setup.flush()
    expect(installs).toBe(0)
    expect(app.state().action).toContain("already reachable")
  } finally {
    app.destroy()
    setup.renderer.destroy()
  }
})

test("install argv only uses sudo for non-root callers", () => {
  expect(installArgv(false, "/usr/local/bin/delucyx")).toEqual(["sudo", "/usr/local/bin/delucyx", "install"])
  expect(installArgv(true, "/usr/local/bin/delucyx")).toEqual(["/usr/local/bin/delucyx", "install"])
})

test("telemetry charts sample the daemon frame counter", async () => {
  const client = new StubClient({ ok: true, status: makeStatus({ framesSent: 1000 }) })
  let clock = 1_759_190_460_000
  const { setup, app } = await boot(client, { now: () => clock })
  try {
    // Three polls, 2 s apart, sending 40 frames each — a flat top row of bars.
    for (const framesSent of [1040, 1080, 1120]) {
      clock += 2_000
      client.statusResult = { ok: true, status: makeStatus({ framesSent }) }
      await app.refreshNow()
    }
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("tx/s")
    expect(frame).toContain("20/s") // 40 frames / 2 s
    expect(frame).toContain("peak")
    expect(/[▁▂▃▄▅▆▇█]/.test(frame)).toBe(true)
    expect(frame).toContain("targets")
  } finally {
    app.destroy()
    setup.renderer.destroy()
  }
})

test("w switches to the neighbour table, where cutting is refused", async () => {
  const client = new StubClient({ ok: true, status: makeStatus() })
  const { setup, app } = await boot(client)
  try {
    setup.mockInput.pressKey("w")
    await setup.flush()
    expect(app.state().view).toBe("wifi")
    expect(app.state().cursorAp).toBe("KopiTetangga|6")

    const frame = setup.captureCharFrame()
    expect(frame).toContain("SIGNAL")
    expect(frame).toContain("NETWORK")
    expect(frame).toContain("▸") // cursor sits on an AP row
    expect(frame).not.toContain("192.168.1.10") // the LAN table is gone

    // Cursor walks the whole neighbour list…
    setup.mockInput.pressArrow("down")
    await setup.flush()
    expect(app.state().cursorAp).toBe("KopiTetangga-5G|149")

    // …but an AP is not a target: cut/mitm and marking are refused, nothing is sent.
    setup.mockInput.pressKey("c")
    setup.mockInput.pressKey(" ")
    await setup.flush()
    expect(app.state().modal).toBeNull()
    expect(app.state().selected).toEqual([])
    expect(client.calls.some((call) => call.method === "start")).toBe(false)

    setup.mockInput.pressKey("w")
    await setup.flush()
    expect(app.state().view).toBe("devices")
    expect(setup.captureCharFrame()).toContain("192.168.1.10")
  } finally {
    app.destroy()
    setup.renderer.destroy()
  }
})

test("sparkline scales and pads to a fixed width", () => {
  expect(sparkline([], 4)).toBe("    ")
  expect(sparkline([1, 2, 3], 5)).toBe("  ▃▆█")
  expect(sparkline([5, 5, 5], 3, 5)).toBe("███")
  expect(sparkline([0, 0], 2, 0)).toBe("▁▁")
  expect(sparkline([1, 2, 3, 4, 5, 6, 7, 8, 9], 4)).toBe("▆▇██")
})

test("signal meter maps dBm to a fixed-width block bar", () => {
  expect(signalBar(-35)).toBe("█████")   // ceiling
  expect(signalBar(-95)).toBe("·····")   // floor
  expect(signalBar(0)).toBe("·····")     // radio reported nothing
  expect(signalBar(-65)).toBe("███··")
  expect(signalBar(-100)).toBe("·····")  // below the floor is clamped, never negative
  expect(signalBar(-46, 4).length).toBe(4)
  expect(signalLevel(-40)).toBeGreaterThan(signalLevel(-80))
})
