import Foundation

enum Color: String {
    case reset   = "\u{001B}[0m"
    case red     = "\u{001B}[31m"
    case green   = "\u{001B}[32m"
    case yellow  = "\u{001B}[33m"
    case blue    = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan    = "\u{001B}[36m"
    case white   = "\u{001B}[37m"
    case bold    = "\u{001B}[1m"
    case dim     = "\u{001B}[2m"
}

func c(_ color: Color, _ text: String) -> String {
    "\(color.rawValue)\(text)\(Color.reset.rawValue)"
}

struct DeviceInfo {
    let ip: String
    let mac: String
    let hostname: String
    let isGateway: Bool
    let isSelf: Bool
}

func showBanner() {
    print("")
    print(c(.cyan, "  ╔══════════════════════════════════╗"))
    print(c(.cyan, "  ║ ") + c(.bold, "   d e l u c y x") + String(repeating: " ", count: 17) + c(.cyan, "║"))
    print(c(.cyan, "  ║ ") + c(.dim, "   LAN Access Control Tool") + String(repeating: " ", count: 7) + c(.cyan, "║"))
    print(c(.cyan, "  ╚══════════════════════════════════╝"))
    print("")
}

func selectInterface() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
    task.arguments = ["-l"]
    let out = Pipe()
    task.standardOutput = out
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    let interfaces = output.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ")
        .filter { name in
            let s = String(name)
            guard let ip = getInterfaceIP(s) else { return false }
            return !ip.isEmpty && getInterfaceMAC(s) != nil
        }

    var candidates: [(name: String, ip: String, mac: String)] = []
    for iface in interfaces {
        let name = String(iface)
        guard let mac = getInterfaceMAC(name) else { continue }
        let ip = getInterfaceIP(name) ?? "-"
        if ip != "-" {
            candidates.append((name, ip, macToString(mac)))
        }
    }

    if candidates.isEmpty {
        print(c(.red, "  ✗ Tidak ada interface aktif"))
        return nil
    }

    print(c(.bold, "  Interface tersedia:"))
    print("")
    for (i, iface) in candidates.enumerated() {
        let tag = c(.green, "  [\(i+1)]")
        let name = c(.bold, iface.name)
        let ip = c(.cyan, iface.ip)
        print("\(tag) \(name)  \(ip)  \(iface.mac)")
    }
    print("")
    print(c(.dim, "  Pilih [1-\(candidates.count)]"), terminator: " ")

    guard let input = readLine(), let n = Int(input), n >= 1, n <= candidates.count else {
        print(c(.red, "  ✗ Pilihan tidak valid"))
        return nil
    }
    return candidates[n-1].name
}

func showDeviceTable(_ devices: [DeviceInfo]) -> Int? {
    guard let indices = showDeviceTableMulti(devices) else { return nil }
    return indices.first
}

func showDeviceTableMulti(_ devices: [DeviceInfo]) -> [Int]? {
    if devices.isEmpty {
        print(c(.yellow, "  ⚠ Tidak ada device terdeteksi"))
        return nil
    }

    print("")
    print(c(.bold, "  Device di jaringan:"))
    print("")
    print("  \(pad("#", 3)) \(pad("IP", 16)) \(pad("MAC", 18)) \(pad("Hostname", 20))")
    print("  \(String(repeating: "─", count: 60))")

    for (i, d) in devices.enumerated() {
        let num = "\(i+1)"
        let tag = d.isSelf ? c(.dim, "  [\(num)]") : c(.green, "  [\(num)]")
        let ip = d.isGateway ? c(.yellow, pad(d.ip, 16)) : pad(d.ip, 16)
        let mac = pad(d.mac, 18)
        let host = d.hostname != "" ? pad(d.hostname, 20) : pad("-", 20)
        let note = d.isGateway ? c(.yellow, " ← gateway") : (d.isSelf ? c(.dim, " ← kamu") : "")
        print("\(tag) \(ip) \(mac) \(host) \(note)")
    }
    print("")
    print(c(.dim, "  Pilih target [1-\(devices.count)] / pisah koma (mis: 3,4,5) / \"all\""), terminator: " ")

    guard let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty else {
        print(c(.red, "  ✗ Pilihan tidak valid"))
        return nil
    }

    let allIndices = devices.indices.filter { !devices[$0].isGateway && !devices[$0].isSelf }

    if input.lowercased() == "all" {
        if allIndices.isEmpty {
            print(c(.red, "  ✗ Tidak ada target valid"))
            return nil
        }
        return allIndices
    }

    let parts = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    var indices: [Int] = []
    for part in parts {
        guard let n = Int(part), n >= 1, n <= devices.count else {
            print(c(.red, "  ✗ Pilihan tidak valid: \(part)"))
            return nil
        }
        indices.append(n - 1)
    }

    var seen = Set<Int>()
    let unique = indices.filter { seen.insert($0).inserted }
    return unique.isEmpty ? nil : unique
}

func confirmAction(config: SpooferConfig) -> Bool {
    return confirmActionMulti(configs: [config])
}

func confirmActionMulti(configs: [SpooferConfig]) -> Bool {
    guard let first = configs.first else { return false }
    print("")
    print(c(.bold, "  Ringkasan:"))
    print("  ─────────────────────────────")
    print("  Interface : \(first.interface)")
    if configs.count == 1 {
        print("  Target    : \(first.victimIP) (\(macToString(first.victimMAC)))")
    } else {
        print("  Target    : \(configs.count) device")
        for cfg in configs {
            print("              \(pad(cfg.victimIP, 16)) \(macToString(cfg.victimMAC))")
        }
    }
    print("  Gateway   : \(first.gatewayIP) (\(macToString(first.gatewayMAC)))")
    print("  Mode      : \(first.bidirectional ? "MITM penuh" : "Potong koneksi")")
    print("  AP Poison : ya (gateway ARP cache)")
    let intervalStr = first.interval >= 1 ? "\(Int(first.interval))" : "\(first.interval)"
    print("  Interval  : \(intervalStr) detik")
    print("")
    print(c(.yellow, "  ⚠ PERINGATAN: Device target akan kehilangan akses jaringan!"))
    print(c(.dim, "  Mulai serangan? [y/N]"), terminator: " ")

    guard let input = readLine()?.lowercased() else { return false }
    return input == "y" || input == "yes"
}

func pad(_ s: String, _ n: Int) -> String {
    if s.count >= n { return String(s.prefix(n)) }
    return s + String(repeating: " ", count: n - s.count)
}

func status(_ msg: String) {
    print("  \(c(.blue, "▸")) \(msg)")
}

func ok(_ msg: String) {
    print("  \(c(.green, "✓")) \(msg)")
}

func fail(_ msg: String) {
    print("  \(c(.red, "✗")) \(msg)")
}

func warn(_ msg: String) {
    print("  \(c(.yellow, "⚠")) \(msg)")
}
