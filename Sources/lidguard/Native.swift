import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// Native replacements for the old per-second `bash -lc` probes.
// Reading IOPMrootDomain and calling kill(2) costs microseconds and spawns nothing.

enum LidState: String {
    case open, closed, unknown
}

/// Test hooks are honoured only for non-root processes, so a root watchdog
/// can never be redirected by its environment.
func testOverride(_ key: String) -> String? {
    guard getuid() != 0, let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
        return nil
    }
    return value
}

private var rootDomainService: io_service_t = 0

private func rootDomain() -> io_service_t {
    if rootDomainService == 0 {
        rootDomainService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    }
    return rootDomainService
}

func rootDomainBool(_ key: String) -> Bool? {
    let service = rootDomain()
    guard service != 0,
          let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else {
        return nil
    }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return CFBooleanGetValue((value as! CFBoolean))
    }
    return (value as? NSNumber)?.boolValue
}

func readLidState() -> LidState {
    if let fake = testOverride("LIDGUARD_FAKE_CLAMSHELL") {
        switch fake.lowercased() {
        case "yes", "closed": return .closed
        case "no", "open": return .open
        default: return .unknown
        }
    }
    guard let closed = rootDomainBool("AppleClamshellState") else { return .unknown }
    return closed ? .closed : .open
}

/// True for serious/critical thermal pressure. Replaces `pmset -g therm` polling.
func thermalSerious() -> Bool {
    if let fake = testOverride("LIDGUARD_FAKE_THERMAL") {
        return fake == "serious" || fake == "critical"
    }
    let state = ProcessInfo.processInfo.thermalState
    return state == .serious || state == .critical
}

func thermalLabel() -> String {
    if let fake = testOverride("LIDGUARD_FAKE_THERMAL") { return fake }
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

/// True on the power adapter. Desktops always report AC. Unknown counts as AC.
/// Test hook: LIDGUARD_FAKE_POWER=ac|battery, or LIDGUARD_FAKE_POWER_FILE whose
/// content can change while a test runs.
func onACPower() -> Bool {
    if let path = testOverride("LIDGUARD_FAKE_POWER_FILE") {
        let value = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "ac"
        return value != "battery"
    }
    if let fake = testOverride("LIDGUARD_FAKE_POWER") {
        return fake != "battery"
    }
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
        return true
    }
    return (type as String) != "Battery Power"
}

/// Below this, on battery, every keep-awake mode ends (fixed at 5%).
let lowBatteryPercent = 5

/// Internal battery charge in percent, nil on Macs without a battery.
/// Test hook: LIDGUARD_FAKE_BATTERY_PERCENT.
func batteryPercent() -> Int? {
    if let fake = testOverride("LIDGUARD_FAKE_BATTERY_PERCENT") {
        return Int(fake)
    }
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
        return nil
    }
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              (desc["Type"] as? String) == "InternalBattery",
              let current = desc["Current Capacity"] as? Int,
              let maximum = desc["Max Capacity"] as? Int, maximum > 0 else {
            continue
        }
        return current * 100 / maximum
    }
    return nil
}

/// On battery at or below 5%. Charging never counts as low.
func batteryLow() -> Bool {
    guard !onACPower(), let percent = batteryPercent() else { return false }
    return percent <= lowBatteryPercent
}

/// EPERM means the process exists but belongs to another user (root watchdog).
func pidAlive(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

func readPidFile(_ path: String) -> pid_t? {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
          let value = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    return value
}

/// Runs a tool directly (no shell, no login profile).
@discardableResult
func runTool(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
    } catch {
        return (1, error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// Authoritative `pmset -g` read. Called only on events (launch, after 해제), never per second.
func pmsetSleepDisabled() -> Bool {
    let out = runTool("/usr/bin/pmset", ["-g"]).output
    for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
    }
    return false
}

func nowEpoch() -> Int { Int(Date().timeIntervalSince1970) }

func writeText(_ path: String, _ text: String) {
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
}

/// Holds a PreventUserIdleSystemSleep assertion (what `caffeinate -i` does).
/// macOS drops it automatically when the process exits or crashes.
final class IdleSleepAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var isHeld = false

    @discardableResult
    func hold(reason: String) -> Bool {
        guard !isHeld else { return true }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID
        )
        guard result == kIOReturnSuccess else { return false }
        id = newID
        isHeld = true
        return true
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        id = 0
        isHeld = false
    }
}
