import Foundation
import DelucyxBPF_C

public enum BPFError: LocalizedError {
    case openFailed(String)
    case sendFailed(String)
    case recvFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "BPF open failed: \(msg)"
        case .sendFailed(let msg): return "BPF send failed: \(msg)"
        case .recvFailed(let msg): return "BPF recv failed: \(msg)"
        case .notOpen: return "BPF device not open"
        }
    }
}

public struct BPFPacket {
    public let data: Data
    public let rawLength: Int

    public init(data: Data, rawLength: Int) {
        self.data = data
        self.rawLength = rawLength
    }
}

public final class DelucyxBPF {
    private var ctx: OpaquePointer?

    /// Frames handed to the kernel since launch (all BPF clients, one process).
    private static var framesSentCounter: Int64 = 0

    /// Total transmitted frames — sampled by the daemon for the dashboard charts.
    public static var framesSent: Int64 {
        OSAtomicAdd64(0, &framesSentCounter)
    }

    public var isOpen: Bool { ctx != nil }

    public init(interface: String) throws {
        guard let c = interface.withCString({ delucyx_bpf_open($0) }) else {
            let err = String(cString: delucyx_bpf_error(nil))
            throw BPFError.openFailed(err)
        }
        ctx = c
    }

    deinit {
        close()
    }

    public func send(frame: Data) throws {
        guard let ctx else { throw BPFError.notOpen }
        let count = frame.count
        let result = frame.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> ssize_t in
            guard let base = ptr.baseAddress else { return -1 }
            return delucyx_bpf_send(ctx, base.assumingMemoryBound(to: UInt8.self), count)
        }
        if result == -1 {
            throw BPFError.sendFailed(String(cString: delucyx_bpf_error(ctx)))
        }
        OSAtomicIncrement64(&DelucyxBPF.framesSentCounter)
    }

    public func receive(timeout: TimeInterval) throws -> BPFPacket? {
        guard let ctx else { throw BPFError.notOpen }
        let timeoutMs = Int(timeout * 1000)
        var buf = [UInt8](repeating: 0, count: 65535)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            delucyx_bpf_recv(ctx, ptr.baseAddress, ptr.count, Int32(timeoutMs))
        }
        if n == -1 {
            throw BPFError.recvFailed(String(cString: delucyx_bpf_error(ctx)))
        }
        if n == 0 { return nil }
        return BPFPacket(data: Data(bytes: buf, count: Int(n)), rawLength: Int(n))
    }

    public func close() {
        guard let ctx else { return }
        delucyx_bpf_close(ctx)
        self.ctx = nil
    }
}
