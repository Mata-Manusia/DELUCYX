#!/usr/bin/env bun
/**
 * DELUCYX terminal UI entry point.
 *
 *   DELUCYX_SOCKET=/path/to.sock bun run start
 */
import { createCliRenderer } from "@opentui/core"
import { createApp, type AppHandle } from "./app"
import { installArgv } from "./install"
import { UnixSocketDelucyxClient } from "./ipc"

const renderer = await createCliRenderer({ exitOnCtrlC: true })
const client = new UnixSocketDelucyxClient()

let app: AppHandle | undefined

function shutdown(): void {
  app?.destroy()
  client.close()
  renderer.destroy()
}

// Ctrl+C tears the renderer down directly; make sure timers and the socket go with it.
renderer.once("destroy", () => {
  app?.destroy()
  client.close()
})

app = createApp(renderer, client, {
  onQuit: () => {
    shutdown()
    process.exit(0)
  },
  onInstallDaemon: async () => {
    const bin = process.env.DELUCYX_BIN?.length
      ? process.env.DELUCYX_BIN
      : (Bun.which("delucyx") ?? "delucyx")
    const argv = installArgv((process.getuid?.() ?? 1) === 0, bin)

    // Hand the terminal to the installer so sudo can prompt, then take it back.
    renderer.suspend()
    try {
      const proc = Bun.spawn(argv, { stdin: "inherit", stdout: "inherit", stderr: "inherit" })
      await proc.exited
    } finally {
      renderer.resume()
    }
  },
})
