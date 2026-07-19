import Foundation
import Darwin

let scanPorts = [21,22,23,25,53,80,110,143,443,445,993,995,1433,1521,2049,3306,3389,5432,5900,6379,8080,8443,9000,9090,27017]

func computeChecksum(_ data: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0; var i = 0
    while i < data.count - 1 { sum += UInt32(UInt16(data[i]) << 8 | UInt16(data[i+1])); i += 2 }
    if i < data.count { sum += UInt32(UInt16(data[i]) << 8) }
    while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
    return ~UInt16(truncatingIfNeeded: sum)
}

func buildTCPSYN(ourMAC: MACAddr, theirMAC: MACAddr, ourIP: String, theirIP: String,
                 srcPort: UInt16, dstPort: UInt16) -> [UInt8]? {
    guard let srcB = ipToBytes(ourIP), let dstB = ipToBytes(theirIP) else { return nil }
    let seq = UInt32.random(in: 0...UInt32.max)
    var ip = [UInt8](repeating: 0, count: 20)
    ip[0] = 0x45; ip[2] = 0; ip[3] = 40; ip[4] = UInt8.random(in: 0...255); ip[5] = UInt8.random(in: 0...255)
    ip[6] = 0x40; ip[7] = 0; ip[8] = 64; ip[9] = 6
    ip[12] = srcB[0]; ip[13] = srcB[1]; ip[14] = srcB[2]; ip[15] = srcB[3]
    ip[16] = dstB[0]; ip[17] = dstB[1]; ip[18] = dstB[2]; ip[19] = dstB[3]
    let ipCS = computeChecksum(ip); ip[10] = UInt8(ipCS >> 8); ip[11] = UInt8(ipCS & 0xFF)

    var tcp = [UInt8](repeating: 0, count: 20)
    tcp[0] = UInt8(srcPort >> 8); tcp[1] = UInt8(srcPort & 0xFF)
    tcp[2] = UInt8(dstPort >> 8); tcp[3] = UInt8(dstPort & 0xFF)
    tcp[4] = UInt8((seq >> 24) & 0xFF); tcp[5] = UInt8((seq >> 16) & 0xFF)
    tcp[6] = UInt8((seq >> 8) & 0xFF); tcp[7] = UInt8(seq & 0xFF)
    tcp[12] = 0x50; tcp[13] = 0x02; tcp[14] = 0xFF; tcp[15] = 0xFF

    var pseudo = [UInt8]()
    pseudo.append(contentsOf: srcB); pseudo.append(contentsOf: dstB)
    pseudo.append(0); pseudo.append(6); pseudo.append(0); pseudo.append(20)
    pseudo.append(contentsOf: tcp)
    let tcpCS = computeChecksum(pseudo); tcp[16] = UInt8(tcpCS >> 8); tcp[17] = UInt8(tcpCS & 0xFF)

    var frame = [UInt8]()
    frame.append(contentsOf: macToBytes(theirMAC))
    frame.append(contentsOf: macToBytes(ourMAC))
    frame.append(0x08); frame.append(0x00)
    frame.append(contentsOf: ip); frame.append(contentsOf: tcp)
    return frame
}

func synScan(bpf: NetcutxBPF, ourMAC: MACAddr, theirMAC: MACAddr, ourIP: String, theirIP: String,
             ports: [Int] = scanPorts, delay: ClosedRange<Double> = 0.05...0.2) -> (open: [Int], ttl: UInt8) {
    var open: [Int] = []
    var observedTTL: UInt8 = 0
    let srcPort = UInt16.random(in: 10000...60000)

    // Send all SYN probes with randomized delay
    for port in ports.shuffled() {
        guard let frame = buildTCPSYN(ourMAC: ourMAC, theirMAC: theirMAC, ourIP: ourIP,
                                       theirIP: theirIP, srcPort: srcPort, dstPort: UInt16(port))
        else { continue }
        try? bpf.send(frame: Data(frame))
        usleep(UInt32(Double.random(in: delay) * 1_000_000))
    }

    // Collect SYN-ACK responses
    let deadline = Date().addingTimeInterval(3)
    var rcvTotal = 0, rcvIP = 0, rcvTCP = 0, rcvFromTarget = 0
    while Date() < deadline {
        guard let pkt = try? bpf.receive(timeout: 0.2) else { continue }
        rcvTotal += 1
        guard pkt.data.count >= 54 else { continue }
        let ethType = (UInt16(pkt.data[12]) << 8) | UInt16(pkt.data[13])
        guard ethType == 0x0800 else { continue }
        rcvIP += 1
        let ipHL = Int(pkt.data[14] & 0x0F) * 4
        guard ipHL >= 20, pkt.data.count >= 14 + ipHL + 20 else { continue }
        let proto = pkt.data[23]
        guard proto == 6 else { continue }
        rcvTCP += 1
        let srcIP = "\(pkt.data[26]).\(pkt.data[27]).\(pkt.data[28]).\(pkt.data[29])"
        guard srcIP == theirIP else { continue }
        rcvFromTarget += 1
        let tcpStart = 14 + ipHL
        let dport = (UInt16(pkt.data[tcpStart]) << 8) | UInt16(pkt.data[tcpStart + 1])
        guard dport == srcPort else { continue }
        let flags = pkt.data[tcpStart + 13]
        if flags & 0x12 == 0x12 { // SYN-ACK
            let sport = (UInt16(pkt.data[tcpStart + 2]) << 8) | UInt16(pkt.data[tcpStart + 3])
            open.append(Int(sport))
        }
        if observedTTL == 0 { observedTTL = pkt.data[22] }
    }
    if open.isEmpty { fputs("  dbg: \(theirIP) rx \(rcvTotal) pkts (\(rcvIP) IP, \(rcvTCP) TCP, \(rcvFromTarget) from target)\n", stderr) }
    return (open.sorted(), observedTTL)
}

func probeService(_ ip: String, _ port: Int, timeout: TimeInterval = 3) -> String {
    let hint = serviceHint(port)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = CFSwapInt16HostToBig(UInt16(port))
    inet_pton(AF_INET, ip, &addr.sin_addr)

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return hint }
    defer { close(fd) }

    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var sa = addr
    let rc = withUnsafePointer(to: &sa) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard rc == 0 else { return hint }

    var banner = ""
    var buf = [UInt8](repeating: 0, count: 1024)
    // Send probe for HTTP
    if port == 80 || port == 8080 {
        let req = "GET / HTTP/1.0\r\nHost: \(ip)\r\n\r\n"
        _ = req.withCString { write(fd, $0, strlen($0)) }
    }
    let n = read(fd, &buf, 1024)
    if n > 0 {
        let raw = String(bytes: buf[..<min(n, 200)], encoding: .utf8) ?? ""
        banner = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: " | ")
            .prefix(100).description
    }
    return banner.isEmpty ? hint : "\(hint): \(banner)"
}

func serviceHint(_ port: Int) -> String {
    switch port {
    case 21: return "FTP"; case 22: return "SSH"; case 23: return "Telnet"
    case 25: return "SMTP"; case 53: return "DNS"; case 80: return "HTTP"
    case 110: return "POP3"; case 143: return "IMAP"; case 443: return "HTTPS"
    case 445: return "SMB"; case 993: return "IMAPS"; case 995: return "POP3S"
    case 1433: return "MSSQL"; case 1521: return "Oracle"; case 2049: return "NFS"
    case 3306: return "MySQL"; case 3389: return "RDP"; case 5432: return "PostgreSQL"
    case 5900: return "VNC"; case 6379: return "Redis"; case 8080: return "HTTP-Alt"
    case 8443: return "HTTPS-Alt"; case 9000: return "Port-9000"; case 9090: return "Port-9090"
    case 27017: return "MongoDB"; default: return "Port-\(port)"
    }
}

// HTTP default creds check
let httpCreds: [(user: String, pass: String)] = [
    ("admin","admin"), ("admin","password"), ("admin","1234"), ("admin","12345"),
    ("admin","123456"), ("admin","root"), ("root","root"), ("root","toor"),
    ("root","admin"), ("admin",""), ("admin","manager"), ("admin","pass"),
    ("user","user"), ("user","password"), ("guest","guest"),
]

func tryHTTPDefaultCreds(_ ip: String, port: Int = 80, path: String = "/") -> (user: String, pass: String)? {
    for cred in httpCreds {
        let login = "\(cred.user):\(cred.pass)"
        guard let data = "\(login)".data(using: .utf8)?.base64EncodedString() else { continue }
        let auth = "Authorization: Basic \(data)\r\n"
        let req = "GET \(path) HTTP/1.0\r\nHost: \(ip)\r\n\(auth)\r\n"
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(UInt16(port))
        inet_pton(AF_INET, ip, &addr.sin_addr)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { continue }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var sa = addr
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { continue }
        _ = req.withCString { write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buf, 512)
        if n > 0 {
            let resp = String(bytes: buf[..<min(n, 200)], encoding: .utf8) ?? ""
            if !resp.contains("401") && !resp.contains("Unauthorized") && (resp.contains("200") || resp.contains("302") || resp.contains("Location")) {
                return (cred.user, cred.pass)
            }
        }
        usleep(100_000)
    }
    return nil
}

func trySSHDefaultCreds(_ ip: String, port: Int = 22) -> (user: String, pass: String)? {
    // ponytail: minimal SSH check — just check if port responds
    // Real SSH brute-force needs libssh2 or expect. Skip for now.
    return nil
}
