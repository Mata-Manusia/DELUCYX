import Foundation
import Darwin

// Overridable for tests / alternate installs. Default is the real system socket.
let ipcSocketPath = ProcessInfo.processInfo.environment["DELUCYX_SOCKET"] ?? "/var/run/delucyx.sock"

// Protocol version announced in `status`. Clients refuse to drive older daemons.
// 2 → 3 adds the `nearby` Wi-Fi network list.
let ipcProtocolVersion = 3

func startIPCServer() {
    let t = Thread { runIPCServer() }
    t.name = "delucyx-ipc"
    t.start()
}

private func runIPCServer() {
    unlink(ipcSocketPath)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        daemonLog("IPC socket create failed: \(errno)")
        return
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    setSunPath(&addr, ipcSocketPath)

    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        daemonLog("IPC bind failed: \(errno)")
        close(fd); return
    }

    chmod(ipcSocketPath, 0o666)  // allow non-root GUI/TUI to connect
    guard listen(fd, 5) == 0 else {
        daemonLog("IPC listen failed: \(errno)")
        close(fd); return
    }

    daemonLog("IPC socket ready: \(ipcSocketPath) (protocol \(ipcProtocolVersion))")

    while _daemonExitFlag == 0 {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { continue }
        let t = Thread { handleClient(fd: client) }
        t.start()
    }

    close(fd)
    unlink(ipcSocketPath)
}

private func handleClient(fd: Int32) {
    defer { close(fd) }

    var buf = [UInt8](repeating: 0, count: 2048)
    let n = read(fd, &buf, 2047)
    guard n > 0 else { return }

    let msg = String(bytes: buf[0..<n], encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard let data = msg.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cmd  = json["cmd"] as? String else { return }

    var response: [String: Any]

    switch cmd {
    case "status":
        response = statusPayload()

    case "refresh":
        // Rescan only — keep the current mode (TUI refresh).
        _ = OSAtomicCompareAndSwap32(0, 2, &_rescanFlag)
        response = ["ok": true]

    case "scan":
        // Rescan and resume auto mode (legacy GUI semantics).
        _ = OSAtomicCompareAndSwap32(0, 1, &_rescanFlag)
        response = ["ok": true]

    case "start":
        let requested = json["targets"] as? [String] ?? []
        let mode      = (json["mode"] as? String) ?? "cut"
        let forward   = (json["forward"] as? Bool) ?? false

        guard !requested.isEmpty else {
            response = ["error": "no targets"]
            break
        }
        guard mode == "cut" || mode == "mitm" else {
            response = ["error": "invalid mode: \(mode)"]
            break
        }

        let snapshot = sharedState.snapshot()
        let spoofable = Set(snapshot.devices.filter {
            !$0.isGateway && !$0.isSelf &&
            !$0.ip.hasSuffix(".0") && !$0.ip.hasSuffix(".255")
        }.map(\.ip))

        var accepted: [String] = []
        for ip in requested where spoofable.contains(ip) && !accepted.contains(ip) {
            accepted.append(ip)
        }

        guard !accepted.isEmpty else {
            response = ["error": "no targets resolved"]
            break
        }

        sharedState.setExplicit(targets: accepted, mode: mode, forward: forward)
        resetSpooferStop()
        _ = OSAtomicCompareAndSwap32(0, 2, &_rescanFlag)  // act on the next loop tick
        response = ["ok": true, "targets": accepted]

    case "stop":
        sharedState.setMode("hold")
        requestSpooferStop()
        response = ["ok": true]

    case "hold":
        sharedState.setMode("hold")
        requestSpooferStop()
        response = ["ok": true]

    case "resume":
        sharedState.setMode("auto")
        _ = OSAtomicCompareAndSwap32(0, 2, &_rescanFlag)
        response = ["ok": true]

    case "exit":
        _daemonExitFlag = 1
        _stopFlag = 1
        response = ["ok": true]

    default:
        response = ["error": "unknown command: \(cmd)"]
    }

    if let respData = try? JSONSerialization.data(withJSONObject: response),
       let respStr  = String(data: respData, encoding: .utf8) {
        let out = respStr + "\n"
        _ = out.withCString { write(fd, $0, strlen($0)) }
    }
}

private func statusPayload() -> [String: Any] {
    let snap = sharedState.snapshot()
    let activeTargets = Set(snap.targets)

    let devices: [[String: Any]] = snap.devices.map { d in
        [
            "ip":        d.ip,
            "mac":       d.mac,
            "hostname":  d.hostname,
            "isGateway": d.isGateway,
            "isSelf":    d.isSelf,
            "spoofing":  activeTargets.contains(d.ip)
        ]
    }

    let nearby: [[String: Any]] = snap.nearby.map { net in
        [
            "ssid":     net.ssid,
            "channel":  net.channel,
            "band":     net.band,
            "security": net.security,
            "signal":   net.signal,
            "phymode":  net.phymode
        ]
    }

    return [
        "protocol": ipcProtocolVersion,
        "framesSent": Int(DelucyxBPF.framesSent),
        "running":  snap.active,
        "hold":     snap.mode == "hold",
        "manualStop": snap.mode == "hold",  // legacy key read by DelucyxUI
        "mode":     snap.mode,
        "iface":    snap.iface,
        "ip":       snap.ip,
        "gateway":  snap.gateway,
        "ssid":     snap.wifi?.ssid ?? "",
        "ssidChannel": snap.wifi?.channel ?? 0,
        "ssidBand":    snap.wifi?.band ?? "",
        "ssidSignal":  snap.wifi?.signal ?? 0,
        "scanning": snap.scanning,
        "lastScan": Int(snap.lastScan),
        "targets":  snap.targets,
        "devices":  devices,
        "nearby":   nearby
    ]
}

// Client side, used by the CLI subcommands (stop/status/hold/resume).
func sendIPC(_ cmd: [String: Any], timeout: TimeInterval = 5) -> [String: Any]? {
    guard let data = try? JSONSerialization.data(withJSONObject: cmd),
          let msg  = String(data: data, encoding: .utf8) else { return nil }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    setSunPath(&addr, ipcSocketPath)

    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard ok == 0 else { return nil }

    _ = msg.withCString { write(fd, $0, strlen($0)) }

    var buf = [UInt8](repeating: 0, count: 65536)
    var total = 0
    while total < buf.count - 1 {
        let n = read(fd, &buf[total], buf.count - 1 - total)
        if n <= 0 { break }
        total += n
        if buf[total - 1] == UInt8(ascii: "\n") { break }
    }
    guard total > 0,
          let json = try? JSONSerialization.jsonObject(with: Data(buf[0..<total])) as? [String: Any]
    else { return nil }

    return json
}

private func setSunPath(_ addr: inout sockaddr_un, _ path: String) {
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        path.withCString { cstr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) {
                strncpy($0, cstr, 103)
            }
        }
    }
}
