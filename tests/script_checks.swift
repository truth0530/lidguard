import Darwin
import Foundation

// Compiled with StartScript.swift by tests/test_script.sh. Never runs the
// script as root: syntax via `bash -n`, quoting via a non-admin osascript echo.
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "ok " : "FAIL ") + name + (detail.isEmpty ? "" : " (\(detail))"))
    if !ok { failures += 1 }
}
func run(_ path: String, _ args: [String], stdin: String? = nil) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    let inp = Pipe(); if stdin != nil { p.standardInput = inp }
    try! p.run()
    if let stdin { inp.fileHandleForWriting.write(stdin.data(using: .utf8)!); try? inp.fileHandleForWriting.close() }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let weirdExe = "/Users/a b/Applications/잠자기 '방지'.app/Contents/MacOS/lidguard"
let weirdDir = "/Users/a b/Library/Application Support/lid\"guard'"
for (unlimited, acOnly, arm) in [(false, false, true), (true, true, false), (false, true, true)] {
    let script = buildStartScript(exe: weirdExe, closedUntil: unlimited ? 0 : 1_800_000_000, guiPid: 1234,
                                  acOnly: acOnly, unlimited: unlimited, armNow: arm,
                                  requestDir: weirdDir, requestUid: 501)
    let tag = "unlimited=\(unlimited) ac=\(acOnly) arm=\(arm)"
    let (rc, out) = run("/bin/bash", ["-n"], stdin: script)
    check("bash -n \(tag)", rc == 0, out)
    check("no /tmp path \(tag)", !script.contains("/tmp"))
    check("gen bumped in script \(tag)", script.contains("--gen \"$G\""))
    check("flags \(tag)", script.contains("--ac-only") == acOnly && script.contains("--closed-unlimited") == unlimited)
    // Same nesting as adminShell, minus admin: printf the script instead of running it.
    let cmd = "/usr/bin/printf %s \(shellQuote(script))"
    let (orc, echoed) = run("/usr/bin/osascript", ["-e", "do shell script \(appleQuote(cmd))"])
    check("osascript quoting round-trip \(tag)", orc == 0 && echoed.replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .newlines) == script.trimmingCharacters(in: .newlines))
    // The quoted args survive: parse the watchdog line with bash and look at argv.
    let probe = script.replacingOccurrences(of: "'\(weirdExe.replacingOccurrences(of: "'", with: "'\\''"))' --watchdog", with: "printf '[%s]\\n' --watchdog")
    let lines = probe.components(separatedBy: "\n")
    if let s = lines.firstIndex(where: { $0.contains("printf '[%s]") }) {
        let cmdLines = lines[s...].prefix(4).joined(separator: "\n")
            .replacingOccurrences(of: ">>\"$D/lidguard_watchdog.log\" 2>&1", with: "")
        let (_, argv) = run("/bin/bash", ["-c", "D=/x; G=7; " + cmdLines])
        check("request-dir arg intact \(tag)", argv.contains("[\(weirdDir)]"), argv)
    } else { check("watchdog line found \(tag)", false) }
}
exit(failures == 0 ? 0 : 1)
