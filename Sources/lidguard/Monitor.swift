import Darwin
import Foundation
import IOKit.ps

// One-line system status (battery, thermal, CPU, memory) without polling helpers.
// Battery, thermal and memory pressure update only when macOS reports a change.
// CPU is sampled by the caller, and only while the window is visible.
// Details (process lists, graphs, history) are left to Activity Monitor.

enum MemoryPressure {
    case normal, warning, critical
}

struct BatteryReading {
    /// nil on Macs without an internal battery.
    let percent: Int?
    let onAC: Bool
}

/// Kernel memory pressure level: 1 normal, 2 warning, 4 critical.
func readMemoryPressure() -> MemoryPressure {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
        return .normal
    }
    switch level {
    case 4: return .critical
    case 2: return .warning
    default: return .normal
    }
}

/// Percent of memory the kernel can hand out right now (the "free percentage"
/// that `memory_pressure` prints). Shown as 여유 % because macOS fills spare RAM
/// with cache, so a "used %" would always look high.
func readMemoryFreePercent() -> Int? {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0,
          (0...100).contains(level) else {
        return nil
    }
    return Int(level)
}

struct CPUTicks {
    let busy: UInt64
    let total: UInt64
}

/// Cached once: every mach_host_self() call adds a port reference.
private let hostPort = mach_host_self()

/// Whole-machine CPU tick counters (user + system + nice vs idle). One mach call.
func readCPUTicks() -> CPUTicks? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let user = UInt64(info.cpu_ticks.0)
    let system = UInt64(info.cpu_ticks.1)
    let idle = UInt64(info.cpu_ticks.2)
    let nice = UInt64(info.cpu_ticks.3)
    let busy = user + system + nice
    return CPUTicks(busy: busy, total: busy + idle)
}

/// Percent busy between two samples, nil if the counters wrapped or did not move.
func cpuPercent(from old: CPUTicks, to new: CPUTicks) -> Int? {
    guard new.total > old.total, new.busy >= old.busy else { return nil }
    let value = Double(new.busy - old.busy) / Double(new.total - old.total) * 100
    return min(100, max(0, Int(value.rounded())))
}

/// IOPS callbacks are C function pointers and cannot capture; route through a global.
private var powerChangeHandler: (() -> Void)?

final class SystemMonitor {
    private(set) var battery = BatteryReading(percent: nil, onAC: true)
    private(set) var thermal: ProcessInfo.ThermalState = .nominal
    private(set) var memory: MemoryPressure = .normal
    private(set) var cpu: Int?
    private(set) var memoryFree: Int?
    /// Called on the main thread after battery, thermal or memory changes.
    var onChange: (() -> Void)?

    private var lastTicks: CPUTicks?
    private var memorySource: DispatchSourceMemoryPressure?
    private var powerSource: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?

    func start() {
        readBattery()
        thermal = ProcessInfo.processInfo.thermalState
        memory = readMemoryPressure()
        memoryFree = readMemoryFreePercent()
        lastTicks = readCPUTicks()

        powerChangeHandler = { [weak self] in
            self?.readBattery()
            self?.onChange?()
        }
        if let source = IOPSNotificationCreateRunLoopSource({ _ in powerChangeHandler?() }, nil)?
            .takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.thermal = ProcessInfo.processInfo.thermalState
            self?.onChange?()
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let event = self.memorySource?.data else { return }
            if event.contains(.critical) {
                self.memory = .critical
            } else if event.contains(.warning) {
                self.memory = .warning
            } else {
                self.memory = .normal
            }
            self.onChange?()
        }
        source.resume()
        memorySource = source
    }

    private func readBattery() {
        battery = BatteryReading(percent: batteryPercent(), onAC: onACPower())
    }

    /// Called once a second while the window is visible: CPU since the previous
    /// sample and the current memory free percentage (one sysctl each).
    func sample() {
        memoryFree = readMemoryFreePercent()
        guard let now = readCPUTicks() else { return }
        if let last = lastTicks, let value = cpuPercent(from: last, to: now) {
            cpu = value
        }
        lastTicks = now
    }

    /// After the window was hidden, start a fresh interval so the next value is current.
    func rebaseCPU() {
        lastTicks = readCPUTicks()
    }
}
