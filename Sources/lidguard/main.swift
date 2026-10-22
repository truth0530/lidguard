import AppKit
import Foundation

private let stateDir = "/tmp"
private let genPath = "\(stateDir)/lidguard_gen"
private let untilPath = "\(stateDir)/lidguard_until"
private let stopPath = "\(stateDir)/lidguard_stop"
private let watchdogPidPath = "\(stateDir)/lidguard_watchdog.pid"
private let watchdogLogPath = "\(stateDir)/lidguard_watchdog.log"
private let startScriptPath = "\(stateDir)/lidguard_start.sh"
private let heartbeatPath = "\(stateDir)/lidguard_heartbeat"
private let uiStatePath = "\(stateDir)/lidguard_ui"
private let lastRevertPath = "\(stateDir)/lidguard_last_revert"
private let lastUpdateCheckKey = "lastUpdateCheck"
private let acOnlyKey = "acOnly"
private let updateCheckInterval: TimeInterval = 24 * 60 * 60

private let closedDurations: [Int] = [0, 15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60]
private let closedLabels = ["끔", "15분", "30분", "1시간", "2시간", "4시간"]
/// The 7th closed-lid segment: 무한 with 전원 연결 시만 (unplugging always ends it),
/// otherwise 6시간. The segment count never changes.
private let closedUnlimitedLabel = "무한"
private let closedLongLabel = "6시간"
private let closedLongSeconds = 6 * 60 * 60
private let openDurations: [Int] = [0, 15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60, -1]
private let openLabels = ["끔", "15분", "30분", "1시간", "2시간", "4시간", "무한"]

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func appleQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

@discardableResult
private func adminShell(_ command: String) -> (Bool, String) {
    let result = runTool("/usr/bin/osascript", ["-e", "do shell script \(appleQuote(command)) with administrator privileges"])
    return (result.status == 0, result.output)
}

/// Closed-lid watchdog liveness: pid check (EPERM = alive root process) or a fresh heartbeat.
private func watchdogAlive() -> Bool {
    if let pid = readPidFile(watchdogPidPath), pidAlive(pid) { return true }
    guard let raw = try? String(contentsOfFile: heartbeatPath, encoding: .utf8),
          let ts = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return false
    }
    return nowEpoch() - ts < 8
}

private func watchdogPidAlive() -> Bool {
    guard let pid = readPidFile(watchdogPidPath) else { return false }
    return pidAlive(pid)
}

private func lidClosed() -> Bool { readLidState() == .closed }

private func fmtDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    if h > 0 { return String(format: "%d시간 %d분 %02d초", h, m, sec) }
    if m > 0 { return String(format: "%d분 %02d초", m, sec) }
    return String(format: "%d초", sec)
}

private func bumpGeneration() -> Int {
    let current = Int((try? String(contentsOfFile: genPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    let next = current + 1
    writeText(genPath, "\(next)\n")
    chmod(genPath, 0o666)
    return next
}

/// Watchdog writes `<epoch> <reason>` whenever it restores sleep.
private func readLastRevert() -> (epoch: Int, reason: String)? {
    guard let raw = try? String(contentsOfFile: lastRevertPath, encoding: .utf8) else { return nil }
    let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
    guard parts.count == 2, let epoch = Int(parts[0]) else { return nil }
    return (epoch, String(parts[1]))
}

/// closed_until from the running watchdog, so a relaunched app can show the countdown.
private func readWatchdogClosedUntil() -> Int? {
    guard let raw = try? String(contentsOfFile: uiStatePath, encoding: .utf8) else { return nil }
    for line in raw.split(separator: "\n") where line.hasPrefix("closed_until=") {
        return Int(line.dropFirst("closed_until=".count)).flatMap { $0 > 0 ? $0 : nil }
    }
    return nil
}

private func readWatchdogFlag(_ line: String) -> Bool {
    guard let raw = try? String(contentsOfFile: uiStatePath, encoding: .utf8) else { return false }
    return raw.split(separator: "\n").contains(Substring(line))
}

/// Status line for a watchdog revert reason.
private func revertMessage(_ reason: String, at epoch: Int) -> (String, NSColor) {
    if reason.hasPrefix("thermal") {
        return ("과열이 감지돼 자동으로 해제했습니다 · \(clockText(epoch))", .systemOrange)
    }
    if reason.hasPrefix("battery-low") {
        return ("배터리 \(lowBatteryPercent)% 이하라 자동으로 해제했습니다 · \(clockText(epoch))", .systemOrange)
    }
    return ("해제됨 · 시간이 끝나 잠자기로 돌아갔습니다 · \(clockText(epoch))", .secondaryLabelColor)
}

private let clockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.dateFormat = "a h:mm"
    return formatter
}()

private func clockText(_ epoch: Int) -> String {
    clockFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
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
    var acOnlyCheck: NSButton?
    var startBtn: NSButton?
    var stopBtn: NSButton?
    var errorLabel: NSTextField?
    var timer: Timer?
    /// Closed-lid timer: root watchdog owns `pmset disablesleep`.
    private var closedRunning = false
    /// Open-lid timer: an in-process IOPM assertion, no helper process.
    private let openAssertion = IdleSleepAssertion()
    /// Open-lid timer is logically on; the assertion may be released while paused on battery.
    private var openRunning = false
    /// 전원 연결 중일 때만, fixed for the running session.
    private var sessionACOnly = false
    private var isStarting = false
    private var isStopping = false
    private var closedUntil: Int?
    private var closedUnlimited = false
    private var openUntil: Int?
    private var openUnlimited = false
    /// `SleepDisabled` left on with no watchdog (seen at launch or after a failed 해제).
    private var leftoverSleepDisabled = false
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

    private var isSessionActive: Bool { closedRunning || openRunning }

    /// Session is on but holding nothing because the Mac runs on battery.
    private var pausedForBattery: Bool {
        isSessionActive && sessionACOnly && !onACPower()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildUI()
        restoreIfNeeded()
        checkForUpdatesIfDue()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Lets macOS coalesce wakeups with other timers.
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowVisibilityChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        openRunning = false
        openAssertion.release()
        if closedRunning || leftoverSleepDisabled || watchdogPidAlive() {
            stopClosedSession()
            closedRunning = false
        }
        endActivity()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        openAssertion.release()
        endActivity()
        timer?.invalidate()
    }

    private var windowVisible: Bool {
        window?.occlusionState.contains(.visible) == true
    }

    @objc private func windowVisibilityChanged() {
        if windowVisible {
            updateStatusVisuals()
            updateButtons()
        }
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
            // Title pinned left; an explicit spacer absorbs the free width so the
            // title never drifts when the badge or font size changes.
            let fill = NSView()
            fill.setContentHuggingPriority(.defaultLow, for: .horizontal)
            fill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [accent, title, fill, badge])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            title.alignment = .left
            title.setContentHuggingPriority(.required, for: .horizontal)
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
        let startsACOnly = UserDefaults.standard.bool(forKey: acOnlyKey)
        let closedSeg = NSSegmentedControl(labels: closedLabels + [startsACOnly ? closedUnlimitedLabel : closedLongLabel],
                                           trackingMode: .selectOne, target: nil, action: nil)
        closedSeg.segmentStyle = .capsule
        closedSeg.controlSize = .regular
        closedSeg.selectedSegment = 3
        closedSeg.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.closedSeg = closedSeg
        let closedNote = label("화면 자동꺼짐도 함께 막힙니다", size: 11, weight: .regular)
        closedNote.textColor = .secondaryLabelColor
        self.closedNote = closedNote
        let closedLiveNote = label("타이머가 끝나거나 과열되면 잠자기로 돌아갑니다.", size: 11, weight: .regular)
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

        // Its own row above both sections, right-aligned. Stays visible (disabled)
        // during a session so the layout never shifts.
        let acOnly = NSButton(checkboxWithTitle: "전원 연결 시만", target: self, action: #selector(acOnlyChanged))
        acOnly.controlSize = .small
        acOnly.font = NSFont.systemFont(ofSize: 11)
        acOnly.state = startsACOnly ? .on : .off
        acOnly.toolTip = "배터리로 바뀌면 멈춥니다. 켜면 6시간 대신 무한을 고를 수 있습니다."
        acOnly.setContentHuggingPriority(.required, for: .horizontal)
        acOnly.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.acOnlyCheck = acOnly
        let topFill = NSView()
        topFill.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topFill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topBar = NSStackView(views: [topFill, acOnly])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 0

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
        // Version at the right end of the button row, so it is clear which copy is running.
        let version = NSTextField(labelWithString: "v\(currentAppVersion())")
        version.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        version.textColor = .tertiaryLabelColor
        version.alignment = .right
        version.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [start, stop, spacer, version])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let errorLabel = label("", size: 11, weight: .regular)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2
        errorLabel.isHidden = true
        self.errorLabel = errorLabel

        let root = NSStackView(views: [topBar, closedCard, rule, openCard, buttons, errorLabel])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.setCustomSpacing(6, after: topBar)
        root.setCustomSpacing(20, after: openCard)
        root.setCustomSpacing(8, after: buttons)
        root.edgeInsets = NSEdgeInsets(top: 10, left: 22, bottom: 14, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false
        closedCard.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true
        openCard.widthAnchor.constraint(equalTo: closedCard.widthAnchor).isActive = true
        rule.widthAnchor.constraint(equalTo: closedCard.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: closedCard.widthAnchor).isActive = true
        errorLabel.widthAnchor.constraint(equalTo: closedCard.widthAnchor).isActive = true
        topBar.widthAnchor.constraint(equalTo: closedCard.widthAnchor).isActive = true

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
        if watchdogAlive() {
            closedRunning = true
            closedUntil = readWatchdogClosedUntil()
            closedUnlimited = readWatchdogFlag("closed_unlimited=1")
            sessionACOnly = readWatchdogFlag("ac_only=1")
            // Show the running session's setting on the (disabled) checkbox.
            acOnlyCheck?.state = sessionACOnly ? .on : .off
            acOnlyChanged()
            sessionStartedAt = nowEpoch()
            beginActivity()
        } else if pmsetSleepDisabled() {
            leftoverSleepDisabled = true
            lastError = "이전 잠자기 방지 설정이 남아 있습니다 · 해제를 눌러 되돌리세요"
        }
        updateButtons()
        updateStatusVisuals()
    }

    /// Everything here is native (IOKit, kill(2), file reads): no process is spawned per second.
    func tick() {
        let now = nowEpoch()
        if openRunning, !isStopping {
            let safetyReason: String? = thermalSerious() ? "thermal" : (batteryLow() ? "battery-low" : nil)
            if let safetyReason {
                openRunning = false
                openAssertion.release()
                openUntil = nil
                openUnlimited = false
                if !closedRunning {
                    let (message, color) = revertMessage(safetyReason, at: now)
                    infoMessage = message
                    infoColor = color
                }
            } else if !openUnlimited, let until = openUntil, now >= until {
                openRunning = false
                openAssertion.release()
                openUntil = nil
                if !closedRunning {
                    infoMessage = "해제됨 · 시간이 끝나 잠자기로 돌아갔습니다 · \(clockText(now))"
                    infoColor = .secondaryLabelColor
                }
            } else {
                let allowed = !sessionACOnly || onACPower()
                if allowed, !openAssertion.isHeld {
                    openAssertion.hold(reason: "잠자기 방지: 뚜껑이 열렸을 때만 켜 두기")
                } else if !allowed, openAssertion.isHeld {
                    openAssertion.release()
                }
            }
        }
        if closedRunning, !isStopping, !watchdogAlive() {
            closedRunning = false
            let revert = readLastRevert().flatMap { $0.epoch >= sessionStartedAt ? $0 : nil }
            let wasUnlimited = closedUnlimited
            closedUnlimited = false
            if let revert, revert.reason.hasPrefix("thermal") || revert.reason.hasPrefix("battery-low") {
                // Safety reverts end the whole session, open-lid timer included.
                openRunning = false
                openAssertion.release()
                openUntil = nil
                openUnlimited = false
                closedUntil = nil
                lastError = nil
                let (message, color) = revertMessage(revert.reason, at: revert.epoch)
                infoMessage = message
                infoColor = color
            } else if revert != nil || (!wasUnlimited && (closedUntil.map { now >= $0 } ?? true)) {
                closedUntil = nil
                lastError = nil
                if !openRunning {
                    let (message, color) = revertMessage(revert?.reason ?? "deadline", at: revert?.epoch ?? now)
                    infoMessage = message
                    infoColor = color
                }
            } else {
                closedUntil = nil
                leftoverSleepDisabled = true
                lastError = "워치독이 응답하지 않습니다 · 해제를 눌러 잠자기 설정을 되돌리세요"
            }
        }
        if !isSessionActive {
            endActivity()
        }
        if pendingRelease != nil {
            maybePromptUpdate()
        } else if Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: lastUpdateCheckKey) > updateCheckInterval {
            checkForUpdatesIfDue()
        }
        // Hidden or covered window: skip drawing and layout entirely.
        guard windowVisible else { return }
        updateStatusVisuals()
        updateButtons()
    }

    func updateButtons() {
        let busy = isStarting || isStopping || updateBusy
        startBtn?.isEnabled = !isSessionActive && !busy
        startBtn?.isHidden = isSessionActive
        stopBtn?.isEnabled = (isSessionActive || leftoverSleepDisabled) && !busy
        closedSeg?.isEnabled = !isSessionActive && !busy
        openSeg?.isEnabled = !isSessionActive && !busy
        acOnlyCheck?.isEnabled = !isSessionActive && !busy
    }

    func closedArmed() -> Bool {
        guard closedRunning else { return false }
        if closedUnlimited { return true }
        guard let until = closedUntil else { return true }
        return until > nowEpoch()
    }

    /// 전원 연결 시만 relabels the last closed-lid segment: 무한 ↔ 6시간. Same count, same selection.
    @objc func acOnlyChanged() {
        let on = acOnlyCheck?.state == .on
        UserDefaults.standard.set(on, forKey: acOnlyKey)
        closedSeg?.setLabel(on ? closedUnlimitedLabel : closedLongLabel, forSegment: closedLabels.count)
    }

    func openArmed() -> Bool {
        guard openRunning else { return false }
        if openUnlimited { return true }
        guard let until = openUntil else { return false }
        return until > nowEpoch()
    }

    func paintModeCards() {
        let session = isSessionActive || isStarting || isStopping
        let lidIsClosed = lidClosed()
        let paused = pausedForBattery
        let closedLive = session && closedArmed() && !paused
        let openLive = session && !lidIsClosed && openArmed() && !paused
        let closedRemainText = closedUnlimited ? "무한" : (closedUntil.map { fmtDuration($0 - nowEpoch()) } ?? "")
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
        } else if pausedForBattery {
            errorLabel?.stringValue = "배터리 사용 중 · 전원을 연결하면 다시 켜집니다"
            errorLabel?.textColor = .systemOrange
            errorLabel?.isHidden = false
        } else if let infoMessage {
            errorLabel?.stringValue = infoMessage
            errorLabel?.textColor = infoColor
            errorLabel?.isHidden = false
        } else {
            // Keep one empty line reserved so the window does not jump when a status appears.
            errorLabel?.stringValue = " "
            errorLabel?.isHidden = false
        }
        let key = "\(pausedForBattery)-\(isSessionActive)-\(isStarting)-\(isStopping)-\(lidClosed())-\(closedArmed())-\(openArmed())-\(errorLabel?.isHidden == true)-\(errorLabel?.stringValue.count ?? 0 > 40)"
        if key != lastLayoutKey {
            lastLayoutKey = key
            sizeWindow(animate: true)
        }
    }

    @objc func startPressed() {
        guard !isStarting, !isSessionActive, !updateBusy else { return }
        let closedIdx = max(0, closedSeg?.selectedSegment ?? 3)
        let openIdx = max(0, openSeg?.selectedSegment ?? 0)
        // The last segment is 무한 (-1) with 전원 연결 시만, otherwise 6시간.
        let acOnlyNow = acOnlyCheck?.state == .on
        let closedSeconds = closedIdx < closedDurations.count ? closedDurations[closedIdx] : (acOnlyNow ? -1 : closedLongSeconds)
        let openSeconds = openDurations[min(openIdx, openDurations.count - 1)]
        if closedSeconds == 0, openSeconds == 0 {
            errorLabel?.stringValue = "닫힘·열림이 모두 끔입니다 · 하나를 고르세요"
            errorLabel?.textColor = .systemRed
            errorLabel?.isHidden = false
            return
        }
        lastError = nil
        infoMessage = nil
        sessionStartedAt = nowEpoch()
        sessionACOnly = acOnlyCheck?.state == .on
        UserDefaults.standard.set(sessionACOnly, forKey: acOnlyKey)

        guard closedSeconds != 0 else {
            startOpen(openSeconds)
            updateButtons()
            updateStatusVisuals()
            return
        }

        isStarting = true
        updateButtons()
        updateStatusVisuals()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.startClosedSession(closedSeconds: closedSeconds) ?? (false, "내부 오류")
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStarting = false
                if result.0 {
                    self.closedRunning = true
                    self.leftoverSleepDisabled = false
                    self.closedUnlimited = closedSeconds < 0
                    self.closedUntil = closedSeconds > 0 ? nowEpoch() + closedSeconds : nil
                    self.startOpen(openSeconds)
                    self.beginActivity()
                } else {
                    self.lastError = result.1
                }
                self.updateButtons()
                self.updateStatusVisuals()
            }
        }
    }

    private func startOpen(_ openSeconds: Int) {
        guard openSeconds != 0 else {
            openUntil = nil
            openUnlimited = false
            return
        }
        if !sessionACOnly || onACPower() {
            guard openAssertion.hold(reason: "잠자기 방지: 뚜껑이 열렸을 때만 켜 두기") else {
                lastError = "잠자기 방지 요청을 만들지 못했습니다"
                return
            }
        }
        openRunning = true
        openUnlimited = openSeconds < 0
        openUntil = openSeconds > 0 ? nowEpoch() + openSeconds : nil
        beginActivity()
    }

    @objc func stopPressed() {
        guard !isStopping else { return }
        isStopping = true
        lastError = nil
        openRunning = false
        openAssertion.release()
        openUntil = nil
        openUnlimited = false
        let needsClosedStop = closedRunning || leftoverSleepDisabled || watchdogPidAlive()
        updateButtons()
        updateStatusVisuals()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var stillDisabled = false
            if needsClosedStop {
                self?.stopClosedSession()
                stillDisabled = pmsetSleepDisabled()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStopping = false
                self.closedRunning = false
                self.closedUntil = nil
                self.closedUnlimited = false
                self.endActivity()
                if stillDisabled {
                    self.leftoverSleepDisabled = true
                    self.lastError = "아직 잠자기 방지가 남아 있습니다 · 해제를 다시 눌러 주세요"
                } else {
                    self.leftoverSleepDisabled = false
                    self.infoMessage = "해제됨 · 잠자기 설정을 원래대로 되돌렸습니다 · \(clockText(nowEpoch()))"
                    self.infoColor = .secondaryLabelColor
                }
                self.updateButtons()
                self.updateStatusVisuals()
            }
        }
    }

    private func startClosedSession(closedSeconds: Int) -> (Bool, String) {
        guard let exe = Bundle.main.executablePath else { return (false, "앱 실행 파일 경로를 찾지 못했습니다") }
        unlink(stopPath)
        let gen = bumpGeneration()
        // closedSeconds < 0 is 무한: no deadline, only 전원 연결·과열·배터리·해제 end it.
        let unlimited = closedSeconds < 0
        let until = unlimited ? 0 : nowEpoch() + closedSeconds
        if unlimited {
            unlink(untilPath)
        } else {
            writeText(untilPath, "\(until)\n")
        }

        // pmset first: Clamshell Sleep is synchronous, so disablesleep must be on
        // before the watchdog's first poll. Roll back if the watchdog never starts.
        let launch = [
            shellQuote(exe), "--watchdog", "--daemonize",
            "--gen", "\(gen)", "--closed-until", "\(until)", "--sleepnow-if-closed",
            "--gui-pid", "\(getpid())", "--pidfile", watchdogPidPath
        ].joined(separator: " ") + (sessionACOnly ? " --ac-only" : "") + (unlimited ? " --closed-unlimited" : "")
        // On battery with 전원 연결 중일 때만, start paused: the watchdog arms on AC.
        let armNow = !sessionACOnly || onACPower()
        let script = """
        #!/bin/bash
        /bin/rm -f \(watchdogPidPath)
        \(armNow ? "/usr/bin/pmset -a disablesleep 1 || exit 1" : ": paused on battery")
        \(launch) >>\(watchdogLogPath) 2>&1
        for i in $(/usr/bin/seq 1 30); do
          PID=$(/usr/bin/tr -d '[:space:]' < \(watchdogPidPath) 2>/dev/null)
          if [ -n "$PID" ] && /bin/kill -0 "$PID" 2>/dev/null; then
            exit 0
          fi
          /bin/sleep 0.1
        done
        /usr/bin/pmset -a disablesleep 0
        echo "워치독이 시작되지 않았습니다"
        exit 1
        """
        writeText(startScriptPath, script)
        chmod(startScriptPath, 0o755)
        let (ok, out) = adminShell("/bin/bash \(startScriptPath)")
        if !ok {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.localizedCaseInsensitiveContains("User canceled") || trimmed.contains("-128") {
                return (false, "관리자 암호가 취소되었습니다")
            }
            return (false, trimmed.isEmpty ? "관리자 권한으로 워치독을 시작하지 못했습니다" : trimmed)
        }
        return (true, "")
    }

    /// The watchdog polls every 2 s, so the stop file normally lands within that window.
    private func stopClosedSession() {
        writeText(stopPath, "1\n")
        for _ in 0..<40 {
            if !watchdogPidAlive() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if watchdogPidAlive() {
            _ = bumpGeneration()
        }
        if pmsetSleepDisabled() {
            _ = adminShell("/usr/bin/pmset -a disablesleep 0; exit 0")
        }
        unlink(untilPath)
        unlink(stopPath)
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
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--watchdog" {
            exit(Watchdog.main(args))
        }
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
