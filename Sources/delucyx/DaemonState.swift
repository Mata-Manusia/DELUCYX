import Foundation

// One device seen by the last scan, exposed to IPC clients (GUI + TUI).
struct DeviceEntry {
    let ip: String
    let mac: String
    let hostname: String
    let isGateway: Bool
    let isSelf: Bool
}

struct DaemonSnapshot {
    let active: Bool
    let mode: String            // "auto" | "manual" | "hold"
    let iface: String
    let ip: String
    let gateway: String
    let wifi: WifiCurrent?      // joined Wi-Fi network; nil on wired interfaces
    let scanning: Bool
    let lastScan: Double
    let targets: [String]
    let devices: [DeviceEntry]
    let nearby: [WifiNetwork]   // Wi-Fi networks heard but not joined
}

// Shared state between daemon loop, IPC server and spoofer threads (thread-safe)
final class DaemonState {
    private let lock = NSLock()

    private var _active        = false
    // "hold" is the safe default: nothing is ever cut until the user enables it
    private var _mode          = "hold"
    private var _iface: String = ""
    private var _ip: String    = ""
    private var _gateway       = ""
    private var _wifi: WifiCurrent? = nil
    private var _scanning      = false
    private var _lastScan: Double = 0
    private var _targets: [String] = []
    private var _devices: [DeviceEntry] = []
    private var _nearby: [WifiNetwork] = []

    // Explicit selection requested through IPC (`start`)
    private var _explicitTargets: [String] = []
    private var _explicitMode    = "cut"
    private var _explicitForward = false

    func setSpoof(active: Bool, targets: [String]) {
        lock.lock(); defer { lock.unlock() }
        _active  = active
        _targets = targets
    }

    func setNetwork(iface: String, ip: String, gateway: String) {
        lock.lock(); defer { lock.unlock() }
        _iface   = iface
        _ip      = ip
        _gateway = gateway
    }

    /// Joined network (nil when unknown/wired) and the neighbours heard with it.
    func setWifi(_ current: WifiCurrent?, _ nearby: [WifiNetwork]) {
        lock.lock(); defer { lock.unlock() }
        _wifi   = current
        _nearby = nearby
    }

    func setScan(devices: [DeviceEntry], lastScan: Double) {
        lock.lock(); defer { lock.unlock() }
        _devices  = devices
        _lastScan = lastScan
    }

    func setScanning(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        _scanning = value
    }

    func mode() -> String {
        lock.lock(); defer { lock.unlock() }
        return _mode
    }

    func setMode(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        _mode = value
    }

    func setExplicit(targets: [String], mode: String, forward: Bool) {
        lock.lock(); defer { lock.unlock() }
        _explicitTargets = targets
        _explicitMode    = mode
        _explicitForward = forward
        _mode            = "manual"
    }

    func explicit() -> (targets: [String], mode: String, forward: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_explicitTargets, _explicitMode, _explicitForward)
    }

    func snapshot() -> DaemonSnapshot {
        lock.lock(); defer { lock.unlock() }
        return DaemonSnapshot(
            active:   _active,
            mode:     _mode,
            iface:    _iface,
            ip:       _ip,
            gateway:  _gateway,
            wifi:     _wifi,
            scanning: _scanning,
            lastScan: _lastScan,
            targets:  _targets,
            devices:  _devices,
            nearby:   _nearby
        )
    }
}

let sharedState = DaemonState()

// Separate exit flag for daemon loop (vs _stopFlag which is for spoof loop only)
var _daemonExitFlag: Int32 = 0

// Rescan request: 0 = none, 1 = scan + resume auto (legacy GUI), 2 = scan only (keep mode)
var _rescanFlag: Int32 = 0

// Take the pending rescan request if any (atomic consume).
func takeRescanRequest() -> Int32 {
    if OSAtomicCompareAndSwap32(1, 0, &_rescanFlag) { return 1 }
    if OSAtomicCompareAndSwap32(2, 0, &_rescanFlag) { return 2 }
    return 0
}
