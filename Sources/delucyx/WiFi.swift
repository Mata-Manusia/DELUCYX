import Foundation

/// The network we are joined to, as reported by the radio.
struct WifiCurrent {
    let ssid: String
    let channel: Int
    let band: String
    let signal: Int     // dBm; 0 when unknown
    let phymode: String
}

/// A Wi-Fi network the radio can hear but is not joined to.
struct WifiNetwork {
    let ssid: String
    let channel: Int
    let band: String        // "2.4GHz" | "5GHz" | "6GHz" | ""
    let security: String    // "WPA2" | "WPA3" | "OPEN" | …
    let signal: Int         // dBm (negative); 0 when the radio does not report it
    let phymode: String     // "802.11ac" | …
}

/// Joined network + surrounding networks, both read from `system_profiler`.
struct WifiSurvey {
    let current: WifiCurrent?
    let nearby: [WifiNetwork]

    static let empty = WifiSurvey(current: nil, nearby: [])
}

/// `system_profiler -json SPAirPortDataType` costs ~1 s, so keep one result alive
/// for a short window: the daemon loop, refreshes and rescans all share it.
private let wifiCacheTTL: Double = 15
private let wifiCacheLock = NSLock()
private var wifiCacheAt: Double = 0
private var wifiCacheIface = ""
private var wifiCache: WifiSurvey = .empty

/// Cap on published neighbours — a busy block can hear 50+ APs and the UI is a table.
private let nearbyLimit = 24

func wifiSurvey(ifname: String, force: Bool = false) -> WifiSurvey {
    wifiCacheLock.lock()
    let fresh = !force
        && ifname == wifiCacheIface
        && Date().timeIntervalSince1970 - wifiCacheAt < wifiCacheTTL
    let cached = wifiCache
    wifiCacheLock.unlock()
    if fresh { return cached }

    let survey = readWifiSurvey(ifname: ifname)
    wifiCacheLock.lock()
    wifiCacheIface = ifname
    wifiCacheAt    = Date().timeIntervalSince1970
    wifiCache      = survey
    wifiCacheLock.unlock()
    return survey
}

// Never fatal: a missing/renamed key degrades to "no wifi info".
private func readWifiSurvey(ifname: String) -> WifiSurvey {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    task.arguments = ["-json", "SPAirPortDataType"]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return .empty }
    // Drain before waiting: a full pipe buffer would deadlock the child.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sections = root["SPAirPortDataType"] as? [[String: Any]] else { return .empty }

    var current: WifiCurrent? = nil
    var nearby: [WifiNetwork] = []

    for section in sections {
        let interfaces = section["spairport_airport_interfaces"] as? [[String: Any]] ?? []
        // Prefer the interface we are actually on; fall back to any associated one.
        let match = interfaces.first { $0["_name"] as? String == ifname }
            ?? interfaces.first { ($0["spairport_current_network_information"] as? [String: Any])?["_name"] != nil }
        guard let iface = match else { continue }

        if current == nil, let joined = iface["spairport_current_network_information"] as? [String: Any],
           let joinedSSID = joined["_name"] as? String, !joinedSSID.isEmpty {
            let channel = parseChannel(joined["spairport_network_channel"] as? String ?? "")
            current = WifiCurrent(
                ssid: joinedSSID,
                channel: channel.number,
                band: channel.band,
                signal: parseSignal(joined["spairport_signal_noise"] as? String ?? ""),
                phymode: shortPhymode(joined["spairport_network_phymode"] as? String ?? "")
            )
        }
        let others = iface["spairport_airport_other_local_wireless_networks"] as? [[String: Any]] ?? []
        for other in others {
            guard let ssid = other["_name"] as? String, !ssid.isEmpty else { continue }
            let channel = parseChannel(other["spairport_network_channel"] as? String ?? "")
            nearby.append(WifiNetwork(
                ssid: ssid,
                channel: channel.number,
                band: channel.band,
                security: shortSecurity(other["spairport_security_mode"] as? String ?? ""),
                signal: parseSignal(other["spairport_signal_noise"] as? String ?? ""),
                phymode: shortPhymode(other["spairport_network_phymode"] as? String ?? "")
            ))
        }
    }

    // Sane SSID on two bands is two distinct sightings: collapse per SSID+band, keep the strongest.
    var best: [String: WifiNetwork] = [:]
    for network in nearby where network.ssid != current?.ssid {
        let key = "\(network.ssid)|\(network.band)"
        if let seen = best[key], seen.signal <= network.signal { continue }
        best[key] = network
    }
    let sorted = best.values.sorted { a, b in
        if (a.signal == 0) != (b.signal == 0) { return b.signal == 0 }   // unknown signal last
        if a.signal != b.signal { return a.signal > b.signal }           // strongest (least negative) first
        return a.ssid.localizedStandardCompare(b.ssid) == .orderedAscending
    }
    return WifiSurvey(current: current, nearby: Array(sorted.prefix(nearbyLimit)))
}

/// "153 (5GHz, 20MHz)" → (153, "5GHz").
private func parseChannel(_ raw: String) -> (number: Int, band: String) {
    let number = Int(raw.prefix { $0.isNumber || $0 == "-" }) ?? 0
    guard let open = raw.firstIndex(of: "("), let close = raw.firstIndex(of: ")"), open < close else {
        return (number, "")
    }
    let inside = raw[raw.index(after: open)..<close]
    let band = inside.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    return (number, band == "2GHz" ? "2.4GHz" : band)
}

/// "-61 dBm / -84 dBm" → -61.
private func parseSignal(_ raw: String) -> Int {
    guard let match = raw.split(separator: " ").first, let value = Int(match) else { return 0 }
    return value
}

/// "spairport_security_mode_wpa3_transition" → "WPA2/WPA3".
private func shortSecurity(_ raw: String) -> String {
    let mode = raw.replacingOccurrences(of: "spairport_security_mode_", with: "")
    switch true {
    case mode.contains("wpa3") && mode.contains("transition"): return "WPA2/WPA3"
    case mode.contains("wpa3") && mode.contains("enterprise"): return "WPA3-ENT"
    case mode.contains("wpa3"):                                return "WPA3"
    case mode.contains("wpa2") && mode.contains("enterprise"): return "WPA2-ENT"
    case mode.contains("wpa2"):                                return "WPA2"
    case mode.contains("wpa") && mode.contains("enterprise"):  return "WPA-ENT"
    case mode.contains("wpa"):                                 return "WPA"
    case mode.contains("none"):                                return "OPEN"
    case mode.isEmpty:                                         return "?"
    default:                                                   return mode.uppercased()
    }
}

/// "802.11ac" → "ac" (the column is narrow).
private func shortPhymode(_ raw: String) -> String {
    raw.hasPrefix("802.11") ? String(raw.dropFirst("802.11".count)) : raw
}
