import Foundation

typealias MACAddr = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

let broadcastMAC: MACAddr = (0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
let etherTypeARP: UInt16 = 0x0806
let arpRequest: UInt16 = 0x0001
let arpReply: UInt16 = 0x0002
let arpHWTypeEther: UInt16 = 0x0001
let arpProtoTypeIP: UInt16 = 0x0800

func macToString(_ mac: MACAddr) -> String {
    String(format: "%02x:%02x:%02x:%02x:%02x:%02x", mac.0, mac.1, mac.2, mac.3, mac.4, mac.5)
}

func stringToMAC(_ s: String) -> MACAddr? {
    let parts = s.split(separator: ":").map { UInt8($0, radix: 16) }
    guard parts.count == 6, let a = parts[0], let b = parts[1],
          let c = parts[2], let d = parts[3], let e = parts[4], let f = parts[5] else {
        return nil
    }
    return (a, b, c, d, e, f)
}

func macToBytes(_ mac: MACAddr) -> [UInt8] {
    [mac.0, mac.1, mac.2, mac.3, mac.4, mac.5]
}

func ipToBytes(_ ip: String) -> [UInt8]? {
    let parts = ip.split(separator: ".").map { UInt8($0) }
    guard parts.count == 4, let a = parts[0], let b = parts[1],
          let c = parts[2], let d = parts[3] else { return nil }
    return [a, b, c, d]
}

func bytesToIP(_ bytes: [UInt8]) -> String? {
    guard bytes.count == 4 else { return nil }
    return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
}

func isAllZeroMAC(_ mac: MACAddr) -> Bool {
    mac.0 == 0 && mac.1 == 0 && mac.2 == 0 && mac.3 == 0 && mac.4 == 0 && mac.5 == 0
}

func getMACFromARPTable(_ ip: String) -> MACAddr? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
    task.arguments = ["-a"]
    let out = Pipe()
    task.standardOutput = out
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    for line in output.components(separatedBy: "\n") {
        guard line.contains("(\(ip))") else { continue }
        let parts = line.split(separator: " ").map(String.init)
        let macStr = parts.first { $0.contains(":") && $0.count == 17 }
        if let m = macStr { return stringToMAC(m) }
    }
    return nil
}
