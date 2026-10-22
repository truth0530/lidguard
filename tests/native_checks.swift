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
