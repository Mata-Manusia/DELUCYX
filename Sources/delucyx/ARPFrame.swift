import Foundation

struct ARPFrame {
    let ethernetHeader: [UInt8]
    let arpPayload: [UInt8]

    var bytes: [UInt8] { ethernetHeader + arpPayload }
    static let totalSize = 42

    init(ethernetHeader: [UInt8], arpPayload: [UInt8]) {
        self.ethernetHeader = ethernetHeader
        self.arpPayload = arpPayload
    }

    init?(from data: Data) {
        guard data.count >= ARPFrame.totalSize else { return nil }
        self.init(
            ethernetHeader: [UInt8](data[0..<14]),
            arpPayload: [UInt8](data[14..<42])
        )
    }

    static func buildRequest(
        srcMAC: MACAddr, srcIP: String, targetIP: String
    ) -> ARPFrame {
        let eth = buildEthernetHeader(dstMAC: broadcastMAC, srcMAC: srcMAC, etherType: etherTypeARP)
        let sip = ipToBytes(srcIP)!
        let tip = ipToBytes(targetIP)!
        let arp = buildARPPayload(
            op: arpRequest,
            senderMAC: srcMAC, senderIP: sip,
            targetMAC: (0, 0, 0, 0, 0, 0), targetIP: tip
        )
        return ARPFrame(ethernetHeader: eth, arpPayload: arp)
    }

    static func buildReply(
        srcMAC: MACAddr, srcIP: String,
        dstMAC: MACAddr, dstIP: String
    ) -> ARPFrame {
        let eth = buildEthernetHeader(dstMAC: dstMAC, srcMAC: srcMAC, etherType: etherTypeARP)
        let sip = ipToBytes(srcIP)!
        let dip = ipToBytes(dstIP)!
        let arp = buildARPPayload(
            op: arpReply,
            senderMAC: srcMAC, senderIP: sip,
            targetMAC: dstMAC, targetIP: dip
        )
        return ARPFrame(ethernetHeader: eth, arpPayload: arp)
    }

    static func buildAPPoison(
        srcMAC: MACAddr, srcIP: String,
        targetMAC: MACAddr, targetIP: String
    ) -> ARPFrame {
        let eth = buildEthernetHeader(dstMAC: targetMAC, srcMAC: srcMAC, etherType: etherTypeARP)
        let sip = ipToBytes(srcIP)!
        let tip = ipToBytes(targetIP)!
        let arp = buildARPPayload(
            op: arpReply,
            senderMAC: srcMAC, senderIP: sip,
            targetMAC: targetMAC, targetIP: tip
        )
        return ARPFrame(ethernetHeader: eth, arpPayload: arp)
    }

    static func buildBroadcastSpoof(
        srcMAC: MACAddr, srcIP: String,
        victimMAC: MACAddr, victimIP: String
    ) -> ARPFrame {
        let eth = buildEthernetHeader(dstMAC: broadcastMAC, srcMAC: srcMAC, etherType: etherTypeARP)
        let sip = ipToBytes(srcIP)!
        let vip = ipToBytes(victimIP)!
        let arp = buildARPPayload(
            op: arpReply,
            senderMAC: srcMAC, senderIP: sip,
            targetMAC: victimMAC, targetIP: vip
        )
        return ARPFrame(ethernetHeader: eth, arpPayload: arp)
    }

    var senderIP: String? {
        let bytes = Array(arpPayload[14..<18])
        return bytesToIP(bytes)
    }

    var senderMAC: MACAddr? {
        guard arpPayload.count >= 20 else { return nil }
        return (arpPayload[8], arpPayload[9], arpPayload[10],
                arpPayload[11], arpPayload[12], arpPayload[13])
    }

    var targetIP: String? {
        let bytes = Array(arpPayload[24..<28])
        return bytesToIP(bytes)
    }

    var isReply: Bool {
        arpPayload[6] == 0x00 && arpPayload[7] == 0x02
    }

    var isRequest: Bool {
        arpPayload[6] == 0x00 && arpPayload[7] == 0x01
    }
}

private func buildEthernetHeader(dstMAC: MACAddr, srcMAC: MACAddr, etherType: UInt16) -> [UInt8] {
    macToBytes(dstMAC) + macToBytes(srcMAC) + [UInt8(etherType >> 8), UInt8(etherType & 0xFF)]
}

private func buildARPPayload(
    op: UInt16,
    senderMAC: MACAddr, senderIP: [UInt8],
    targetMAC: MACAddr, targetIP: [UInt8]
) -> [UInt8] {
    var buf = [UInt8]()
    buf.append(contentsOf: [0x00, 0x01]) // hw type: ethernet
    buf.append(contentsOf: [0x08, 0x00]) // proto type: IPv4
    buf.append(6)   // hw addr len
    buf.append(4)   // proto addr len
    buf.append(contentsOf: [UInt8(op >> 8), UInt8(op & 0xFF)])
    buf.append(contentsOf: macToBytes(senderMAC))
    buf.append(contentsOf: senderIP)
    buf.append(contentsOf: macToBytes(targetMAC))
    buf.append(contentsOf: targetIP)
    return buf
}
