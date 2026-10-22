import Darwin
import Foundation

// Closed-lid watchdog. Runs as root from the same binary:
//   lidguard --watchdog --gen N --closed-until EPOCH [--sleepnow-if-closed]
//            [--gui-pid PID] [--pidfile PATH] [--ac-only] [--daemonize]
// It owns `pmset disablesleep` for the closed-lid timer and must keep working
// if the GUI dies. Each poll is a file stat plus an IOKit read; pmset runs only
// on transitions (set once, clear once, optional sleepnow).

private var terminateRequested: sig_atomic_t = 0

struct WatchdogOptions {
    var gen = ""
    var closedUntil = 0
    var sleepnowIfClosed = false
    var guiPid: pid_t?
    var pidfile: String?
    var acOnly = false
    var daemonize = false
}

enum Watchdog {
    static let stateDir = ProcessInfo.processInfo.environment["LIDGUARD_STATE_DIR"] ?? "/tmp"
    static var genPath: String { "\(stateDir)/lidguard_gen" }
    static var stopPath: String { "\(stateDir)/lidguard_stop" }
    static var untilPath: String { "\(stateDir)/lidguard_until" }
    static var heartbeatPath: String { "\(stateDir)/lidguard_heartbeat" }
    static var uiStatePath: String { "\(stateDir)/lidguard_ui" }
    static var lastRevertPath: String { "\(stateDir)/lidguard_last_revert" }
    static var logPath: String {
        testOverride("LIDGUARD_LOG") ?? "\(stateDir)/lidguard_watchdog.log"
    }
    static var pmsetPath: String { testOverride("LIDGUARD_PMSET") ?? "/usr/bin/pmset" }
    static var pollSeconds: Int {
        Int(ProcessInfo.processInfo.environment["LIDGUARD_POLL_SECONDS"] ?? "") ?? 2
    }
    static var guiGraceSeconds: Int {
        Int(testOverride("LIDGUARD_GUI_GRACE") ?? "") ?? 60
    }

    static func parse(_ args: [String]) -> WatchdogOptions? {
        var options = WatchdogOptions()
        var i = 0
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--watchdog": break
            case "--gen": options.gen = value() ?? ""
            case "--closed-until": options.closedUntil = Int(value() ?? "") ?? 0
            case "--sleepnow-if-closed": options.sleepnowIfClosed = true
            case "--gui-pid": options.guiPid = Int32(value() ?? "")
            case "--pidfile": options.pidfile = value()
            case "--ac-only": options.acOnly = true
            case "--daemonize": options.daemonize = true
            default:
                FileHandle.standardError.write("unknown arg: \(args[i])\n".data(using: .utf8)!)
                return nil
            }
            i += 1
        }
        guard !options.gen.isEmpty else { return nil }
        return options
    }

    static func main(_ rawArgs: [String]) -> Int32 {
        guard let options = parse(rawArgs) else {
            FileHandle.standardError.write(
                "usage: lidguard --watchdog --gen N --closed-until EPOCH [--sleepnow-if-closed] [--gui-pid PID] [--pidfile PATH] [--ac-only] [--daemonize]\n"
                    .data(using: .utf8)!)
            return 2
        }
        if options.daemonize {
            return spawnDetached(rawArgs.filter { $0 != "--daemonize" })
        }
        if let pidfile = options.pidfile {
            writeText(pidfile, "\(getpid())\n")
        }
        signal(SIGTERM) { _ in terminateRequested = 1 }
        signal(SIGINT) { _ in terminateRequested = 1 }
        signal(SIGHUP, SIG_IGN)
        var loop = WatchdogLoop(options: options)
        return loop.run()
    }

    /// Replaces daemonize.py: new session via POSIX_SPAWN_SETSID so the
    /// osascript admin shell cannot take the watchdog down with it.
    static func spawnDetached(_ args: [String]) -> Int32 {
        guard let exe = Bundle.main.executablePath else { return 1 }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&actions)
        }
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attr, argv, envp)
        if rc != 0 {
            FileHandle.standardError.write("posix_spawn failed: \(rc)\n".data(using: .utf8)!)
            return 1
        }
        return 0
    }
}

struct WatchdogLoop {
    let options: WatchdogOptions
    var sleepDisabled = false
    var lastLid: LidState = .unknown
    var lastPhase = ""
    var guiMissingSince: Int?
    var lidUnknownLogged = false
    var pausedForBattery = false

    init(options: WatchdogOptions) {
        self.options = options
    }

    func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let path = Watchdog.logPath
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    func stale() -> Bool {
        let current = (try? String(contentsOfFile: Watchdog.genPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return current != options.gen
    }

    func closedActive(_ now: Int) -> Bool {
        options.closedUntil > 0 && now < options.closedUntil
    }

    mutating func setDisableSleep() {
        if runTool(Watchdog.pmsetPath, ["-a", "disablesleep", "1"]).status == 0 {
            if !sleepDisabled { log("disablesleep 1") }
            sleepDisabled = true
        } else {
            log("disablesleep 1 failed")
        }
    }

    mutating func clearDisableSleep() {
        if runTool(Watchdog.pmsetPath, ["-a", "disablesleep", "0"]).status == 0 {
            if sleepDisabled { log("disablesleep 0") }
            sleepDisabled = false
        } else {
            log("disablesleep 0 failed")
        }
    }

    mutating func revert(_ reason: String) {
        log("revert: \(reason) gen=\(options.gen) closed_until=\(options.closedUntil)")
        if stale() {
            log("skip revert, gen changed")
            return
        }
        // GUI reads this to tell 시간 종료 / 과열 / 해제 apart. 666 so a later
        // non-root process can overwrite a file a root watchdog created.
        writeText(Watchdog.lastRevertPath, "\(nowEpoch()) \(reason)\n")
        chmod(Watchdog.lastRevertPath, 0o666)
        if sleepDisabled || options.closedUntil > 0 {
            clearDisableSleep()
        }
        unlink(Watchdog.untilPath)
        unlink(Watchdog.heartbeatPath)
        if let pidfile = options.pidfile { unlink(pidfile) }
        let lid = readLidState()
        // A confirmed open lid must never trigger sleepnow.
        if options.sleepnowIfClosed, lid == .closed || (lid == .unknown && lastLid == .closed) {
            log("clamshell closed — sleepnow")
            runTool(Watchdog.pmsetPath, ["sleepnow"])
        } else if options.sleepnowIfClosed {
            log("clamshell not confirmed closed — skip sleepnow state=\(lid.rawValue) last=\(lastLid.rawValue)")
        }
    }

    mutating func heartbeat(_ now: Int, lid: LidState, phase: String) {
        writeText(Watchdog.heartbeatPath, "\(now)\n")
        writeText(Watchdog.uiStatePath, """
        heartbeat=\(now)
        closed_until=\(options.closedUntil)
        ac_only=\(options.acOnly ? 1 : 0)
        lid=\(lid.rawValue)
        phase=\(phase)
        gen=\(options.gen)

        """)
        if phase != lastPhase {
            log("phase=\(phase) lid=\(lid.rawValue)")
            lastPhase = phase
        }
    }

    mutating func run() -> Int32 {
        log("start gen=\(options.gen) closed_until=\(options.closedUntil) gui_pid=\(options.guiPid.map(String.init) ?? "-") ac_only=\(options.acOnly) poll=\(Watchdog.pollSeconds)")
        if closedActive(nowEpoch()), !options.acOnly || onACPower() {
            setDisableSleep()
        }
        while true {
            if terminateRequested != 0 {
                revert("signal")
                return 0
            }
            // Stop file first. Bumping gen during 해제 must not skip revert.
            if access(Watchdog.stopPath, F_OK) == 0 {
                revert("stop-file")
                return 0
            }
            if stale() {
                log("gen changed, exit without revert")
                return 0
            }
            let now = nowEpoch()
            if thermalSerious() {
                revert("thermal \(thermalLabel())")
                return 0
            }
            if let gui = options.guiPid {
                if pidAlive(gui) {
                    guiMissingSince = nil
                } else {
                    let since = guiMissingSince ?? now
                    guiMissingSince = since
                    if now - since >= Watchdog.guiGraceSeconds {
                        revert("gui-exited")
                        return 0
                    }
                }
            }

            let lid = readLidState()
            if lid == .unknown {
                if !lidUnknownLogged {
                    log("clamshell state unavailable; retaining last=\(lastLid.rawValue)")
                    lidUnknownLogged = true
                }
            } else {
                lastLid = lid
                lidUnknownLogged = false
            }

            guard closedActive(now) else {
                switch lid {
                case .closed: revert("closed-idle")
                case .open: revert("open-idle")
                case .unknown: revert("lid-state-unknown")
                }
                return 0
            }
            // 전원 연결 중일 때만: on battery, give sleep back to macOS but keep
            // the timer; plugging in again within the timer re-arms.
            if options.acOnly, !onACPower() {
                if !pausedForBattery {
                    pausedForBattery = true
                    log("power battery — pause")
                    // Always clear: the start script may have set it before this process tracked it.
                    clearDisableSleep()
                    if lid == .closed {
                        log("battery with lid closed — sleepnow")
                        runTool(Watchdog.pmsetPath, ["sleepnow"])
                    }
                }
                heartbeat(now, lid: lid == .unknown ? lastLid : lid, phase: "battery-paused")
                let wait = max(0, min(Watchdog.pollSeconds, options.closedUntil - now))
                if wait > 0 { sleep(UInt32(wait)) } else if Watchdog.pollSeconds == 0 { usleep(50_000) }
                continue
            }
            if pausedForBattery {
                pausedForBattery = false
                log("power ac — resume")
            }
            // Closed mode must hold disablesleep even while the lid is still
            // open; Clamshell Sleep is synchronous, so a post-close poll loses.
            if !sleepDisabled {
                setDisableSleep()
            }
            switch lid {
            case .closed: heartbeat(now, lid: lid, phase: "lid-closed-awake")
            case .open: heartbeat(now, lid: lid, phase: "lid-open-closed-armed")
            case .unknown: heartbeat(now, lid: lastLid, phase: "lid-state-unknown")
            }

            // Wake exactly at the deadline instead of overshooting by a poll.
            let wait = max(0, min(Watchdog.pollSeconds, options.closedUntil - now))
            if wait > 0 {
                sleep(UInt32(wait))
            } else if Watchdog.pollSeconds == 0 {
                usleep(50_000)
            }
        }
    }
}
