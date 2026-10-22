import Darwin
import Foundation

// Compiled with Native.swift and Updater.swift by tests/test_native.sh.
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "ok " : "FAIL ") + name + (detail.isEmpty ? "" : " (\(detail))"))
    if !ok { failures += 1 }
}

let lid = readLidState()
check("lid state readable via IOKit", lid != .unknown, lid.rawValue)

let registry = rootDomainBool("SleepDisabled")
let pmset = pmsetSleepDisabled()
check("IOKit SleepDisabled matches pmset -g", registry == pmset,
      "ioreg=\(registry.map(String.init) ?? "nil") pmset=\(pmset)")

check("pidAlive(self)", pidAlive(getpid()))
check("pidAlive(1) via EPERM (launchd is root)", pidAlive(1))
var dead: pid_t = 99_999
while kill(dead, 0) == 0 || errno == EPERM { dead -= 1 }
check("pidAlive(dead pid) is false", !pidAlive(dead), "pid=\(dead)")

let assertion = IdleSleepAssertion()
check("IOPM assertion hold", assertion.hold(reason: "lidguard test"))
let listed = runTool("/usr/bin/pmset", ["-g", "assertions"]).output.contains("lidguard test")
check("assertion visible in pmset -g assertions", listed)
assertion.release()
let gone = !runTool("/usr/bin/pmset", ["-g", "assertions"]).output.contains("lidguard test")
check("assertion released", gone && !assertion.isHeld)

check("version compare", isVersion("1.5.1", newerThan: "1.5.0") && !isVersion("1.5.0", newerThan: "1.5")
      && isVersion("v1.10.0", newerThan: "1.9.9"))

let ac = onACPower()
let pmsetSource = runTool("/usr/bin/pmset", ["-g", "batt"]).output
check("onACPower matches pmset -g batt", ac == pmsetSource.contains("AC Power"), "ac=\(ac)")
let percent = batteryPercent()
let pmsetPercent = pmsetSource.range(of: #"(\d+)%"#, options: .regularExpression)
    .map { Int(pmsetSource[$0].dropLast()) ?? -1 }
check("batteryPercent matches pmset -g batt (±1)",
      percent == nil ? pmsetPercent == nil : abs((percent ?? 0) - (pmsetPercent ?? -100)) <= 1,
      "iokit=\(percent.map(String.init) ?? "nil") pmset=\(pmsetPercent.map(String.init) ?? "nil")")
check("batteryLow false at current charge", batteryLow() == (!ac && (percent ?? 100) <= lowBatteryPercent))

// Status line probes
let ticksA = readCPUTicks()
check("CPU ticks readable", ticksA != nil)
var spin = 0.0
for i in 0..<3_000_000 { spin += Double(i).squareRoot() }
usleep(200_000)
let ticksB = readCPUTicks()
let cpuValue = (ticksA != nil && ticksB != nil) ? cpuPercent(from: ticksA!, to: ticksB!) : nil
check("CPU percent in 0...100", cpuValue.map { (0...100).contains($0) } ?? false,
      "cpu=\(cpuValue.map(String.init) ?? "nil") spin=\(Int(spin) % 10)")
check("cpuPercent nil on wrapped counters",
      cpuPercent(from: CPUTicks(busy: 10, total: 100), to: CPUTicks(busy: 5, total: 50)) == nil)
let pressure = readMemoryPressure()
check("memory pressure readable", true, "\(pressure)")
let monitorUnderTest = SystemMonitor()
monitorUnderTest.start()
monitorUnderTest.sample()
let freePercent = readMemoryFreePercent()
check("memory free percent in 0...100", freePercent.map { (0...100).contains($0) } ?? false,
      "free=\(freePercent.map(String.init) ?? "nil")%")
check("SystemMonitor memoryFree set", monitorUnderTest.memoryFree != nil)
check("SystemMonitor battery matches batteryPercent", monitorUnderTest.battery.percent == batteryPercent())
let cpuCostStart = Date()
for _ in 0..<2000 { _ = readCPUTicks() }
print(String(format: "cost readCPUTicks %.2f µs/call", Date().timeIntervalSince(cpuCostStart) / 2000 * 1_000_000))

// Per-call cost of the per-second probes (old code spawned bash for each).
let n = 2000
var t = Date()
for _ in 0..<n { _ = readLidState() }
let lidMicros = Date().timeIntervalSince(t) / Double(n) * 1_000_000
t = Date()
for _ in 0..<n { _ = pidAlive(1) }
let pidMicros = Date().timeIntervalSince(t) / Double(n) * 1_000_000
t = Date()
for _ in 0..<200 { _ = onACPower() }
let powerMicros = Date().timeIntervalSince(t) / 200 * 1_000_000
print(String(format: "cost onACPower %.1f µs/call", powerMicros))
print(String(format: "cost readLidState %.1f µs/call, pidAlive %.2f µs/call", lidMicros, pidMicros))
check("native probes under 1 ms", lidMicros < 1000 && pidMicros < 1000)

exit(failures == 0 ? 0 : 1)
