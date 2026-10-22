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
private let heartbeatPath = "\(stateDir)/lidguard_heartbeat"
private let uiStatePath = "\(stateDir)/lidguard_ui"
private let lastRevertPath = "\(stateDir)/lidguard_last_revert"
private let lastUpdateCheckKey = "lastUpdateCheck"
private let updateCheckInterval: TimeInterval = 24 * 60 * 60

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
private func adminShell(_ command: String) -> (Bool, String) {
    let script = "do shell script \(appleQuote(command)) with administrator privileges"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (proc.terminationStatus == 0, out)
    } catch {
        return (false, error.localizedDescription)
    }
}

private func sleepDisabled() -> Bool {
    let (_, out) = shell("pmset -g | awk '/SleepDisabled/{print $2}'")
    return out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
}

/// `kill -0` on a root watchdog returns EPERM and looks "dead" to the GUI.
private func pidFileAlive(_ path: String) -> Bool {
    let (status, _) = shell(
        "PID=$(cat \(path) 2>/dev/null | tr -d '[:space:]'); [ -n \"$PID\" ] && /bin/ps -p \"$PID\" -o pid= >/dev/null"
    )
    return status == 0
}

private func caffeinateAlive() -> Bool {
    pidFileAlive(caffeinatePidPath)
}

private func watchdogAlive() -> Bool {
    if pidFileAlive(watchdogPidPath) { return true }
    guard let raw = try? String(contentsOfFile: heartbeatPath, encoding: .utf8),
          let ts = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return false
    }
    return nowEpoch() - ts < 25
}

private func lidClosed() -> Bool {
    let (_, out) = shell(
        "/usr/sbin/ioreg -r -k AppleClamshellState -d 4 2>/dev/null | awk -F'= ' '/AppleClamshellState/ { gsub(/[ ;]/, \"\", $2); print $2; exit }'"
    )
    return out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes"
}

private func fmtDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    if h > 0 { return String(format: "%d시간 %d분 %02d초", h, m, sec) }
    if m > 0 { return String(format: "%d분 %02d초", m, sec) }
    return String(format: "%d초", sec)
}

private func nowEpoch() -> Int { Int(Date().timeIntervalSince1970) }

private func copyResource(_ name: String, ext: String, to destination: String) -> Bool {
    guard let bundled = Bundle.main.path(forResource: name, ofType: ext),
          let data = try? Data(contentsOf: URL(fileURLWithPath: bundled)) else {
        return false
    }
    do {
        try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
    } catch {
        return false
    }
    _ = shell("chmod 755 \(appleQuote(destination))")
    return FileManager.default.isExecutableFile(atPath: destination)
}

private func installHelpers() -> String? {
    if !copyResource("watchdog", ext: "sh", to: watchdogCopyPath) {
        return "앱 안의 watchdog.sh를 복사하지 못했습니다"
    }
    if !copyResource("daemonize", ext: "py", to: daemonizeCopyPath) {
        return "앱 안의 daemonize.py를 복사하지 못했습니다"
    }
    if !FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
        return "/usr/bin/python3 이 없습니다 · 명령줄 도구를 설치하세요"
    }
    return nil
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

/// Watchdog writes `<epoch> <reason>` whenever it restores sleep.
private func readLastRevert() -> (epoch: Int, reason: String)? {
    guard let raw = try? String(contentsOfFile: lastRevertPath, encoding: .utf8) else { return nil }
    let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
    guard parts.count == 2, let epoch = Int(parts[0]) else { return nil }
    return (epoch, String(parts[1]))
}

private func clockText(_ epoch: Int) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.dateFormat = "a h:mm"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

private func killCaffeinate() {
    _ = shell("test -f \(caffeinatePidPath) && kill $(cat \(caffeinatePidPath)) 2>/dev/null; rm -f \(caffeinatePidPath)")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var closedCard: NSView?
    var openCard: NSView?
    var closedAccent: NSView?
    var openAccent: NSView?
    var closedHint: NSTextField?
    var closedNote: NSTextField?
    var closedLiveNote: NSTextField?
    var openHint: NSTextField?
    var closedBadge: NSTextField?
    var openBadge: NSTextField?
    var closedRemain: NSTextField?
    var openRemain: NSTextField?
    var closedSeg: NSSegmentedControl?
    var openSeg: NSSegmentedControl?
    var startBtn: NSButton?
    var stopBtn: NSButton?
    var errorLabel: NSTextField?
    var timer: Timer?
    private var isSessionActive = false
    private var isStarting = false
    private var isStopping = false
    private var closedUntil: Int?
    private var openUntil: Int?
    private var openUnlimited = false
    private var needsAdmin = false
    private var lastError: String?
    private var lastLayoutKey = ""
    private var activity: NSObjectProtocol?
    private var infoMessage: String?
    private var infoColor: NSColor = .secondaryLabelColor
    private var sessionStartedAt = 0
    private var pendingRelease: ReleaseInfo?
    private var updatePrompting = false
    private var updateBusy = false
    private var updateChecking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildUI()
        restoreIfNeeded()
        checkForUpdatesIfDue()
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
            contentRect: NSRect(x: 0, y: 0, width: 456, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "잠자기 방지"
        window.isReleasedWhenClosed = true
        window.center()
        self.window = window

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = NSFont.systemFont(ofSize: size, weight: weight)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }
        func accentMark() -> NSView {
            let mark = NSView()
            mark.wantsLayer = true
            mark.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            mark.layer?.cornerRadius = 1.5
            mark.translatesAutoresizingMaskIntoConstraints = false
            mark.widthAnchor.constraint(equalToConstant: 3).isActive = true
            mark.heightAnchor.constraint(equalToConstant: 14).isActive = true
            mark.isHidden = true
            return mark
        }
        func headerRow(accent: NSView, title: NSTextField, badge: NSTextField) -> NSStackView {
            let row = NSStackView(views: [accent, title, badge])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.alignment = .right
            badge.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            return row
        }
        func section(title: NSTextField, badge: NSTextField, remain: NSTextField,
                     seg: NSSegmentedControl, accent: NSView) -> NSStackView {
            let stack = NSStackView(views: [headerRow(accent: accent, title: title, badge: badge), remain, seg])
            stack.orientation = .vertical
            stack.alignment = .width
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            return stack
        }

        let closedAccent = accentMark()
        self.closedAccent = closedAccent
        let closedHint = label("뚜껑을 닫아도 켜 두기", size: 13, weight: .medium)
        closedHint.textColor = .labelColor
        self.closedHint = closedHint
        let closedBadge = label("", size: 12, weight: .regular)
        closedBadge.textColor = .tertiaryLabelColor
        self.closedBadge = closedBadge
        let closedRemain = label("", size: 26, weight: .regular)
        closedRemain.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .regular)
        closedRemain.textColor = .labelColor
        closedRemain.isHidden = true
        self.closedRemain = closedRemain
        let closedSeg = NSSegmentedControl(labels: closedLabels, trackingMode: .selectOne, target: nil, action: nil)
        closedSeg.segmentStyle = .capsule
        closedSeg.controlSize = .regular
        closedSeg.selectedSegment = 3
        closedSeg.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.closedSeg = closedSeg
        let closedNote = label("켜면 화면 자동꺼짐도 같이 막힙니다 · 과열되면 자동으로 풀립니다", size: 11, weight: .regular)
        closedNote.textColor = .secondaryLabelColor
        self.closedNote = closedNote
        let closedLiveNote = label("가방에 넣기 전에 남은 시간을 확인하세요. 시간이 끝나면 잠자기로 돌아가고, 과열되면 바로 풀립니다.", size: 11, weight: .regular)
        closedLiveNote.textColor = .secondaryLabelColor
        closedLiveNote.lineBreakMode = .byWordWrapping
        closedLiveNote.maximumNumberOfLines = 2
        closedLiveNote.isHidden = true
        self.closedLiveNote = closedLiveNote
        let closedCard = section(title: closedHint, badge: closedBadge, remain: closedRemain,
                                 seg: closedSeg, accent: closedAccent)
        closedCard.addArrangedSubview(closedNote)
        closedCard.addArrangedSubview(closedLiveNote)
        self.closedCard = closedCard

        let openAccent = accentMark()
        self.openAccent = openAccent
        let openHint = label("뚜껑이 열렸을 때만 켜 두기", size: 13, weight: .medium)
        openHint.textColor = .labelColor
        self.openHint = openHint
        let openBadge = label("", size: 12, weight: .regular)
        openBadge.textColor = .tertiaryLabelColor
        self.openBadge = openBadge
        let openRemain = label("", size: 26, weight: .regular)
        openRemain.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .regular)
        openRemain.textColor = .labelColor
        openRemain.isHidden = true
        self.openRemain = openRemain
        let openSeg = NSSegmentedControl(labels: openLabels, trackingMode: .selectOne, target: nil, action: nil)
        openSeg.segmentStyle = .capsule
        openSeg.controlSize = .regular
        openSeg.selectedSegment = 0
        self.openSeg = openSeg
        let openCard = section(title: openHint, badge: openBadge, remain: openRemain,
                               seg: openSeg, accent: openAccent)
        self.openCard = openCard

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        let start = NSButton(title: "시작", target: self, action: #selector(startPressed))
        start.bezelStyle = .rounded
        start.setButtonType(.momentaryPushIn)
        start.keyEquivalent = "\r"
        start.widthAnchor.constraint(equalToConstant: 84).isActive = true
        self.startBtn = start
        let stop = NSButton(title: "해제", target: self, action: #selector(stopPressed))
        stop.bezelStyle = .rounded
        stop.widthAnchor.constraint(equalToConstant: 84).isActive = true
        self.stopBtn = stop
        let buttons = NSStackView(views: [start, stop])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let errorLabel = label("", size: 11, weight: .regular)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2
        errorLabel.isHidden = true
        self.errorLabel = errorLabel

        let root = NSStackView(views: [closedCard, rule, openCard, buttons, errorLabel])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.setCustomSpacing(20, after: openCard)
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false
        closedCard.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true
        openCard.widthAnchor.constraint(equalTo: closedCard.widthAnchor).isActive = true
        rule.widthAnchor.constraint(equalTo: closedCard.widthAnchor).isActive = true

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        updateButtons()
        updateStatusVisuals()
        sizeWindow(animate: false)
    }

    func sizeWindow(animate: Bool) {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var size = content.fittingSize
        size.width = 456
        size.height = max(size.height, 168)
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var win = window.frame
        win.origin.y += win.size.height - frame.size.height
        win.size = frame.size
        window.setFrame(win, display: true, animate: animate)
    }

    func restoreIfNeeded() {
        guard sleepDisabled() || caffeinateAlive() || watchdogAlive() else { return }
        isSessionActive = true
        sessionStartedAt = nowEpoch()
        needsAdmin = sleepDisabled()
        beginActivity()
        updateButtons()
        updateStatusVisuals()
    }

    func stillTimed() -> Bool {
        let now = nowEpoch()
        if openUnlimited { return true }
        if let until = closedUntil, until > now { return true }
        if let until = openUntil, until > now { return true }
        return false
    }

    func tick() {
        if isSessionActive, !isStopping {
            let alive = watchdogAlive() || sleepDisabled() || caffeinateAlive()
            let revert = readLastRevert().flatMap { $0.epoch >= sessionStartedAt ? $0 : nil }
            if !alive, let revert, revert.reason.hasPrefix("thermal") {
                endSessionState()
                lastError = nil
                infoMessage = "과열이 감지돼 자동으로 해제했습니다 · \(clockText(revert.epoch))"
                infoColor = .systemOrange
            } else if !alive, !stillTimed() {
                endSessionState()
                lastError = nil
                infoMessage = "해제됨 · 시간이 끝나 잠자기로 돌아갔습니다 · \(clockText(revert?.epoch ?? nowEpoch()))"
                infoColor = .secondaryLabelColor
            } else if !alive, stillTimed() {
                lastError = "워치독이 응답하지 않습니다 · 해제 후 다시 시작하세요"
            }
        }
        if pendingRelease != nil {
            maybePromptUpdate()
        } else if Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: lastUpdateCheckKey) > updateCheckInterval {
            checkForUpdatesIfDue()
        }
        updateStatusVisuals()
        updateButtons()
    }

    private func endSessionState() {
        isSessionActive = false
        closedUntil = nil
        openUntil = nil
        openUnlimited = false
        needsAdmin = false
        endActivity()
    }

    func updateButtons() {
        let busy = isStarting || isStopping || updateBusy
        startBtn?.isEnabled = !isSessionActive && !busy
        startBtn?.isHidden = isSessionActive
        stopBtn?.isEnabled = (isSessionActive || sleepDisabled() || caffeinateAlive()) && !busy
        closedSeg?.isEnabled = !isSessionActive && !busy
        openSeg?.isEnabled = !isSessionActive && !busy
    }

    func closedArmed() -> Bool {
        guard let until = closedUntil else { return false }
        return until > nowEpoch()
    }

    func openArmed() -> Bool {
        if openUnlimited { return true }
        guard let until = openUntil else { return false }
        return until > nowEpoch()
    }

    func paintModeCards() {
        let session = isSessionActive || isStarting || isStopping
        let closedLive = session && closedArmed()
        let openLive = session && !lidClosed() && openArmed()
        let closedRemainText = closedUntil.map { fmtDuration($0 - nowEpoch()) } ?? ""
        let openRemainText: String = {
            if openUnlimited { return "무한" }
            if let until = openUntil { return fmtDuration(until - nowEpoch()) }
            return ""
        }()

        func apply(live: Bool, armed: Bool, remain: String,
                   hint: NSTextField?, badge: NSTextField?, remainLabel: NSTextField?,
                   seg: NSSegmentedControl?, accent: NSView?,
                   liveTitle: String, idleTitle: String) {
            hint?.stringValue = live ? liveTitle : idleTitle
            hint?.font = NSFont.systemFont(ofSize: live ? 15 : 13, weight: live ? .semibold : .regular)
            hint?.textColor = live ? .labelColor : (session ? .secondaryLabelColor : .labelColor)
            remainLabel?.stringValue = remain
            remainLabel?.isHidden = !live
            seg?.isHidden = session
            accent?.isHidden = !live
            if hint === closedHint {
                closedNote?.isHidden = session
                closedLiveNote?.isHidden = !(session && armed)
            }
            if live {
                badge?.stringValue = ""
            } else if armed {
                badge?.stringValue = remain
                badge?.textColor = .secondaryLabelColor
            } else if session {
                badge?.stringValue = "끔"
                badge?.textColor = .tertiaryLabelColor
            } else {
                badge?.stringValue = ""
            }
        }

        if !session {
            apply(live: false, armed: false, remain: "",
                  hint: closedHint, badge: closedBadge, remainLabel: closedRemain,
                  seg: closedSeg, accent: closedAccent,
                  liveTitle: "뚜껑을 닫아도 켜져 있음", idleTitle: "뚜껑을 닫아도 켜 두기")
            apply(live: false, armed: false, remain: "",
                  hint: openHint, badge: openBadge, remainLabel: openRemain,
                  seg: openSeg, accent: openAccent,
                  liveTitle: "뚜껑이 열렸을 때만 켜져 있음", idleTitle: "뚜껑이 열렸을 때만 켜 두기")
            closedSeg?.isHidden = false
            openSeg?.isHidden = false
            return
        }

        apply(live: closedLive, armed: closedArmed(), remain: closedRemainText,
              hint: closedHint, badge: closedBadge, remainLabel: closedRemain,
              seg: closedSeg, accent: closedAccent,
              liveTitle: "뚜껑을 닫아도 켜져 있음", idleTitle: "뚜껑을 닫아도 켜 두기")
        apply(live: openLive, armed: openArmed(), remain: openRemainText,
              hint: openHint, badge: openBadge, remainLabel: openRemain,
              seg: openSeg, accent: openAccent,
              liveTitle: "뚜껑이 열렸을 때만 켜져 있음", idleTitle: "뚜껑이 열렸을 때만 켜 두기")
    }

    func updateStatusVisuals() {
        paintModeCards()
        if isStarting {
            errorLabel?.stringValue = lastError ?? "권한 확인 또는 워치독 시작…"
            errorLabel?.textColor = .secondaryLabelColor
            errorLabel?.isHidden = false
        } else if isStopping {
            errorLabel?.stringValue = "잠자기 설정을 되돌리는 중"
            errorLabel?.textColor = .secondaryLabelColor
            errorLabel?.isHidden = false
        } else if let lastError {
            errorLabel?.stringValue = lastError
            errorLabel?.textColor = .systemRed
            errorLabel?.isHidden = false
        } else if let infoMessage {
            errorLabel?.stringValue = infoMessage
            errorLabel?.textColor = infoColor
            errorLabel?.isHidden = false
        } else {
            errorLabel?.stringValue = ""
            errorLabel?.isHidden = true
        }
        let key = "\(isSessionActive)-\(isStarting)-\(isStopping)-\(lidClosed())-\(closedArmed())-\(openArmed())-\(errorLabel?.isHidden == true)-\(errorLabel?.stringValue.count ?? 0 > 40)"
        if key != lastLayoutKey {
            lastLayoutKey = key
            sizeWindow(animate: true)
        }
    }

    @objc func startPressed() {
        guard !isStarting, !isSessionActive, !updateBusy else { return }
        let closedIdx = max(0, closedSeg?.selectedSegment ?? 3)
        let openIdx = max(0, openSeg?.selectedSegment ?? 0)
        let closedSeconds = closedDurations[min(closedIdx, closedDurations.count - 1)]
        let openSeconds = openDurations[min(openIdx, openDurations.count - 1)]
        if closedSeconds == 0, openSeconds == 0 {
            errorLabel?.stringValue = "닫힘·열림이 모두 끔입니다 · 하나를 고르세요"
            errorLabel?.textColor = .systemRed
            return
        }
        isStarting = true
        lastError = nil
        infoMessage = nil
        sessionStartedAt = nowEpoch()
        updateButtons()
        updateStatusVisuals()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.startSession(closedSeconds: closedSeconds, openSeconds: openSeconds)
                ?? (false, "내부 오류")
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStarting = false
                if result.0 {
                    self.isSessionActive = true
                    self.lastError = nil
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
                    self.lastError = result.1
                    self.errorLabel?.stringValue = result.1
                    self.errorLabel?.textColor = .systemRed
                }
                self.updateButtons()
                self.updateStatusVisuals()
            }
        }
    }

    @objc func stopPressed() {
        guard !isStopping else { return }
        isStopping = true
        lastError = nil
        updateButtons()
        updateStatusVisuals()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.stopSession()
            let stillDisabled = sleepDisabled()
            let stillCaffeinated = caffeinateAlive()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStopping = false
                self.endSessionState()
                if stillDisabled || stillCaffeinated {
                    self.lastError = "아직 잠자기 방지가 남아 있습니다 · 해제를 다시 눌러 주세요"
                } else {
                    self.infoMessage = "해제됨 · 잠자기 설정을 원래대로 되돌렸습니다 · \(clockText(nowEpoch()))"
                    self.infoColor = .secondaryLabelColor
                }
                self.updateButtons()
                self.updateStatusVisuals()
            }
        }
    }

    private func startSession(closedSeconds: Int, openSeconds: Int) -> (Bool, String) {
        try? FileManager.default.removeItem(atPath: stopPath)
        if let helperError = installHelpers() {
            return (false, helperError)
        }
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
        // Force-quit or crash: watchdog restores sleep about a minute after the app disappears.
        args += " --require-gui"

        let launch = "/usr/bin/python3 \(daemonizeCopyPath) \(watchdogPidPath) /bin/bash \(watchdogCopyPath) \(args) >>\(watchdogLogPath) 2>&1"
        if closedSeconds > 0 {
            let script = """
            #!/bin/bash
            /usr/bin/pmset -a disablesleep 1 || exit 1
            \(launch)
            for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
              PID=$(tr -d '[:space:]' < \(watchdogPidPath) 2>/dev/null)
              if [ -n "$PID" ] && /bin/ps -p "$PID" -o pid= >/dev/null 2>&1; then
                exit 0
              fi
              sleep 0.1
            done
            /usr/bin/pmset -a disablesleep 0
            exit 1
            """
            writeFile(startScriptPath, script)
            _ = shell("chmod 755 \(startScriptPath)")
            let (ok, out) = adminShell("/bin/bash \(startScriptPath)")
            if !ok {
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.localizedCaseInsensitiveContains("User canceled")
                    || trimmed.contains("-128") {
                    return (false, "관리자 암호가 취소되었습니다")
                }
                return (false, trimmed.isEmpty ? "관리자 권한으로 워치독을 시작하지 못했습니다" : trimmed)
            }
            return (true, "")
        }

        let (status, out) = shell(launch)
        for _ in 0..<15 {
            if watchdogAlive() { return (true, "") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if watchdogAlive() { return (true, "") }
        let logTail = (try? String(contentsOfFile: watchdogLogPath, encoding: .utf8))?
            .split(separator: "\n").suffix(3).joined(separator: " · ") ?? out
        return (false, status == 0
                ? "워치독 프로세스가 살아 있지 않습니다 · \(logTail)"
                : "워치독 실행 실패 · \(logTail)")
    }

    private func stopSession() {
        writeFile(stopPath, "1\n")
        killCaffeinate()
        for _ in 0..<30 {
            if !watchdogAlive(), !sleepDisabled() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if sleepDisabled() {
            _ = adminShell("/usr/bin/pmset -a disablesleep 0; exit 0")
        }
        if watchdogAlive() {
            _ = bumpGeneration()
        }
        try? FileManager.default.removeItem(atPath: untilPath)
        try? FileManager.default.removeItem(atPath: stopPath)
    }

    // MARK: - Update

    private func checkForUpdatesIfDue() {
        let last = UserDefaults.standard.double(forKey: lastUpdateCheckKey)
        guard Date().timeIntervalSince1970 - last > updateCheckInterval else { return }
        checkForUpdates(manual: false)
    }

    @objc func checkUpdatesMenu() {
        checkForUpdates(manual: true)
    }

    private func checkForUpdates(manual: Bool) {
        guard !updateChecking, !updateBusy else { return }
        updateChecking = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastUpdateCheckKey)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = fetchLatestRelease()
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateChecking = false
                switch result {
                case .success(let release):
                    if isVersion(release.version, newerThan: currentAppVersion()) {
                        self.pendingRelease = release
                        self.maybePromptUpdate()
                    } else if manual {
                        self.simpleAlert("최신 버전입니다", "지금 쓰는 버전은 \(currentAppVersion())입니다.")
                    }
                case .failure(let error):
                    if manual {
                        self.simpleAlert("업데이트를 확인하지 못했습니다", error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Never swap the app while sleep prevention is on; wait until the session ends.
    private func maybePromptUpdate() {
        guard let release = pendingRelease, !updatePrompting, !updateBusy,
              !isSessionActive, !isStarting, !isStopping else { return }
        if UserDefaults.standard.bool(forKey: "autoInstallUpdates") {
            pendingRelease = nil
            performUpdate(release)
            return
        }
        updatePrompting = true
        let alert = NSAlert()
        alert.messageText = "새 버전 \(release.version)이 있습니다"
        alert.informativeText = "지금 버전은 \(currentAppVersion())입니다. 업데이트하면 앱이 잠깐 닫혔다가 다시 열립니다."
        alert.addButton(withTitle: "업데이트")
        alert.addButton(withTitle: "나중에")
        alert.addButton(withTitle: "변경 내용 보기")
        let response = alert.runModal()
        updatePrompting = false
        pendingRelease = nil
        switch response {
        case .alertFirstButtonReturn:
            performUpdate(release)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    private func performUpdate(_ release: ReleaseInfo) {
        updateBusy = true
        lastError = nil
        infoMessage = "\(release.version) 내려받는 중…"
        infoColor = .secondaryLabelColor
        updateButtons()
        updateStatusVisuals()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let prepared = prepareUpdate(release)
            DispatchQueue.main.async {
                guard let self else { return }
                switch prepared {
                case .success(let newApp):
                    if let error = launchInstaller(newApp: newApp) {
                        self.updateFailed(error, release: release)
                    } else {
                        self.infoMessage = "\(release.version) 설치 중 · 곧 다시 열립니다"
                        self.updateStatusVisuals()
                        NSApp.terminate(nil)
                    }
                case .failure(let error):
                    self.updateFailed(error, release: release)
                }
            }
        }
    }

    private func updateFailed(_ error: Error, release: ReleaseInfo) {
        updateBusy = false
        infoMessage = nil
        updateButtons()
        updateStatusVisuals()
        let alert = NSAlert()
        alert.messageText = "업데이트하지 못했습니다"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "릴리스 페이지 열기")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    private func simpleAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "확인")
        alert.runModal()
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
        let updateItem = NSMenuItem(title: "업데이트 확인…", action: #selector(AppDelegate.checkUpdatesMenu), keyEquivalent: "")
        updateItem.target = delegate
        appMenu.addItem(updateItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "잠자기 방지 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        app.mainMenu = menu
        app.setActivationPolicy(.regular)
        app.run()
    }
}
