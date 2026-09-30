import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let ipc = IPCClient()
    var pollTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.systemFont(ofSize: 13)
        statusItem.button?.title = "⏳"
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let status = self.ipc.status()
            DispatchQueue.main.async {
                self.updateMenu(status: status)
            }
        }
    }

    func updateMenu(status: DaemonStatus?) {
        let menu = NSMenu()

        // ── Header ──────────────────────────────────────────────
        addLabel(menu, "delucyx v1.0.0", bold: true)
        menu.addItem(.separator())

        // ── Status ───────────────────────────────────────────────
        if let s = status {
            let dot: String
            let label: String
            if s.running        { dot = "🟢"; label = "Active" }
            else if s.manualStop { dot = "🟡"; label = "Stopped (manual)" }
            else                 { dot = "🔴"; label = "Idle" }
            addLabel(menu, "\(dot) \(label)")

            if !s.iface.isEmpty {
                addLabel(menu, "Interface: \(s.iface)  \(s.ip)", small: true)
            }

            menu.addItem(.separator())

            if s.running && !s.targets.isEmpty {
                addLabel(menu, "Cutting (\(s.targets.count) targets):", small: true)
                for t in s.targets {
                    addLabel(menu, "   · \(t)", small: true)
                }
            } else if !s.running {
                addLabel(menu, "No active spoof", small: true)
            }

            statusItem.button?.title = s.running ? "🛡" : (s.manualStop ? "🟡" : "⚫")
        } else {
            addLabel(menu, "🔴 Daemon not running")
            addLabel(menu, "Run: sudo delucyx install", small: true)
            statusItem.button?.title = "⚠️"
        }

        // ── Actions ───────────────────────────────────────────────
        menu.addItem(.separator())

        let isRunning = status?.running ?? false
        if isRunning {
            let stopItem = NSMenuItem(title: "Stop All", action: #selector(stopAll), keyEquivalent: "s")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(title: "Start All", action: #selector(scanNetwork), keyEquivalent: "s")
            startItem.target = self
            startItem.isEnabled = status != nil
            menu.addItem(startItem)
        }

        let scanItem = NSMenuItem(title: "Scan Network", action: #selector(scanNetwork), keyEquivalent: "r")
        scanItem.target = self
        scanItem.isEnabled = status != nil
        menu.addItem(scanItem)

        menu.addItem(.separator())

        let logItem = NSMenuItem(title: "Open Log…", action: #selector(openLog), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // ── Helpers ───────────────────────────────────────────────────

    private func addLabel(_ menu: NSMenu, _ text: String, bold: Bool = false, small: Bool = false) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold  { item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]) }
        if small { item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]) }
        menu.addItem(item)
    }

    // ── Actions ───────────────────────────────────────────────────

    @objc func stopAll() {
        ipc.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    @objc func scanNetwork() {
        ipc.scan()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.refresh() }
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/delucyx.log"))
    }
}
