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

func readUntilEpoch() -> Int? {
    let (_, out) = shell("cat /tmp/lidguard_until 2>/dev/null")
    guard let until = Int(out), until > 0 else { return nil }
    return until
}

func fmtDuration(_ total: Int) -> String {
    let t = max(0, total)
    let h = t / 3600
    let m = (t % 3600) / 60
    let s = t % 60
    if h > 0 {
        return String(format: "%d시간 %02d분 %02d초", h, m, s)
    }
    return String(format: "%02d분 %02d초", m, s)
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    let phaseBadge = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let countdownLabel = NSTextField(labelWithString: "")
    var statusBox: NSView!

    var radioClosed: NSButton!
    var radioOpen: NSButton!
    var seg: NSSegmentedControl!
    var startBtn: NSButton!
    var stopBtn: NSButton!

    let durations: [Int] = [
        30 * 60,
        60 * 60,
        2 * 60 * 60,
        4 * 60 * 60,
        8 * 60 * 60,
        0,
    ]
    var timer: Timer?

    // MARK: Session state (버튼 상호 작용의 유일한 정본)

    /// true 이면 시작 비활성 · 해제 활성. 시작 클릭 즉시 true.
    private var isSessionActive = false
    /// 백그라운드 시작/해제 작업 중 (연속 클릭 방지). 해제 버튼은 active면 유지.
    private var isBusy = false
    private var sessionClosedMode = false
    /// 로컬 만료 시각 (시스템 파일보다 UI 카운트다운 우선)
    private var localUntilEpoch: Int?
    /// 무제한 세션
    private var sessionUnlimited = false
    /// 만료 후 idle 전환용 연속 카운트
    private var deadTicks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        // 이전 세션 복원
        if sleepDisabled() || caffeinateAlive() {
            isSessionActive = true
            sessionClosedMode = sleepDisabled()
            if let until = readUntilEpoch() {
                localUntilEpoch = until
                sessionUnlimited = false
            } else {
                sessionUnlimited = true
                localUntilEpoch = nil
            }
        }
        updateButtons()
        updateStatusVisuals()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: UI

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

        // 일반 rounded 버튼 — 구버전 AppKit에서도 isEnabled 만으로 확실히 구분
        startBtn = NSButton(title: "시작", target: self, action: #selector(startPressed))
        startBtn.bezelStyle = .rounded
        startBtn.setButtonType(.momentaryPushIn)

        stopBtn = NSButton(title: "해제", target: self, action: #selector(stopPressed))
        stopBtn.bezelStyle = .rounded
        stopBtn.setButtonType(.momentaryPushIn)

        let btnRow = NSStackView(views: [startBtn, stopBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 12
        btnRow.distribution = .fillEqually

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
        updateButtons()
        updateStatusVisuals()
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

    // MARK: Buttons — 규칙: 세션 켜짐 ⇒ 시작 OFF / 해제 ON

    /// 시작·해제 isEnabled 만 여기서 결정. 다른 코드에서 버튼 enable 직접 건드리지 말 것.
    func updateButtons() {
        if isSessionActive {
            // 작동 중: 시작 OFF · 해제 ON (시작 클릭 직후부터 이 규칙)
            startBtn.isEnabled = false
            startBtn.title = "시작"
            startBtn.keyEquivalent = ""

            if isBusy {
                // 해제 처리 중일 때만 해제 버튼도 잠시 잠금
                stopBtn.isEnabled = false
                stopBtn.title = "해제 중…"
                stopBtn.keyEquivalent = ""
            } else {
                stopBtn.isEnabled = true
                stopBtn.title = "해제"
                stopBtn.keyEquivalent = "\r"
            }

            radioClosed.isEnabled = false
            radioOpen.isEnabled = false
            seg.isEnabled = false
        } else {
            startBtn.isEnabled = !isBusy
            startBtn.title = isBusy ? "시작 중…" : "시작"
            startBtn.keyEquivalent = isBusy ? "" : "\r"

            stopBtn.isEnabled = false
            stopBtn.title = "해제"
            stopBtn.keyEquivalent = ""

            radioClosed.isEnabled = !isBusy
            radioOpen.isEnabled = !isBusy
            seg.isEnabled = !isBusy
        }

        // 강제 다시 그리기 (일부 macOS에서 isEnabled 시각 갱신 지연 방지)
        startBtn.needsDisplay = true
        stopBtn.needsDisplay = true
        window?.viewsNeedDisplay = true
    }

    func updateStatusVisuals() {
        if isSessionActive {
            let closed = sessionClosedMode
            phaseBadge.stringValue = closed ? "●  작동 중 · 뚜껑 닫아도 OK" : "●  작동 중"
            phaseBadge.textColor = closed ? .systemOrange : .systemGreen
            let tint: NSColor = closed ? .systemOrange : .systemGreen
            statusBox.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
            statusBox.layer?.borderWidth = 1.5
            statusBox.layer?.borderColor = tint.withAlphaComponent(0.55).cgColor

            statusLabel.stringValue = closed
                ? "뚜껑을 닫아도 깨어 있음"
                : "뚜껑을 열어둘 때만 깨어 있음"
            statusLabel.textColor = closed ? .systemOrange : .systemGreen

            if sessionUnlimited {
                countdownLabel.stringValue = "무제한"
                countdownLabel.textColor = .labelColor
            } else if let until = localUntilEpoch ?? readUntilEpoch() {
                let left = until - Int(Date().timeIntervalSince1970)
                if left > 0 {
                    countdownLabel.stringValue = fmtDuration(left)
                    countdownLabel.textColor = .labelColor
                } else {
                    countdownLabel.stringValue = "00분 00초"
                    countdownLabel.textColor = .secondaryLabelColor
                }
            } else {
                countdownLabel.stringValue = "…"
                countdownLabel.textColor = .secondaryLabelColor
            }
        } else {
            phaseBadge.stringValue = "○  작동 준비"
            phaseBadge.textColor = .secondaryLabelColor
            statusBox.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            statusBox.layer?.borderWidth = 1
            statusBox.layer?.borderColor = NSColor.separatorColor.cgColor

            statusLabel.stringValue = "평소처럼 잠자기 · 시작을 누르면 잠자기 방지"
            statusLabel.textColor = .secondaryLabelColor
            countdownLabel.stringValue = "—"
            countdownLabel.textColor = .tertiaryLabelColor
        }
    }

    func tick() {
        // 파일 기준 until 동기화
        if isSessionActive, !sessionUnlimited, localUntilEpoch == nil {
            localUntilEpoch = readUntilEpoch()
        }

        if isSessionActive, !sessionUnlimited, let until = localUntilEpoch {
            let left = until - Int(Date().timeIntervalSince1970)
            if left <= 0 {
                // 타이머 만료 → 세션 종료 (버튼도 시작만 활성)
                isSessionActive = false
                isBusy = false
                sessionClosedMode = false
                localUntilEpoch = nil
                deadTicks = 0
                updateButtons()
            }
        }

        // 시스템이 죽었고 무제한/잔여 없으면 종료 (오탐 방지: 연속 4틱)
        if isSessionActive, !isBusy {
            let systemActive = sleepDisabled() || caffeinateAlive()
            let remLeft: Int = {
                if sessionUnlimited { return 1 }
                if let until = localUntilEpoch {
                    return until - Int(Date().timeIntervalSince1970)
                }
                return 0
            }()
            if !systemActive && remLeft <= 0 {
                deadTicks += 1
                if deadTicks >= 4 {
                    isSessionActive = false
                    sessionClosedMode = false
                    localUntilEpoch = nil
                    sessionUnlimited = false
                    deadTicks = 0
                    updateButtons()
                }
            } else {
                deadTicks = 0
            }
        }

        updateStatusVisuals()
        // 버튼 상태는 세션 플래그만 따르므로 매 틱 재적용 (외부 간섭 방지)
        updateButtons()
    }

    func bumpGeneration() -> Int {
        let (_, out) = shell(
            #"G=$(( $(cat /tmp/lidguard_gen 2>/dev/null || echo 0) + 1 )); echo $G > /tmp/lidguard_gen; echo $G"#
        )
        return Int(out) ?? 1
    }

    // MARK: Actions

    @objc func startPressed() {
        // 이미 작동 중이면 무시
        guard !isSessionActive else { return }
        guard !isBusy else { return }

        let idx = max(0, min(seg.selectedSegment, durations.count - 1))
        let seconds = durations[idx]
        let closedMode = (radioClosed.state == .on)

        // ★ 클릭 즉시: 시작 OFF / 해제 ON (시스템 결과 기다리지 않음)
        isSessionActive = true
        isBusy = true
        sessionClosedMode = closedMode
        sessionUnlimited = (seconds == 0)
        if seconds > 0 {
            localUntilEpoch = Int(Date().timeIntervalSince1970) + seconds
        } else {
            localUntilEpoch = nil
        }
        deadTicks = 0
        stopBtn.title = "해제"
        updateButtons()
        updateStatusVisuals()

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
                    ok = (code == 0)
                } else {
                    let (code, _) = shell(
                        "nohup /usr/bin/caffeinate -i >/dev/null 2>&1 & echo $! > /tmp/lidguard_caffeinate.pid; rm -f /tmp/lidguard_until"
                    )
                    ok = (code == 0)
                }
            }

            DispatchQueue.main.async {
                self.isBusy = false
                if ok {
                    // 세션 유지: 시작 OFF / 해제 ON
                    self.isSessionActive = true
                    if let fileUntil = readUntilEpoch() {
                        self.localUntilEpoch = fileUntil
                    }
                } else {
                    // 암호 취소 등 실패 → 준비 상태
                    self.isSessionActive = false
                    self.sessionClosedMode = false
                    self.localUntilEpoch = nil
                    self.sessionUnlimited = false
                    _ = shell("rm -f /tmp/lidguard_until /tmp/lidguard_caffeinate.pid")
                }
                self.updateButtons()
                self.updateStatusVisuals()
            }
        }
    }

    @objc func stopPressed() {
        // 세션 중일 때만
        guard isSessionActive else { return }
        guard !isBusy else { return }

        isBusy = true
        stopBtn.title = "해제 중…"
        stopBtn.isEnabled = false
        startBtn.isEnabled = false
        startBtn.needsDisplay = true
        stopBtn.needsDisplay = true

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
                self.isBusy = false
                self.isSessionActive = false
                self.sessionClosedMode = false
                self.localUntilEpoch = nil
                self.sessionUnlimited = false
                self.deadTicks = 0
                self.updateButtons()
                self.updateStatusVisuals()
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
