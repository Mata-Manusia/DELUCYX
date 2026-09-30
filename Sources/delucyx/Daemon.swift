import Foundation
import Darwin

private let pidFile    = "/var/run/delucyx.pid"
private let logFile    = "/var/log/delucyx.log"
private let daemonLabel = "com.delucyx.daemon"
private let plistPath  = "/Library/LaunchDaemons/\(daemonLabel).plist"
private let daemonBinaryPath = "/usr/local/libexec/delucyx"

// MARK: - Install / Uninstall

/// Real path of the running binary. `argv[0]` alone is useless when the CLI was
/// started through PATH (it is just "delucyx", i.e. relative to the cwd).
func currentExecutablePath() -> String {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buffer, &size) == 0 {
        if let resolved = realpath(buffer, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return String(cString: buffer)
    }
    return CommandLine.arguments[0]
}

/// Copies the running binary to a root-owned path so the launchd job can never
/// execute a user-writable file. Returns the path the daemon should run from.
func stageDaemonBinary() -> String {
    let source = currentExecutablePath()
    let fm = FileManager.default

    guard fm.fileExists(atPath: source) else {
        print("Error: binary not found at \(source)")
        print("Build + install first: make && make install")
        exit(1)
    }

    do {
        try fm.createDirectory(atPath: (daemonBinaryPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        if fm.fileExists(atPath: daemonBinaryPath) {
            try fm.removeItem(atPath: daemonBinaryPath)
        }
        try fm.copyItem(atPath: source, toPath: daemonBinaryPath)
        try fm.setAttributes([
            .posixPermissions: 0o755,
            .ownerAccountID: 0,
            .groupOwnerAccountID: 0
        ], ofItemAtPath: daemonBinaryPath)
        return daemonBinaryPath
    } catch {
        print("Warning: cannot stage \(daemonBinaryPath) (\(error.localizedDescription))")
        print("         falling back to \(source)")
        return source
    }
}

// MARK: - launchd lifecycle
//
// macOS 11+ wants the domain API (`bootstrap`/`bootout`/`kickstart`). The legacy
// `launchctl load -w` returns "Load failed: 5: Input/output error" whenever the label is
// already registered, which left the job booted out but reported as installed.

private var daemonDomainTarget: String { "system/\(daemonLabel)" }

private func launchJobRegistered() -> Bool {
    runCmdQuiet("/bin/launchctl", ["print", daemonDomainTarget]) == 0
}

private func bootoutJob() {
    _ = runCmdQuiet("/bin/launchctl", ["bootout", daemonDomainTarget])
}

/// Registers the job from its plist; false means launchd refused (caller falls back).
private func bootstrapJob() -> Bool {
    guard runCmdQuiet("/bin/launchctl", ["bootstrap", "system", plistPath]) == 0 else { return false }
    _ = runCmdQuiet("/bin/launchctl", ["enable", daemonDomainTarget])
    return true
}

/// Starts the job now; `-k` replaces an already-running instance.
private func kickstartJob() {
    _ = runCmdQuiet("/bin/launchctl", ["kickstart", "-k", daemonDomainTarget])
}

/// Waits for the daemon to publish its PID file, so callers can report a real state.
private func waitForDaemonPid(seconds: Double = 3) -> pid_t? {
    var waited = 0.0
    while waited < seconds {
        if let pid = readPid() { return pid }
        Thread.sleep(forTimeInterval: 0.1)
        waited += 0.1
    }
    return readPid()
}

func installDaemon() {
    guard getuid() == 0 else {
        print("Error: install requires sudo")
        exit(1)
    }

    let binaryPath = stageDaemonBinary()

    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(daemonLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(binaryPath)</string>
            <string>--daemon</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>\(logFile)</string>
        <key>StandardErrorPath</key>
        <string>\(logFile)</string>
    </dict>
    </plist>
    """

    do {
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
    } catch {
        print("Error writing plist: \(error)")
        exit(1)
    }

    // Re-register instead of `load -w`: that legacy call fails with EIO on a label that is
    // already known to launchd, leaving an installed-but-dead job behind.
    if launchJobRegistered() { bootoutJob() }
    if !bootstrapJob() {
        runCmd("/bin/launchctl", ["load", "-w", plistPath])
    }
    kickstartJob()

    print("Installed: \(daemonLabel)")
    print("Binary   : \(binaryPath)")
    print("Log      : \(logFile)")
    if let pid = waitForDaemonPid() {
        print("Running  : PID \(pid) (idle/held)")
    } else {
        print("Warning  : launchd did not start it — check \(logFile)")
        print("           try: sudo launchctl bootstrap system \(plistPath)")
    }
    print("Starts on boot, idle (held) — nothing is cut until you enable it.")
    print("Enable   : press 'c' + 'y' in the TUI, or sudo delucyx resume for auto mode")
    print("")
    print("To stop  : sudo delucyx stop all")
    print("To remove: sudo delucyx uninstall")
}

func uninstallDaemon() {
    guard getuid() == 0 else {
        print("Error: uninstall requires sudo")
        exit(1)
    }

    if FileManager.default.fileExists(atPath: plistPath) {
        if launchJobRegistered() { bootoutJob() }
        runCmd("/bin/launchctl", ["unload", "-w", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
        print("Uninstalled: \(daemonLabel)")
    } else {
        print("Not installed.")
    }

    if FileManager.default.fileExists(atPath: daemonBinaryPath) {
        try? FileManager.default.removeItem(atPath: daemonBinaryPath)
        print("Removed staged binary: \(daemonBinaryPath)")
    }

    cleanPidFile()
}

func upgradeDaemon() {
    guard getuid() == 0 else {
        print("Error: upgrade requires sudo")
        exit(1)
    }

    guard FileManager.default.fileExists(atPath: plistPath) else {
        print("Not installed. Run: sudo delucyx install")
        exit(1)
    }

    let staged = stageDaemonBinary()
    print("Binary   : \(staged)")

    print("Stopping daemon...")
    // SIGTERM to running process so it restores ARP tables cleanly
    if let pid = readPid(), kill(pid, 0) == 0 {
        kill(pid, SIGTERM)
        // Wait up to 3s for clean shutdown
        var waited = 0
        while kill(pid, 0) == 0 && waited < 30 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
    }

    // launchctl stop — launchd will auto-restart due to KeepAlive=true
    runCmd("/bin/launchctl", ["stop", daemonLabel])
    Thread.sleep(forTimeInterval: 1)

    print("Restarting with new binary...")
    if launchJobRegistered() {
        kickstartJob()
    } else if !bootstrapJob() {
        runCmd("/bin/launchctl", ["load", "-w", plistPath])
    }

    if let pid = waitForDaemonPid(seconds: 4) {
        print("Upgraded — running (PID \(pid))")
        print("Log: \(logFile)")
    } else {
        // Last resort: cycle the registration from scratch.
        bootoutJob()
        if bootstrapJob() { kickstartJob() }
        Thread.sleep(forTimeInterval: 1)
        if let pid = waitForDaemonPid() {
            print("Upgraded — running (PID \(pid))")
        } else {
            print("Started. Check log: \(logFile)")
        }
    }
}

// MARK: - Stop / Status

func stopAll() {
    if let resp = sendIPC(["cmd": "stop"]), resp["ok"] as? Bool == true {
        print("Stopped — spoofing halted, daemon held")
        print("Resume with: sudo delucyx resume")
        return
    }

    // Daemon unreachable — legacy signal path
    guard let pid = readPid() else {
        // Try by launchctl bootout as fallback
        if getuid() == 0 {
            runCmd("/bin/launchctl", ["stop", daemonLabel])
            print("Stop signal sent.")
        } else {
            print("No active delucyx process found. (Try sudo)")
        }
        return
    }

    if kill(pid, SIGTERM) == 0 {
        print("Stopped delucyx (PID \(pid))")
    } else {
        print("Process \(pid) not found. Cleaning up.")
        cleanPidFile()
    }
}

func holdDaemon() {
    guard let resp = sendIPC(["cmd": "hold"]), resp["ok"] as? Bool == true else {
        print("Daemon not reachable. Install first: sudo delucyx install")
        return
    }
    print("Held — daemon idle, no auto-spoof until 'resume'")
}

func resumeDaemon() {
    guard let resp = sendIPC(["cmd": "resume"]), resp["ok"] as? Bool == true else {
        print("Daemon not reachable. Install first: sudo delucyx install")
        return
    }
    print("Resumed — auto mode active")
}

func daemonStatus() {
    if let s = sendIPC(["cmd": "status"]) {
        let running  = s["running"]  as? Bool ?? false
        let mode     = s["mode"]     as? String ?? "?"
        let targets  = s["targets"]  as? [String] ?? []
        let devices  = s["devices"]  as? [[String: Any]] ?? []
        let protocolVersion = s["protocol"] as? Int ?? 1

        print("Daemon   up (protocol \(protocolVersion))")
        print("Mode     \(mode)\(running ? " — spoofing" : " — idle")")
        print("Interface \(s["iface"] as? String ?? "-")  IP \(s["ip"] as? String ?? "-")")
        let ssid = s["ssid"] as? String ?? ""
        let signal = s["ssidSignal"] as? Int ?? 0
        let channel = s["ssidChannel"] as? Int ?? 0
        let band = s["ssidBand"] as? String ?? ""
        let detail = ssid.isEmpty ? "" : "  ch \(channel) \(band)\(signal == 0 ? "" : "  \(signal) dBm")"
        print("WiFi     \(ssid.isEmpty ? "-" : ssid)\(detail)")
        print("Gateway  \(s["gateway"] as? String ?? "-")")
        let nearby = s["nearby"] as? [[String: Any]] ?? []
        print("Nearby   \(nearby.count) network(s)")
        for net in nearby.prefix(8) {
            let ssid = net["ssid"] as? String ?? "?"
            let name = ssid.count > 24 ? String(ssid.prefix(23)) + "…" : ssid
            let channel = net["channel"] as? Int ?? 0
            let band = net["band"] as? String ?? ""
            let security = net["security"] as? String ?? "?"
            let signal = net["signal"] as? Int ?? 0
            let place = name.padding(toLength: 24, withPad: " ", startingAt: 0)
            print("         \(place) ch \(channel) \(band)  \(security)  \(signal) dBm")
        }
        print("Targets  \(targets.count)\(targets.isEmpty ? "" : ": " + targets.joined(separator: ", "))")
        print("Devices  \(devices.count) known")
        if protocolVersion < ipcProtocolVersion {
            print("Warning  daemon is older than this binary — run: sudo delucyx upgrade")
        }
        print("Log      \(logFile)")
        return
    }

    print("Daemon   not reachable")
    print("Installed: \(FileManager.default.fileExists(atPath: plistPath) ? "yes" : "no")")
    if let pid = readPid(), kill(pid, 0) == 0 {
        print("PID      \(pid)")
    } else {
        print("Next step: sudo delucyx install")
    }
    print("Log      \(logFile)")
}

// MARK: - Scanning

struct ScanOutcome {
    let devices: [DeviceInfo]
    let ourMAC: MACAddr
    let gatewayIP: String
    let gatewayMAC: MACAddr?
    let wifi: WifiSurvey        // joined network + neighbours heard by the radio
}

// Wi-Fi network name of an interface ("" for wired interfaces or when unknown).
func currentSSID(_ ifname: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    task.arguments = ["-getairportnetwork", ifname]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return "" }
    task.waitUntilExit()

    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8),
          let separator = text.range(of: ": ") else { return "" }
    let name = text[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty || name.hasPrefix("You are not associated") ? "" : name
}

func deviceEntry(_ d: DeviceInfo) -> DeviceEntry {
    DeviceEntry(ip: d.ip, mac: d.mac, hostname: d.hostname, isGateway: d.isGateway, isSelf: d.isSelf)
}

// LAN scan (ARP cache + active burst when BPF is usable). Pure: never mutates shared state.
// BPF is optional so a permission failure still yields the ARP-cache view.
func collectScan(ifname: String, ourIP: String) -> ScanOutcome? {
    guard let ourMAC = getInterfaceMAC(ifname) else {
        daemonLog("MAC detect failed"); return nil
    }
    guard let gw = getGatewayIP() else {
        daemonLog("Gateway detect failed"); return nil
    }

    var all = quickScanARPTable(gatewayIP: gw, ourIP: ourIP)
    var gatewayMAC: MACAddr? = nil

    if let bpf = try? DelucyxBPF(interface: ifname) {
        defer { bpf.close() }
        gatewayMAC = try? resolveMAC(bpf: bpf, ourMAC: ourMAC, ourIP: ourIP, targetIP: gw)

        let scanned = (try? scanNetwork(bpf: bpf, ourMAC: ourMAC, ourIP: ourIP, gatewayIP: gw, ifname: ifname))?.devices ?? []
        for d in scanned where !all.contains(where: { $0.ip == d.ip }) {
            all.append(d)
        }
    } else {
        daemonLog("BPF unavailable — ARP cache only")
    }

    if gatewayMAC == nil, let cached = all.first(where: { $0.ip == gw }) {
        gatewayMAC = stringToMAC(cached.mac)
    }

    // Our own row never comes back from the scan (it is skipped), so name it from
    // the machine itself — instant, no reverse DNS.
    let machineName = ProcessInfo.processInfo.hostName
        .replacingOccurrences(of: ".local", with: "")
    let selfHostname    = all.first(where: { $0.ip == ourIP })?.hostname ?? machineName
    let gatewayHostname = all.first(where: { $0.ip == gw })?.hostname ?? ""

    let selfDevice = DeviceInfo(
        ip: ourIP, mac: macToString(ourMAC),
        hostname: selfHostname,
        isGateway: false, isSelf: true
    )
    if let idx = all.firstIndex(where: { $0.isSelf }) {
        all[idx] = selfDevice
    } else {
        all.insert(selfDevice, at: 0)
    }

    let gatewayDevice = DeviceInfo(
        ip: gw, mac: gatewayMAC.map(macToString) ?? "",
        hostname: gatewayHostname,
        isGateway: true, isSelf: false
    )
    if let idx = all.firstIndex(where: { $0.isGateway }) {
        all[idx] = gatewayDevice
    } else {
        all.insert(gatewayDevice, at: 0)
    }

    all = all.filter { !$0.ip.hasSuffix(".255") && !$0.ip.hasSuffix(".0") }
    all.sort { a, b in
        if a.isGateway != b.isGateway { return a.isGateway }
        if a.isSelf != b.isSelf { return b.isSelf }
        return a.ip.localizedStandardCompare(b.ip) == .orderedAscending
    }

    // One `system_profiler` survey answers both: the joined network and the neighbours.
    return ScanOutcome(
        devices: all,
        ourMAC: ourMAC,
        gatewayIP: gw,
        gatewayMAC: gatewayMAC,
        wifi: resolveWifi(ifname: ifname)
    )
}

// Radio survey, falling back to `networksetup` when system_profiler reports no joined
// network (wired interface, or Wi-Fi detail withheld).
func resolveWifi(ifname: String) -> WifiSurvey {
    let survey = wifiSurvey(ifname: ifname)
    if survey.current != nil { return survey }
    let ssid = currentSSID(ifname)
    guard !ssid.isEmpty else { return survey }
    let joined = WifiCurrent(ssid: ssid, channel: 0, band: "", signal: 0, phymode: "")
    return WifiSurvey(current: joined, nearby: survey.nearby)
}

// Interface + Wi-Fi identity without a LAN scan. The header must still show the joined
// network when BPF is unavailable or a scan fails — those paths never reach `collectScan`.
func publishNetwork(ifname: String, ourIP: String) {
    let wifi = resolveWifi(ifname: ifname)
    let gateway = sharedState.snapshot().gateway
    sharedState.setNetwork(iface: ifname, ip: ourIP, gateway: gateway)
    sharedState.setWifi(wifi.current, wifi.nearby)
}

// Scan and publish the device list without touching spoofing (hold/refresh path).
func refreshOnly(ifname: String, ourIP: String, reason: String) {
    daemonLog("[\(reason)] scanning only...")
    sharedState.setScanning(true)
    defer { sharedState.setScanning(false) }

    guard let scan = collectScan(ifname: ifname, ourIP: ourIP) else {
        daemonLog("Scan failed")
        return
    }
    sharedState.setNetwork(iface: ifname, ip: ourIP, gateway: scan.gatewayIP)
    sharedState.setWifi(scan.wifi.current, scan.wifi.nearby)
    sharedState.setScan(devices: scan.devices.map(deviceEntry), lastScan: Date().timeIntervalSince1970)
    daemonLog("Scan finished: \(scan.devices.count) devices")
}

func resolveVictimMAC(ifname: String, ourMAC: MACAddr, ourIP: String, targetIP: String) -> MACAddr? {
    guard let bpf = try? DelucyxBPF(interface: ifname) else { return nil }
    defer { bpf.close() }
    return try? resolveMAC(bpf: bpf, ourMAC: ourMAC, ourIP: ourIP, targetIP: targetIP)
}

// MARK: - Daemon loop

func killStaleDaemon() {
    guard let oldPid = readPid() else { return }
    if oldPid == ProcessInfo.processInfo.processIdentifier { return }
    guard kill(oldPid, 0) == 0 else { return }

    daemonLog("Stale daemon PID \(oldPid) — killing...")
    kill(oldPid, SIGTERM)
    var waited = 0
    while kill(oldPid, 0) == 0 && waited < 30 {
        Thread.sleep(forTimeInterval: 0.1)
        waited += 1
    }
    if kill(oldPid, 0) == 0 {
        kill(oldPid, SIGKILL)
    }
    daemonLog("Stale daemon killed")
}

func runDaemon() {
    killStaleDaemon()
    writePid()

    // SIGTERM/SIGINT → stop both spoof loop and daemon loop
    var sa = sigaction()
    sigemptyset(&sa.sa_mask)
    sa.__sigaction_u.__sa_handler = { _ in
        _stopFlag       = 1
        _daemonExitFlag = 1
    }
    sa.sa_flags = 0
    sigaction(SIGTERM, &sa, nil)
    sigaction(SIGINT,  &sa, nil)

    daemonLog("Started (PID \(ProcessInfo.processInfo.processIdentifier)) — mode \(sharedState.mode()) (nothing cut until enabled)")

    // Start IPC server for GUI communication
    startIPCServer()

    var lastIface: String? = nil
    var lastIP: String?    = nil
    var spoofThread: Thread? = nil
    var spoofActive          = false

    func stopSpoofing(wait: Bool = true) {
        guard spoofThread != nil || spoofActive else { return }
        daemonLog("Stopping spoof...")
        requestSpooferStop()
        if wait {
            var waited = 0
            while spoofActive && waited < 30 {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 1
            }
        }
        spoofThread = nil
        spoofActive = false
        sharedState.setSpoof(active: false, targets: [])
    }

    // `only == nil` spoofs every device on the LAN (auto mode). A list restricts to those IPs.
    @discardableResult
    func startSpoofing(ifname: String, ourIP: String, reason: String, only: [String]? = nil) -> Bool {
        stopSpoofing()
        resetSpooferStop()

        let explicit         = sharedState.explicit()
        let bidirectional    = only == nil ? true : (explicit.mode == "mitm")
        let forwardTraffic   = only == nil ? false : explicit.forward

        daemonLog("[\(reason)] \(ifname) \(ourIP) — scanning...")
        sharedState.setScanning(true)
        guard let scan = collectScan(ifname: ifname, ourIP: ourIP) else {
            sharedState.setScanning(false)
            sharedState.setSpoof(active: false, targets: [])
            daemonLog("Scan failed — will retry")
            return false
        }
        sharedState.setScanning(false)
        sharedState.setNetwork(iface: ifname, ip: ourIP, gateway: scan.gatewayIP)
        sharedState.setWifi(scan.wifi.current, scan.wifi.nearby)
        sharedState.setScan(devices: scan.devices.map(deviceEntry), lastScan: Date().timeIntervalSince1970)

        var candidates = scan.devices.filter { !$0.isGateway && !$0.isSelf && $0.ip != ourIP }
        if let only = only {
            candidates = candidates.filter { only.contains($0.ip) }
        }
        if candidates.isEmpty {
            daemonLog("No targets found — will retry")
            sharedState.setSpoof(active: false, targets: [])
            return false
        }
        guard let gatewayMAC = scan.gatewayMAC, !isAllZeroMAC(gatewayMAC) else {
            daemonLog("Gateway MAC unknown — cannot spoof")
            sharedState.setSpoof(active: false, targets: [])
            return false
        }

        var configs: [SpooferConfig] = []
        for device in candidates {
            var mac = stringToMAC(device.mac)
            if only != nil, mac == nil || isAllZeroMAC(mac!) {
                mac = resolveVictimMAC(ifname: ifname, ourMAC: scan.ourMAC, ourIP: ourIP, targetIP: device.ip)
            }
            guard let victimMAC = mac, !isAllZeroMAC(victimMAC) else { continue }
            configs.append(SpooferConfig(
                interface: ifname,
                victimIP: device.ip,
                gatewayIP: scan.gatewayIP,
                ourMAC: scan.ourMAC,
                ourIP: ourIP,
                victimMAC: victimMAC,
                gatewayMAC: gatewayMAC,
                interval: 0.3,
                bidirectional: bidirectional,
                forwardTraffic: forwardTraffic
            ))
        }

        if configs.isEmpty {
            daemonLog("No spoofable target after MAC resolution — will retry")
            sharedState.setSpoof(active: false, targets: [])
            return false
        }

        daemonLog("Spoofing \(configs.count) targets: \(configs.map(\.victimIP).joined(separator: ", "))")
        sharedState.setSpoof(active: true, targets: configs.map(\.victimIP))

        spoofActive = true
        let capturedConfigs = configs
        let t = Thread {
            do { try startMassSpoofing(configs: capturedConfigs) }
            catch { daemonLog("Spoof error: \(error)") }
            spoofActive = false
            sharedState.setSpoof(active: false, targets: [])
            daemonLog("Spoof thread exited")
        }
        t.start()
        spoofThread = t
        return true
    }

    // Restart backoff so a failing state machine cannot rescan every tick
    var nextRetry = Date.distantPast
    // Neighbour list ages even while the daemon idles; refresh it on a slow timer.
    var lastWifiAt = Date.distantPast

    // Main monitor loop — poll every 2s
    while _daemonExitFlag == 0 {
        let iface = getDefaultInterface()
        let ip    = iface.flatMap { getInterfaceIP($0) }

        // 1 = scan + resume auto (legacy GUI), 2 = scan only (refresh, keeps mode)
        let request = takeRescanRequest()
        var mode    = sharedState.mode()

        if request == 1 && mode == "hold" {
            sharedState.setMode("auto")
            mode = "auto"
            daemonLog("Rescan requested — auto mode resumed")
        }

        if let iface = iface, let ip = ip {
            let networkChanged = iface != lastIface || ip != lastIP
            if networkChanged {
                lastIface = iface
                lastIP    = ip
                // Publish interface/IP + joined SSID + neighbours before any scan: a failing
                // scan (no BPF, no gateway) must not leave the header blank.
                publishNetwork(ifname: iface, ourIP: ip)
                lastWifiAt = Date()
                // Never carry a running attack onto a different network: hold and let the
                // user enable cutting again from the TUI/CLI.
                if mode != "hold" {
                    sharedState.setMode("hold")
                    mode = "hold"
                    daemonLog("Network changed — held (enable cutting manually)")
                    stopSpoofing()
                }
            } else if Date().timeIntervalSince(lastWifiAt) >= 30 {
                publishNetwork(ifname: iface, ourIP: ip)
                lastWifiAt = Date()
            }

            switch mode {
            case "hold":
                // Scan-only: publish the device list so the UI has something to show.
                if networkChanged || request != 0 {
                    refreshOnly(ifname: iface, ourIP: ip, reason: networkChanged ? "connect" : "refresh")
                } else if spoofActive {
                    stopSpoofing()
                }

            case "manual":
                let explicit = sharedState.explicit()
                if request != 0 {
                    if !startSpoofing(ifname: iface, ourIP: ip, reason: "refresh", only: explicit.targets) {
                        nextRetry = Date().addingTimeInterval(30)
                    }
                } else if !spoofActive && Date() >= nextRetry {
                    daemonLog("Spoofing inactive — retrying selected targets...")
                    if !startSpoofing(ifname: iface, ourIP: ip, reason: "restart", only: explicit.targets) {
                        nextRetry = Date().addingTimeInterval(30)
                    }
                }

            default:  // auto — only reachable through an explicit resume/scan
                if request != 0 {
                    if !startSpoofing(ifname: iface, ourIP: ip, reason: "refresh") {
                        nextRetry = Date().addingTimeInterval(30)
                    }
                } else if !spoofActive && Date() >= nextRetry {
                    daemonLog("Spoofing inactive — retrying...")
                    if !startSpoofing(ifname: iface, ourIP: ip, reason: "restart") {
                        nextRetry = Date().addingTimeInterval(30)
                    }
                }
            }
        } else if lastIP != nil {
            daemonLog("Network disconnected (\(lastIface ?? "?") \(lastIP ?? "?"))")
            lastIface = nil
            lastIP    = nil
            sharedState.setNetwork(iface: "", ip: "", gateway: "")
            sharedState.setWifi(nil, [])
            if sharedState.mode() != "hold" {
                sharedState.setMode("hold")
                daemonLog("Held — nothing is cut until you enable it again")
            }
            stopSpoofing()
        }

        Thread.sleep(forTimeInterval: 2)
    }

    daemonLog("Shutting down...")
    stopSpoofing(wait: true)
    cleanPidFile()
    daemonLog("Done")
}

// MARK: - Helpers

private func writePid() {
    let pid = "\(ProcessInfo.processInfo.processIdentifier)"
    try? pid.write(toFile: pidFile, atomically: true, encoding: .utf8)
}

private func readPid() -> pid_t? {
    guard let s = try? String(contentsOfFile: pidFile)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
          let n = Int32(s) else { return nil }
    return n
}

private func cleanPidFile() {
    try? FileManager.default.removeItem(atPath: pidFile)
}

func daemonLog(_ msg: String) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let ts = df.string(from: Date())
    let line = "[\(ts)] delucyx: \(msg)\n"
    print(line, terminator: "")
    if let data = line.data(using: .utf8),
       let fh = FileHandle(forWritingAtPath: logFile) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    }
}

@discardableResult
private func runCmd(_ path: String, _ args: [String]) -> Int32 {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: path)
    t.arguments = args
    try? t.run()
    t.waitUntilExit()
    return t.terminationStatus
}

/// Same as `runCmd`, but swallows output — `launchctl print`/`bootstrap` chatter is noise.
@discardableResult
private func runCmdQuiet(_ path: String, _ args: [String]) -> Int32 {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: path)
    t.arguments = args
    t.standardOutput = FileHandle.nullDevice
    t.standardError = FileHandle.nullDevice
    try? t.run()
    t.waitUntilExit()
    return t.terminationStatus
}
