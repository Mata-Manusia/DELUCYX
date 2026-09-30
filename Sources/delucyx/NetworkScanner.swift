import Foundation

struct ScanResult {
    let devices: [DeviceInfo]
}

func scanNetwork(bpf: DelucyxBPF, ourMAC: MACAddr, ourIP: String, gatewayIP: String, ifname: String? = nil, deep: Bool = false) throws -> ScanResult {
    let netmask = ifname.flatMap { getInterfaceNetmask($0) } ?? "255.255.255.0"
    let prefix = getCIDRPrefix(netmask)
    let networkAddr = getNetworkAddress(ourIP, netmask) ?? ""
    let broadcastAddr = getBroadcastAddress(ourIP, netmask) ?? ""
    let networkParts = networkAddr.split(separator: ".")
    let broadcastParts = broadcastAddr.split(separator: ".")

    var ipsToScan: [String] = []
    guard networkParts.count == 4, broadcastParts.count == 4 else {
        return ScanResult(devices: [])
    }

    let firstOctet = Int(networkParts[3]) ?? 0
    let lastOctet = Int(broadcastParts[3]) ?? 255

    if prefix >= 24 {
        let netBase = "\(networkParts[0]).\(networkParts[1]).\(networkParts[2])"
        let start = firstOctet + 1
        let end = lastOctet - 1
        for i in max(start, 1)...min(end, 254) {
            ipsToScan.append("\(netBase).\(i)")
        }
    } else {
        for i in firstOctet + 1..<lastOctet {
            ipsToScan.append("\(networkParts[0]).\(networkParts[1]).\(networkParts[2]).\(i)")
        }
    }

    let rounds = deep ? 3 : 1
    let interRoundDelay: TimeInterval = deep ? 0.5 : 0

    status("Deep scan \(deep ? "ON" : "OFF") — \(rounds)x burst, \(ipsToScan.count) hosts")
    for round in 1...rounds {
        if round > 1 { Thread.sleep(forTimeInterval: interRoundDelay) }
        for ip in ipsToScan {
            if isSelfIP(ip, ourIP) { continue }
            let req = ARPFrame.buildRequest(srcMAC: ourMAC, srcIP: ourIP, targetIP: ip)
            try? bpf.send(frame: Data(req.bytes))
        }
    }

    let waitTime: TimeInterval = deep ? 12.0 : (ipsToScan.count > 100 ? 5.0 : ipsToScan.count > 50 ? 4.0 : 3.0)
    status("Menunggu reply \(Int(waitTime))s...")
    Thread.sleep(forTimeInterval: waitTime)

    var seen = Set<String>()
    var devices: [DeviceInfo] = []

    let startIP = ourIP
    let gw = gatewayIP

    if deep {
        Thread.sleep(forTimeInterval: 3)
        for ip in ipsToScan {
            if isSelfIP(ip, ourIP) { continue }
            let req = ARPFrame.buildRequest(srcMAC: ourMAC, srcIP: ourIP, targetIP: ip)
            try? bpf.send(frame: Data(req.bytes))
        }
    }

    for _ in 0..<(deep ? 50 : 20) {
        guard let packet = try bpf.receive(timeout: deep ? 0.3 : 0.1) else { break }
        guard let frame = ARPFrame(from: packet.data) else { continue }
        guard frame.isReply, let sip = frame.senderIP, let smac = frame.senderMAC else { continue }
        guard !seen.contains(sip) else { continue }
        guard !isSelfIP(sip, startIP) else { continue }

        seen.insert(sip)
        let hostname = resolveHostname(sip)
        devices.append(DeviceInfo(
            ip: sip,
            mac: macToString(smac),
            hostname: hostname,
            isGateway: sip == gw,
            isSelf: false
        ))
    }

    devices.sort { d1, d2 in
        if d1.isGateway { return true }
        if d2.isGateway { return false }
        return d1.ip.localizedStandardCompare(d2.ip) == .orderedAscending
    }

    return ScanResult(devices: devices)
}

func quickScanARPTable(gatewayIP: String, ourIP: String) -> [DeviceInfo] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
    task.arguments = ["-a"]
    let out = Pipe()
    task.standardOutput = out
    guard (try? task.run()) != nil else { return [] }
    task.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    var devices: [DeviceInfo] = []
    var seen = Set<String>()

    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("?") || trimmed.first?.isLetter == true else { continue }

        let parts = trimmed.split(separator: " ").map(String.init)
        guard parts.count >= 4 else { continue }

        var ip = ""

        if trimmed.contains("(") {
            if let ipStart = trimmed.firstIndex(of: "("),
               let ipEnd = trimmed.firstIndex(of: ")") {
                ip = String(trimmed[trimmed.index(after: ipStart)..<ipEnd])
            }
        } else {
            ip = parts[1]
        }

        // `arp -a` prints octets unpadded ("d8:9a:d:5b:1e:e4"), so a fixed-width token check
        // would silently drop those hosts; normalize through the shared parser instead.
        guard let unicast = parts.first(where: { $0.contains(":") }).flatMap(stringToMAC),
              unicast.0 & 0x01 == 0 else { continue }   // ignore group/multicast MACs
        // The cache also holds multicast rows (mDNS 224.0.0.251); only unicast LAN hosts count.
        guard let octets = ipToBytes(ip), (1...223).contains(octets[0]) else { continue }

        let mac = macToString(unicast)
        guard !seen.contains(ip), !isSelfIP(ip, ourIP) else { continue }

        seen.insert(ip)
        devices.append(DeviceInfo(
            ip: ip, mac: mac, hostname: "",
            isGateway: ip == gatewayIP, isSelf: false
        ))
    }

    return devices.sorted { d1, d2 in
        if d1.isGateway { return true }
        if d2.isGateway { return false }
        return d1.ip.localizedStandardCompare(d2.ip) == .orderedAscending
    }
}

private func isSelfIP(_ ip: String, _ ourIP: String) -> Bool {
    ip == ourIP
}

func resolveHostname(_ ip: String) -> String {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    var addr = in_addr()
    inet_pton(AF_INET, ip, &addr)
    let sa = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                          sin_family: sa_family_t(AF_INET),
                          sin_port: 0, sin_addr: addr,
                          sin_zero: (0,0,0,0,0,0,0,0))
    let result = withUnsafePointer(to: sa) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                       &host, socklen_t(NI_MAXHOST),
                       nil, 0, NI_NAMEREQD)
        }
    }
    if result == 0 {
        return String(cString: host)
    }
    return ""
}
