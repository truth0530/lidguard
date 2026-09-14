import AppKit
import Foundation

private let stateDir = "/tmp"
private let genPath = "\(stateDir)/lidguard_gen"
private let untilPath = "\(stateDir)/lidguard_until"
private let stopPath = "\(stateDir)/lidguard_stop"
private let caffeinatePidPath = "\(stateDir)/lidguard_caffeinate.pid"
private let watchdogPidPath = "\(stateDir)/lidguard_watchdog.pid"
private let watchdogLogPath = "\(stateDir)/lidguard_watchdog.log"
private let startScriptPath = "\(stateDir)/lidguard_start.sh"
private let watchdogCopyPath = "\(stateDir)/lidguard_watchdog.sh"
private let daemonizeCopyPath = "\(stateDir)/lidguard_daemonize.py"

private let closedDurations: [Int] = [0, 15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60]
private let closedLabels = ["끔", "15분", "30분", "1시간", "2시간", "4시간"]
private let openDurations: [Int] = [0, 15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60, -1]
private let openLabels = ["끔", "15분", "30분", "1시간", "2시간", "4시간", "무한"]

private func shell(_ command: String) -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = ["-lc", command]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        return (1, error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

private func appleQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

@discardableResult
private func adminShell(_ command: String) -> Bool {
    let script = "do shell script \(appleQuote(command)) with administrator privileges"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    } catch {
        return false
    }
}

private func sleepDisabled() -> Bool {
    let (_, out) = shell("pmset -g | awk '/SleepDisabled/{print $2}'")
    return out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
}

private func caffeinateAlive() -> Bool {
    let (status, _) = shell("test -f \(caffeinatePidPath) && kill -0 $(cat \(caffeinatePidPath)) 2>/dev/null")
    return status == 0
}

private func watchdogAlive() -> Bool {
    let (status, _) = shell("test -f \(watchdogPidPath) && kill -0 $(cat \(watchdogPidPath)) 2>/dev/null")
    return status == 0
}

private func fmtDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return String(format: "%d시간 %02d분 %02d초", h, m, sec)
}

private func nowEpoch() -> Int { Int(Date().timeIntervalSince1970) }

private func copyResource(_ name: String, ext: String, to destination: String) {
    if let bundled = Bundle.main.path(forResource: name, ofType: ext),
       let data = try? Data(contentsOf: URL(fileURLWithPath: bundled)) {
        try? data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        _ = shell("chmod 755 \(destination)")
    }
}

private func installHelpers() {
    copyResource("watchdog", ext: "sh", to: watchdogCopyPath)
    copyResource("daemonize", ext: "py", to: daemonizeCopyPath)
}

private func bumpGeneration() -> Int {
    let (_, out) = shell(
        "G=$(( $(cat \(genPath) 2>/dev/null || echo 0) + 1 )); echo $G > \(genPath); echo $G"
    )
    return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
}

private func writeFile(_ path: String, _ text: String) {
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
}

private func killCaffeinate() {
    _ = shell("test -f \(caffeinatePidPath) && kill $(cat \(caffeinatePidPath)) 2>/dev/null; rm -f \(caffeinatePidPath)")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let phaseBadge = NSTextField(labelWithString: "○  작동 준비")
    let statusLabel = NSTextField(labelWithString: "평소처럼 잠자기 · 시작을 누르면 잠자기 방지")
    let countdownLabel = NSTextField(labelWithString: "닫힘 · 열림 시간을 각각 고르세요")
    var statusBox: NSView?
    var closedSeg: NSSegmentedControl?
    var openSeg: NSSegmentedControl?
    var startBtn: NSButton?
    var stopBtn: NSButton?
    var timer: Timer?
    private var isSessionActive = false
    private var isStarting = false
    private var isStopping = false
    private var closedUntil: Int?
    private var openUntil: Int?
    private var openUnlimited = false
    private var needsAdmin = false
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildUI()
        restoreIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isSessionActive || sleepDisabled() || caffeinateAlive() {
            stopSession()
            isSessionActive = false
            endActivity()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isSessionActive || sleepDisabled() {
            stopSession()
        }
        endActivity()
        timer?.invalidate()
    }

    func buildUI() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "잠자기 방지"
        window.isReleasedWhenClosed = true
        window.center()
        self.window = window

        let content = NSView(frame: window.contentView!.bounds)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let title = NSTextField(labelWithString: "잠자기 방지")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let closedHint = NSTextField(labelWithString: "뚜껑을 닫았을 때")
        closedHint.textColor = .secondaryLabelColor
        closedHint.translatesAutoresizingMaskIntoConstraints = false

        let closedSeg = NSSegmentedControl(labels: closedLabels, trackingMode: .selectOne, target: nil, action: nil)
        closedSeg.segmentStyle = .rounded
        closedSeg.selectedSegment = 3
        closedSeg.translatesAutoresizingMaskIntoConstraints = false
        self.closedSeg = closedSeg

        let openHint = NSTextField(labelWithString: "뚜껑을 열었을 때")
        openHint.textColor = .secondaryLabelColor
        openHint.translatesAutoresizingMaskIntoConstraints = false

        let openSeg = NSSegmentedControl(labels: openLabels, trackingMode: .selectOne, target: nil, action: nil)
        openSeg.segmentStyle = .rounded
        openSeg.selectedSegment = 0
        openSeg.translatesAutoresizingMaskIntoConstraints = false
        self.openSeg = openSeg

        let start = NSButton(title: "시작", target: self, action: #selector(startPressed))
        start.bezelStyle = .rounded
        start.setButtonType(.momentaryPushIn)
        start.translatesAutoresizingMaskIntoConstraints = false
        start.keyEquivalent = "\r"
        startBtn = start

        let stop = NSButton(title: "해제", target: self, action: #selector(stopPressed))
        stop.bezelStyle = .rounded
        stop.translatesAutoresizingMaskIntoConstraints = false
        stopBtn = stop

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        statusBox = box

        phaseBadge.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        phaseBadge.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(phaseBadge)
        box.addSubview(statusLabel)
        box.addSubview(countdownLabel)

        let note = NSTextField(labelWithString: "1.2.0  ·  덮개를 열면 닫힘 유지를 바로 풀고, 시간은 워치독이 벽시계로 끝냅니다")
        note.textColor = .secondaryLabelColor
        note.font = NSFont.systemFont(ofSize: 11)
        note.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(closedHint)
        content.addSubview(closedSeg)
        content.addSubview(openHint)
        content.addSubview(openSeg)
        content.addSubview(start)
        content.addSubview(stop)
        content.addSubview(box)
        content.addSubview(note)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),

            closedHint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            closedHint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            closedSeg.topAnchor.constraint(equalTo: closedHint.bottomAnchor, constant: 6),
            closedSeg.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            closedSeg.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            openHint.topAnchor.constraint(equalTo: closedSeg.bottomAnchor, constant: 14),
            openHint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            openSeg.topAnchor.constraint(equalTo: openHint.bottomAnchor, constant: 6),
            openSeg.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            openSeg.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            start.topAnchor.constraint(equalTo: openSeg.bottomAnchor, constant: 16),
            start.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            start.widthAnchor.constraint(equalToConstant: 96),
            stop.centerYAnchor.constraint(equalTo: start.centerYAnchor),
            stop.leadingAnchor.constraint(equalTo: start.trailingAnchor, constant: 10),
            stop.widthAnchor.constraint(equalToConstant: 96),

            box.topAnchor.constraint(equalTo: start.bottomAnchor, constant: 18),
            box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            box.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            box.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -14),

            phaseBadge.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            phaseBadge.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            statusLabel.topAnchor.constraint(equalTo: phaseBadge.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: phaseBadge.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            countdownLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            countdownLabel.leadingAnchor.constraint(equalTo: phaseBadge.leadingAnchor),
            countdownLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            countdownLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),

            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])

        updateButtons()
        updateStatusVisuals()
    }

    func restoreIfNeeded() {
        guard sleepDisabled() || caffeinateAlive() || watchdogAlive() else { return }
        isSessionActive = true
        needsAdmin = sleepDisabled()
        beginActivity()
        updateButtons()
        updateStatusVisuals()
    }

    func tick() {
        if isSessionActive, !watchdogAlive(), !sleepDisabled(), !caffeinateAlive() {
            isSessionActive = false
            closedUntil = nil
            openUntil = nil
            openUnlimited = false
            needsAdmin = false
            endActivity()
        }
        updateStatusVisuals()
        updateButtons()
    }

    func updateButtons() {
        let busy = isStarting || isStopping
        startBtn?.isEnabled = !isSessionActive && !busy
        stopBtn?.isEnabled = (isSessionActive || sleepDisabled() || caffeinateAlive()) && !busy
        closedSeg?.isEnabled = !isSessionActive && !busy
        openSeg?.isEnabled = !isSessionActive && !busy
    }

    func remainingText() -> String {
        var parts: [String] = []
        if let until = closedUntil, until > 0 {
            parts.append("닫힘  " + fmtDuration(until - nowEpoch()))
        } else {
            parts.append("닫힘  끔")
        }
        if openUnlimited {
            parts.append("열림  무한")
        } else if let until = openUntil, until > 0 {
            parts.append("열림  " + fmtDuration(until - nowEpoch()))
        } else {
            parts.append("열림  끔")
        }
        return parts.joined(separator: "   ·   ")
    }

    func updateStatusVisuals() {
        if isStarting {
            phaseBadge.stringValue = "●  켜는 중"
            statusLabel.stringValue = "권한 확인 또는 워치독 시작…"
            return
        }
        if isStopping {
            phaseBadge.stringValue = "●  해제 중"
            statusLabel.stringValue = "잠자기 설정을 되돌리는 중"
            return
        }
        if isSessionActive || sleepDisabled() || caffeinateAlive() {
            phaseBadge.stringValue = "●  작동 중"
            statusLabel.stringValue = "덮개를 열면 닫힘 유지를 즉시 해제합니다"
            countdownLabel.stringValue = remainingText()
            statusBox?.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.18).cgColor
        } else {
            phaseBadge.stringValue = "○  작동 준비"
            statusLabel.stringValue = "평소처럼 잠자기 · 시작을 누르면 잠자기 방지"
            countdownLabel.stringValue = "닫힘 · 열림 시간을 각각 고르세요"
            statusBox?.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    @objc func startPressed() {
        guard !isStarting, !isSessionActive else { return }
        let closedIdx = max(0, closedSeg?.selectedSegment ?? 3)
        let openIdx = max(0, openSeg?.selectedSegment ?? 0)
        let closedSeconds = closedDurations[min(closedIdx, closedDurations.count - 1)]
        let openSeconds = openDurations[min(openIdx, openDurations.count - 1)]
        if closedSeconds == 0, openSeconds == 0 {
            statusLabel.stringValue = "닫힘·열림이 모두 끔입니다 · 하나를 고르세요"
            return
        }
        isStarting = true
        updateButtons()
        updateStatusVisuals()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = self?.startSession(closedSeconds: closedSeconds, openSeconds: openSeconds) ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStarting = false
                if ok {
                    self.isSessionActive = true
                    self.needsAdmin = closedSeconds > 0
                    let now = nowEpoch()
                    self.closedUntil = closedSeconds > 0 ? now + closedSeconds : nil
                    if openSeconds < 0 {
                        self.openUnlimited = true
                        self.openUntil = nil
                    } else if openSeconds > 0 {
                        self.openUnlimited = false
                        self.openUntil = now + openSeconds
                    } else {
                        self.openUnlimited = false
                        self.openUntil = nil
                    }
                    self.beginActivity()
                } else {
                    self.statusLabel.stringValue = "시작 실패 · 암호 취소 또는 워치독 오류"
                }
                self.updateButtons()
                self.updateStatusVisuals()
            }
        }
    }

    @objc func stopPressed() {
        guard !isStopping else { return }
        isStopping = true
        updateButtons()
        updateStatusVisuals()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.stopSession()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStopping = false
                self.isSessionActive = false
                self.closedUntil = nil
                self.openUntil = nil
                self.openUnlimited = false
                self.needsAdmin = false
                self.endActivity()
                self.updateButtons()
                self.updateStatusVisuals()
            }
        }
    }

    private func startSession(closedSeconds: Int, openSeconds: Int) -> Bool {
        try? FileManager.default.removeItem(atPath: stopPath)
        installHelpers()
        let gen = bumpGeneration()
        let now = nowEpoch()
        let closedUntilEpoch = closedSeconds > 0 ? now + closedSeconds : 0
        let openUntilEpoch = openSeconds > 0 ? now + openSeconds : 0
        if closedUntilEpoch > 0 {
            writeFile(untilPath, "\(closedUntilEpoch)\n")
        } else {
            try? FileManager.default.removeItem(atPath: untilPath)
        }

        var args = "--gen \(gen) --closed-until \(closedUntilEpoch) --open-until \(openUntilEpoch)"
        if openSeconds < 0 {
            args += " --open-unlimited"
        }
        if closedSeconds > 0 {
            args += " --sleepnow-if-closed"
        }

        let launch = "/usr/bin/python3 \(daemonizeCopyPath) \(watchdogPidPath) /bin/bash \(watchdogCopyPath) \(args) >>\(watchdogLogPath) 2>&1"
        if closedSeconds > 0 {
            let script = """
            #!/bin/bash
            \(launch)
            for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
              if [ -f \(watchdogPidPath) ] && kill -0 "$(cat \(watchdogPidPath))" 2>/dev/null; then
                exit 0
              fi
              sleep 0.1
            done
            exit 1
            """
            writeFile(startScriptPath, script)
            _ = shell("chmod 755 \(startScriptPath)")
            return adminShell("/bin/bash \(startScriptPath)")
        }

        _ = shell(launch)
        for _ in 0..<15 {
            if watchdogAlive() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return watchdogAlive()
    }

    private func stopSession() {
        writeFile(stopPath, "1\n")
        killCaffeinate()
        for _ in 0..<20 {
            if !sleepDisabled(), !watchdogAlive() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if sleepDisabled() {
            _ = adminShell("/usr/bin/pmset -a disablesleep 0; exit 0")
        }
        _ = bumpGeneration()
        try? FileManager.default.removeItem(atPath: untilPath)
        try? FileManager.default.removeItem(atPath: stopPath)
        try? FileManager.default.removeItem(atPath: watchdogPidPath)
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "lidguard session"
        )
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

@main
enum LidguardApp {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        menu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "잠자기 방지 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        app.mainMenu = menu
        app.setActivationPolicy(.regular)
        app.run()
    }
}
