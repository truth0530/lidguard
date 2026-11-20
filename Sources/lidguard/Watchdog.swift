import Darwin
import Foundation

// Closed-lid watchdog. Runs as root from the same binary:
//   lidguard --watchdog --gen N --closed-until EPOCH [--sleepnow-if-closed]
//            [--gui-pid PID] [--pidfile PATH] [--ac-only [--closed-unlimited]] [--daemonize]
//            [--request-dir DIR --request-uid UID]
// State it writes (pid, ui, heartbeat, gen, last_revert, log) lives in a
// root-owned dir (/var/run/lidguard). Requests from the user (stop, new
// deadline) come from the user's own dir, read with O_NOFOLLOW and an owner check.
// --closed-unlimited has no deadline and is accepted only with --ac-only, so
// unplugging, overheating, 5% battery, the app exiting or 해제 always end it.
// A finite closed timer keeps disablesleep on battery too. That is what holds
// a personal hotspot across a lid close. Only 무한 yields when unplugged.
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
    var closedUnlimited = false
    var daemonize = false
    var requestDir: String?
    var requestUid: uid_t?
}

enum Watchdog {
    /// Root-owned. Only the admin start script and this process write here.
    static let defaultStateDir = "/var/run/lidguard"
    static let stateDir = testOverride("LIDGUARD_STATE_DIR") ?? defaultStateDir
    /// Hard cap for a deadline set by request: 6 hours from now.
    static let maxRequestSeconds = 6 * 60 * 60
    /// Shortest deadline a request can set, so a typo cannot end the session at once.
    static var minRequestSeconds: Int { Int(testOverride("LIDGUARD_MIN_REQUEST_SECONDS") ?? "") ?? 60 }
    static var genPath: String { "\(stateDir)/lidguard_gen" }
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
            case "--closed-unlimited": options.closedUnlimited = true
            case "--daemonize": options.daemonize = true
            case "--request-dir": options.requestDir = value()
            case "--request-uid": options.requestUid = UInt32(value() ?? "")
            default:
                FileHandle.standardError.write("unknown arg: \(args[i])\n".data(using: .utf8)!)
                return nil
            }
            i += 1
        }
        guard !options.gen.isEmpty else { return nil }
        if (options.requestDir == nil) != (options.requestUid == nil) {
            FileHandle.standardError.write("--request-dir and --request-uid go together\n".data(using: .utf8)!)
            return nil
        }
        if options.closedUnlimited, !options.acOnly {
            FileHandle.standardError.write("--closed-unlimited requires --ac-only\n".data(using: .utf8)!)
            return nil
        }
        return options
    }

    static func main(_ rawArgs: [String]) -> Int32 {
        guard let options = parse(rawArgs) else {
            FileHandle.standardError.write(
                "usage: lidguard --watchdog --gen N --closed-until EPOCH [--sleepnow-if-closed] [--gui-pid PID] [--pidfile PATH] [--ac-only [--closed-unlimited]] [--daemonize] [--request-dir DIR --request-uid UID]\n"
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
    /// Current deadline. Starts at --closed-until; a request file can move it.
    var closedUntil: Int
    var sleepDisabled = false
    var lastLid: LidState = .unknown
    var lastPhase = ""
    var guiMissingSince: Int?
    var lidUnknownLogged = false
    var pausedForBattery = false

    init(options: WatchdogOptions) {
        self.options = options
        self.closedUntil = options.closedUntil
    }

    var stopPath: String? { options.requestDir.map { "\($0)/\(RequestFiles.stop)" } }
    var requestUntilPath: String? { options.requestDir.map { "\($0)/\(RequestFiles.closedUntil)" } }

    func stopRequested() -> Bool {
        guard let path = stopPath, let uid = options.requestUid else { return false }
        return readUserRequest(path, uid: uid, dir: options.requestDir!) != nil
    }

    /// A new deadline from the user, applied once and clamped to [now+1m, now+6h].
    /// 무한 has no deadline, so requests are dropped there.
    mutating func applyDeadlineRequest(_ now: Int) {
        guard let path = requestUntilPath, let uid = options.requestUid,
              let raw = readUserRequest(path, uid: uid, dir: options.requestDir!) else { return }
        unlink(path)
        guard let requested = Int(raw), requested > 0 else {
            log("request ignored: bad value")
            return
        }
        if options.closedUnlimited {
            log("request ignored: unlimited session has no deadline")
            return
        }
        let clamped = min(max(requested, now + Watchdog.minRequestSeconds), now + Watchdog.maxRequestSeconds)
        log("request closed_until \(closedUntil) -> \(clamped)\(clamped != requested ? " (clamped from \(requested))" : "")")
        closedUntil = clamped
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
        options.closedUnlimited || (closedUntil > 0 && now < closedUntil)
    }

    /// Timed closed-lid stays awake on battery so Wi-Fi survives the lid closing.
    /// Unlimited mode still stops on battery.
    func holdsClosedSleep(onAC: Bool) -> Bool {
        options.closedUnlimited ? onAC : true
    }

    /// Seconds to sleep: one poll, or less so the deadline is hit exactly.
    func pollWait(_ now: Int) -> Int {
        options.closedUnlimited
            ? Watchdog.pollSeconds
            : max(0, min(Watchdog.pollSeconds, closedUntil - now))
    }

    func pause(_ now: Int) {
        let wait = pollWait(now)
        if wait > 0 {
            sleep(UInt32(wait))
        } else if Watchdog.pollSeconds == 0 {
            usleep(50_000)
        }
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
        log("revert: \(reason) gen=\(options.gen) closed_until=\(closedUntil)")
        if stale() {
            log("skip revert, gen changed")
            return
        }
        // GUI reads this to tell 시간 종료 / 과열 / 해제 apart. Only root writes it.
        writeText(Watchdog.lastRevertPath, "\(nowEpoch()) \(reason)\n")
        chmod(Watchdog.lastRevertPath, 0o644)
        if sleepDisabled || closedUntil > 0 || options.closedUnlimited {
            clearDisableSleep()
        }
        unlink(Watchdog.heartbeatPath)
        if let path = requestUntilPath { unlink(path) }
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
        closed_until=\(closedUntil)
        closed_unlimited=\(options.closedUnlimited ? 1 : 0)
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
        log("start gen=\(options.gen) closed_until=\(closedUntil) gui_pid=\(options.guiPid.map(String.init) ?? "-") ac_only=\(options.acOnly) unlimited=\(options.closedUnlimited) poll=\(Watchdog.pollSeconds)")
        if closedActive(nowEpoch()), holdsClosedSleep(onAC: onACPower()) {
            setDisableSleep()
        }
        while true {
            if terminateRequested != 0 {
                revert("signal")
                return 0
            }
            // Stop file first. Bumping gen during 해제 must not skip revert.
            if stopRequested() {
                // The GUI removes the request after it has ended its own timers too.
                revert("stop-file")
                return 0
            }
            if stale() {
                log("gen changed, exit without revert")
                return 0
            }
            let now = nowEpoch()
            let before = closedUntil
            applyDeadlineRequest(now)
            if closedUntil != before {
                heartbeat(now, lid: lastLid, phase: lastPhase.isEmpty ? "request" : lastPhase)
            }
            if thermalSerious() {
                revert("thermal \(thermalLabel())")
                return 0
            }
            // macOS low-battery sleep may be blocked while disablesleep is on,
            // so stop at 5% on battery instead of letting the Mac die in a bag.
            if batteryLow() {
                revert("battery-low \(batteryPercent() ?? -1)%")
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
            // 무한만 배터리에서 잠자기를 돌려준다. 시간을 정한 닫힘 유지는
            // 배터리에서도 disablesleep을 유지해 핫스팟이 뚜껑을 닫아도 남는다.
            if options.closedUnlimited, !onACPower() {
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
                pause(now)
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
            pause(now)
        }
    }
}

