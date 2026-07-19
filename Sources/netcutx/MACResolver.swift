import Foundation

enum ResolveError: Error, LocalizedError {
    case timeout(String)
    case noReply(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .timeout(let ip): return "Timeout resolving MAC for \(ip)"
        case .noReply(let ip): return "No ARP reply from \(ip)"
        case .invalidResponse: return "Invalid ARP response"
        }
    }
}

func resolveMAC(bpf: NetcutxBPF, ourMAC: MACAddr, ourIP: String, targetIP: String) throws -> MACAddr {
    let req = ARPFrame.buildRequest(srcMAC: ourMAC, srcIP: ourIP, targetIP: targetIP)
    try? bpf.send(frame: Data(req.bytes))

    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        guard let packet = try? bpf.receive(timeout: 0.5) else { continue }
        guard let frame = ARPFrame(from: packet.data) else { continue }
        if frame.isReply, let sip = frame.senderIP, sip == targetIP, let mac = frame.senderMAC {
            return mac
        }
    }
    throw ResolveError.timeout(targetIP)
}

func getGatewayIP() -> String? {
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
        if trimmed.hasPrefix("gateway:") {
            let ip = trimmed.components(separatedBy: " ").last?.trimmingCharacters(in: .whitespaces)
            if let ip = ip, !ip.isEmpty {
                var addr = in_addr()
                if inet_pton(AF_INET, ip, &addr) == 1 {
                    return ip
                }
            }
        }
    }
    return nil
}

func getInterfaceIP(_ ifname: String) -> String? {
    var addr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addr) == 0, let start = addr else { return nil }
    defer { freeifaddrs(start) }
    var ptr = start
    while true {
        let info = ptr.pointee
        if let name = info.ifa_name, String(cString: name) == ifname {
            let family = info.ifa_addr.pointee.sa_family
            if family == AF_INET {
                let sin = info.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var sin_addr = sin.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buf)
            }
        }
        guard let next = info.ifa_next else { break }
        ptr = next
    }
    return nil
}

func getInterfaceNetmask(_ ifname: String) -> String? {
    var addr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addr) == 0, let start = addr else { return nil }
    defer { freeifaddrs(start) }
    var ptr = start
    while true {
        let info = ptr.pointee
        if let name = info.ifa_name, String(cString: name) == ifname {
            let family = info.ifa_addr.pointee.sa_family
            if family == AF_INET {
                let netmask = info.ifa_netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var mask = netmask.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &mask, &buf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buf)
            }
        }
        guard let next = info.ifa_next else { break }
        ptr = next
    }
    return nil
}

func getCIDRPrefix(_ netmask: String) -> Int {
    guard let bytes = ipToBytes(netmask) else { return 24 }
    var count = 0
    for byte in bytes {
        count += byte.nonzeroBitCount
    }
    return count
}

func getNetworkAddress(_ ip: String, _ netmask: String) -> String? {
    guard let ipBytes = ipToBytes(ip), let maskBytes = ipToBytes(netmask) else { return nil }
    let net = zip(ipBytes, maskBytes).map { $0 & $1 }
    return bytesToIP(net)
}

func getBroadcastAddress(_ ip: String, _ netmask: String) -> String? {
    guard let ipBytes = ipToBytes(ip), let maskBytes = ipToBytes(netmask) else { return nil }
    let wildcard = maskBytes.map { ~$0 & 0xFF }
    let bcast = zip(ipBytes, wildcard).map { $0 | $1 }
    return bytesToIP(bcast)
}
