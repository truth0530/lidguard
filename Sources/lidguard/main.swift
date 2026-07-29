import AppKit
import Foundation

// MARK: - Shell helpers

@discardableResult
func shell(_ command: String) -> (Int32, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-c", command]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return (1, error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: data, encoding: .utf8) ?? ""
    return (task.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Run shell with administrator privileges via osascript (password dialog).
@discardableResult
func adminShell(_ command: String) -> Bool {
    let escaped = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "do shell script \"\(escaped)\" with administrator privileges"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return false
    }
}

func sleepDisabled() -> Bool {
    let (_, out) = shell("pmset -g | awk '/SleepDisabled/{print $2}'")
    return out == "1"
}

func caffeinateAlive() -> Bool {
    let (code, _) = shell(
        "test -f /tmp/lidguard_caffeinate.pid && kill -0 $(cat /tmp/lidguard_caffeinate.pid) 2>/dev/null"
    )
    return code == 0
}

func remainingSeconds() -> Int? {
    let (_, out) = shell("cat /tmp/lidguard_until 2>/dev/null")
    guard let until = Int(out), until > 0 else { return nil }
    let left = until - Int(Date().timeIntervalSince1970)
    return left > 0 ? left : 0
}

func fmtDuration(_ total: Int) -> String {
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d시간 %02d분 %02d초", h, m, s)
    }
    return String(format: "%02d분 %02d초", m, s)
}

// MARK: - UI phase

enum AppPhase {
    case idle       // 작동 준비
    case starting   // 시작 처리 중 (암호 입력 등)
    case running    // 작동 중
    case stopping   // 해제 처리 중
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    /// 큰 상태 배지: 준비 중 / 작동 중
    let phaseBadge = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let countdownLabel = NSTextField(labelWithString: "")
    var statusBox: NSView!

    var radioClosed: NSButton!
    var radioOpen: NSButton!
    var seg: NSSegmentedControl!
    var startBtn: NSButton!
    var stopBtn: NSButton!

    /// Duration options in seconds.
    let durations: [Int] = [
        30 * 60,
        60 * 60,
        2 * 60 * 60,
        4 * 60 * 60,
        8 * 60 * 60,
        0,
    ]
    var timer: Timer?

    /// UI-driven session phase (버튼 상호 작용의 정본).
    private var phase: AppPhase = .idle
    /// 뚜껑 닫힘 모드로 켠 세션인지 (해제 시 admin 여부).
    private var sessionClosedMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        // 이전 세션이 살아 있으면 작동 중으로 복원
        if sleepDisabled() || caffeinateAlive() {
            phase = .running
            sessionClosedMode = sleepDisabled()
        }
        applyPhaseUI()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: UI builders

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func makeStatusBox() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.masksToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false

        phaseBadge.font = .systemFont(ofSize: 12, weight: .bold)
        phaseBadge.alignment = .center
        phaseBadge.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        countdownLabel.alignment = .center
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [phaseBadge, statusLabel, countdownLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
        ])
        return box
    }

    func buildUI() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "잠자기 방지")
        title.font = .systemFont(ofSize: 18, weight: .bold)

        statusBox = makeStatusBox()

        let modeHeader = sectionLabel("모드")
        radioClosed = NSButton(
            radioButtonWithTitle: "뚜껑을 닫아도 깨어 있기  (관리자 암호 필요)",
            target: self,
            action: #selector(modeChanged(_:))
        )
        radioOpen = NSButton(
            radioButtonWithTitle: "뚜껑을 열어둘 때만 깨어 있기",
            target: self,
            action: #selector(modeChanged(_:))
        )
        radioOpen.state = .on

        let durHeader = sectionLabel("유지 시간  ·  지나면 자동 해제")
        let labels = durations.map { sec -> String in
            if sec == 0 { return "무제한" }
            if sec < 3600 { return "\(sec / 60)분" }
            return "\(sec / 3600)시간"
        }
        seg = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        seg.segmentStyle = .rounded
        seg.selectedSegment = 1
        for i in 0..<labels.count {
            seg.setWidth(58, forSegment: i)
        }

        startBtn = NSButton(title: "시작", target: self, action: #selector(startPressed))
        startBtn.bezelStyle = .rounded
        startBtn.controlSize = .large
        if #available(macOS 11.0, *) {
            startBtn.hasDestructiveAction = false
        }

        stopBtn = NSButton(title: "해제", target: self, action: #selector(stopPressed))
        stopBtn.bezelStyle = .rounded
        stopBtn.controlSize = .large

        let btnRow = NSStackView(views: [startBtn, stopBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 12
        btnRow.distribution = .fillEqually
        btnRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            title,
            statusBox,
            separator(),
            modeHeader,
            radioClosed,
            radioOpen,
            separator(),
            durHeader,
            seg,
            btnRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12, after: statusBox)
        stack.setCustomSpacing(14, after: radioOpen)
        stack.setCustomSpacing(16, after: seg)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            statusBox.widthAnchor.constraint(equalToConstant: 380),
            seg.widthAnchor.constraint(equalToConstant: 380),
            btnRow.widthAnchor.constraint(equalToConstant: 380),
            startBtn.heightAnchor.constraint(equalToConstant: 36),
            stopBtn.heightAnchor.constraint(equalToConstant: 36),
        ])

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "잠자기 방지"
        win.contentView = content
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        window = win

        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func modeChanged(_ sender: NSButton) {
        if sender === radioClosed {
            radioClosed.state = .on
            radioOpen.state = .off
        } else {
            radioOpen.state = .on
            radioClosed.state = .off
        }
    }

    // MARK: Phase UI (버튼·배지 정본)

    /// 시작/해제 버튼 · 배지 · 입력 잠금을 phase 기준으로 즉시 반영.
    func applyPhaseUI() {
        switch phase {
        case .idle:
            phaseBadge.stringValue = "●  작동 준비"
            phaseBadge.textColor = NSColor.secondaryLabelColor
            statusBox.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            statusBox.layer?.borderWidth = 1
            statusBox.layer?.borderColor = NSColor.separatorColor.cgColor

            startBtn.isEnabled = true
            startBtn.title = "시작"
            startBtn.keyEquivalent = "\r"
            if #available(macOS 11.0, *) {
                startBtn.bezelColor = NSColor.controlAccentColor
            }

            stopBtn.isEnabled = false
            stopBtn.title = "해제"
            stopBtn.keyEquivalent = ""
            if #available(macOS 11.0, *) {
                stopBtn.bezelColor = nil
            }

            radioClosed.isEnabled = true
            radioOpen.isEnabled = true
            seg.isEnabled = true

        case .starting:
            phaseBadge.stringValue = "…  시작 중"
            phaseBadge.textColor = NSColor.systemBlue
            statusBox.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.10).cgColor
            statusBox.layer?.borderWidth = 1
            statusBox.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor

            startBtn.isEnabled = false
            startBtn.title = "시작 중…"
            startBtn.keyEquivalent = ""
            stopBtn.isEnabled = false
            stopBtn.title = "해제"
            stopBtn.keyEquivalent = ""

            radioClosed.isEnabled = false
            radioOpen.isEnabled = false
            seg.isEnabled = false

        case .running:
            let closed = sessionClosedMode || sleepDisabled()
            phaseBadge.stringValue = closed ? "●  작동 중 · 뚜껑 닫아도 OK" : "●  작동 중"
            phaseBadge.textColor = closed ? NSColor.systemOrange : NSColor.systemGreen
            let tint = closed ? NSColor.systemOrange : NSColor.systemGreen
            statusBox.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
            statusBox.layer?.borderWidth = 1.5
            statusBox.layer?.borderColor = tint.withAlphaComponent(0.55).cgColor

            startBtn.isEnabled = false
            startBtn.title = "시작"
            startBtn.keyEquivalent = ""
            if #available(macOS 11.0, *) {
                startBtn.bezelColor = nil
            }

            stopBtn.isEnabled = true
            stopBtn.title = "해제"
            stopBtn.keyEquivalent = "\r" // Enter = 해제
            if #available(macOS 11.0, *) {
                stopBtn.bezelColor = NSColor.systemRed
            }

            radioClosed.isEnabled = false
            radioOpen.isEnabled = false
            seg.isEnabled = false

        case .stopping:
            phaseBadge.stringValue = "…  해제 중"
            phaseBadge.textColor = NSColor.systemRed
            statusBox.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
            statusBox.layer?.borderWidth = 1
            statusBox.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.35).cgColor

            startBtn.isEnabled = false
            stopBtn.isEnabled = false
            stopBtn.title = "해제 중…"
            stopBtn.keyEquivalent = ""

            radioClosed.isEnabled = false
            radioOpen.isEnabled = false
            seg.isEnabled = false
        }
    }

    // MARK: Poll

    func refresh() {
        let disabled = sleepDisabled()
        let caff = caffeinateAlive()
        let systemActive = disabled || caff
        let rem = remainingSeconds()

        // 시스템이 꺼졌는데 UI만 running이면 idle로 복귀 (타이머 만료 등)
        if phase == .running && !systemActive {
            // until 파일이 남아 있으면 만료 직후일 수 있음
            if rem == nil || rem == 0 {
                phase = .idle
                sessionClosedMode = false
                applyPhaseUI()
            }
        }
        // 앱 재실행 등으로 시스템만 살아 있으면 running으로
        if phase == .idle && systemActive {
            phase = .running
            sessionClosedMode = disabled
            applyPhaseUI()
        }

        // 상태 문구 + 카운트다운
        switch phase {
        case .idle:
            statusLabel.stringValue = "평소처럼 잠자기 · 시작을 누르면 잠자기 방지"
            statusLabel.textColor = .secondaryLabelColor
            countdownLabel.stringValue = "—"
            countdownLabel.textColor = .tertiaryLabelColor

        case .starting:
            statusLabel.stringValue = sessionClosedMode
                ? "관리자 암호 확인 후 적용합니다…"
                : "잠자기 방지를 켜는 중…"
            statusLabel.textColor = .systemBlue
            countdownLabel.stringValue = "…"
            countdownLabel.textColor = .systemBlue

        case .running:
            if disabled || sessionClosedMode {
                statusLabel.stringValue = "뚜껑을 닫아도 깨어 있음"
                statusLabel.textColor = .systemOrange
            } else {
                statusLabel.stringValue = "뚜껑을 열어둘 때만 깨어 있음"
                statusLabel.textColor = .systemGreen
            }
            if let rem, rem > 0 {
                countdownLabel.stringValue = fmtDuration(rem)
                countdownLabel.textColor = .labelColor
            } else {
                countdownLabel.stringValue = "무제한"
                countdownLabel.textColor = .labelColor
            }

        case .stopping:
            statusLabel.stringValue = "잠자기 방지를 끄는 중…"
            statusLabel.textColor = .systemRed
            countdownLabel.stringValue = "…"
            countdownLabel.textColor = .systemRed
        }

        // phase 버튼 상태는 starting/stopping 중에는 applyPhaseUI가 유지.
        // running/idle 은 위에서 동기화했을 수 있으므로 버튼만 한 번 더 맞춤.
        if phase == .idle || phase == .running {
            applyPhaseUI()
        }
    }

    func bumpGeneration() -> Int {
        let (_, out) = shell(
            #"G=$(( $(cat /tmp/lidguard_gen 2>/dev/null || echo 0) + 1 )); echo $G > /tmp/lidguard_gen; echo $G"#
        )
        return Int(out) ?? 1
    }

    // MARK: Actions

    @objc func startPressed() {
        guard phase == .idle else { return }

        let idx = max(0, seg.selectedSegment)
        let seconds = durations[min(idx, durations.count - 1)]
        let closedMode = radioClosed.state == .on
        sessionClosedMode = closedMode

        // 즉시 UI 전환: 시작 비활성 · 상태 = 시작 중
        phase = .starting
        applyPhaseUI()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = shell(
                "test -f /tmp/lidguard_caffeinate.pid && kill $(cat /tmp/lidguard_caffeinate.pid) 2>/dev/null; rm -f /tmp/lidguard_caffeinate.pid /tmp/lidguard_until /tmp/lidguard_revert.sh"
            )

            var ok = true
            if closedMode {
                let gen = self.bumpGeneration()
                if seconds > 0 {
                    let full =
                        "/usr/bin/pmset -a disablesleep 1; " +
                        "echo $(( $(date +%s) + \(seconds) )) > /tmp/lidguard_until; " +
                        "( sleep \(seconds); " +
                        "[ \"$(cat /tmp/lidguard_gen 2>/dev/null)\" = \"\(gen)\" ] && " +
                        "{ /usr/bin/pmset -a disablesleep 0; rm -f /tmp/lidguard_until; }; " +
                        ") >/dev/null 2>&1 &"
                    ok = adminShell(full)
                } else {
                    ok = adminShell("/usr/bin/pmset -a disablesleep 1; rm -f /tmp/lidguard_until")
                }
            } else {
                if seconds > 0 {
                    let (code, _) = shell(
                        "nohup /usr/bin/caffeinate -i -t \(seconds) >/dev/null 2>&1 & echo $! > /tmp/lidguard_caffeinate.pid; echo $(( $(date +%s) + \(seconds) )) > /tmp/lidguard_until"
                    )
                    ok = code == 0 && caffeinateAlive()
                } else {
                    let (code, _) = shell(
                        "nohup /usr/bin/caffeinate -i >/dev/null 2>&1 & echo $! > /tmp/lidguard_caffeinate.pid; rm -f /tmp/lidguard_until"
                    )
                    ok = code == 0 && caffeinateAlive()
                }
            }

            DispatchQueue.main.async {
                if ok {
                    self.phase = .running
                } else {
                    // 암호 취소 등 실패 → 준비 상태로 복귀
                    self.phase = .idle
                    self.sessionClosedMode = false
                    _ = shell("rm -f /tmp/lidguard_until /tmp/lidguard_caffeinate.pid")
                }
                self.applyPhaseUI()
                self.refresh()
            }
        }
    }

    @objc func stopPressed() {
        guard phase == .running else { return }

        phase = .stopping
        applyPhaseUI()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = self.bumpGeneration()
            _ = shell(
                "test -f /tmp/lidguard_caffeinate.pid && kill $(cat /tmp/lidguard_caffeinate.pid) 2>/dev/null; rm -f /tmp/lidguard_caffeinate.pid /tmp/lidguard_until /tmp/lidguard_revert.sh"
            )
            if sleepDisabled() || self.sessionClosedMode {
                _ = adminShell("/usr/bin/pmset -a disablesleep 0; rm -f /tmp/lidguard_until; exit 0")
            } else {
                _ = shell("rm -f /tmp/lidguard_until")
            }
            DispatchQueue.main.async {
                self.phase = .idle
                self.sessionClosedMode = false
                self.applyPhaseUI()
                self.refresh()
            }
        }
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(
    withTitle: "잠자기 방지 종료",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
)
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.setActivationPolicy(.regular)
app.run()
