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
    // Escape for AppleScript double-quoted string
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

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let statusLabel = NSTextField(labelWithString: "")
    var radioClosed: NSButton!
    var radioOpen: NSButton!
    var seg: NSSegmentedControl!
    var startBtn: NSButton!
    var stopBtn: NSButton!
    /// Duration options in seconds (segment labels derived below).
    let durations: [Int] = [
        30 * 60,      // 30분
        60 * 60,      // 1시간
        2 * 60 * 60,  // 2시간
        4 * 60 * 60,  // 4시간
        8 * 60 * 60,  // 8시간
        0,            // 무제한 (수동 해제)
    ]
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
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

    func buildUI() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "잠자기 방지")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.alignment = .left

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
        seg.selectedSegment = 1 // 1시간 기본
        for i in 0..<labels.count {
            seg.setWidth(58, forSegment: i)
        }

        startBtn = NSButton(title: "시작", target: self, action: #selector(startPressed))
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"

        stopBtn = NSButton(title: "잠자기 방지 종료", target: self, action: #selector(stopPressed))
        stopBtn.bezelStyle = .rounded

        let btnRow = NSStackView(views: [startBtn, stopBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 10
        btnRow.distribution = .fillEqually

        let stack = NSStackView(views: [
            title,
            statusLabel,
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
        stack.setCustomSpacing(14, after: statusLabel)
        stack.setCustomSpacing(14, after: radioOpen)
        stack.setCustomSpacing(16, after: seg)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            seg.widthAnchor.constraint(equalToConstant: 360),
            btnRow.widthAnchor.constraint(equalToConstant: 360),
        ])

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
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
        refresh()
    }

    // MARK: State

    func refresh() {
        let disabled = sleepDisabled()
        let caff = caffeinateAlive()
        let rem = remainingSeconds()

        if disabled {
            if let rem, rem > 0 {
                statusLabel.stringValue = "켜짐 — 뚜껑을 닫아도 깨어 있음  ·  남은 시간 \(fmtDuration(rem))"
            } else {
                statusLabel.stringValue = "켜짐 — 뚜껑을 닫아도 깨어 있음  ·  타이머 없음(해제 필요)"
            }
            statusLabel.textColor = .systemOrange
        } else if caff {
            if let rem, rem > 0 {
                statusLabel.stringValue = "켜짐 — 뚜껑을 열어둘 때만 깨어 있음  ·  남은 시간 \(fmtDuration(rem))"
            } else {
                statusLabel.stringValue = "켜짐 — 뚜껑을 열어둘 때만 깨어 있음"
            }
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "꺼짐 — 평소처럼 잠자기"
            statusLabel.textColor = .secondaryLabelColor
        }

        let active = disabled || caff
        startBtn.isEnabled = !active
        stopBtn.isEnabled = active
        radioClosed.isEnabled = !active
        radioOpen.isEnabled = !active
        seg.isEnabled = !active
    }

    func bumpGeneration() -> Int {
        let (_, out) = shell(
            #"G=$(( $(cat /tmp/lidguard_gen 2>/dev/null || echo 0) + 1 )); echo $G > /tmp/lidguard_gen; echo $G"#
        )
        return Int(out) ?? 1
    }

    // MARK: Actions

    @objc func startPressed() {
        let idx = max(0, seg.selectedSegment)
        let seconds = durations[idx]
        let closedMode = radioClosed.state == .on

        startBtn.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // clear previous caffeinate
            _ = shell(
                "test -f /tmp/lidguard_caffeinate.pid && kill $(cat /tmp/lidguard_caffeinate.pid) 2>/dev/null; rm -f /tmp/lidguard_caffeinate.pid /tmp/lidguard_until /tmp/lidguard_revert.sh"
            )

            if closedMode {
                // Lid closed: pmset disablesleep (admin password once).
                // Timed mode backgrounds a sleep+revert under the elevated shell.
                let gen = self.bumpGeneration()
                if seconds > 0 {
                    let full =
                        "/usr/bin/pmset -a disablesleep 1; " +
                        "echo $(( $(date +%s) + \(seconds) )) > /tmp/lidguard_until; " +
                        "( sleep \(seconds); " +
                        "[ \"$(cat /tmp/lidguard_gen 2>/dev/null)\" = \"\(gen)\" ] && " +
                        "{ /usr/bin/pmset -a disablesleep 0; rm -f /tmp/lidguard_until; }; " +
                        ") >/dev/null 2>&1 &"
                    _ = adminShell(full)
                } else {
                    _ = adminShell("/usr/bin/pmset -a disablesleep 1; rm -f /tmp/lidguard_until")
                }
            } else {
                // Lid open only: caffeinate -i
                if seconds > 0 {
                    _ = shell(
                        "nohup /usr/bin/caffeinate -i -t \(seconds) >/dev/null 2>&1 & echo $! > /tmp/lidguard_caffeinate.pid; echo $(( $(date +%s) + \(seconds) )) > /tmp/lidguard_until"
                    )
                } else {
                    _ = shell(
                        "nohup /usr/bin/caffeinate -i >/dev/null 2>&1 & echo $! > /tmp/lidguard_caffeinate.pid; rm -f /tmp/lidguard_until"
                    )
                }
            }

            DispatchQueue.main.async {
                self.refresh()
            }
        }
    }

    @objc func stopPressed() {
        stopBtn.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = self.bumpGeneration()
            _ = shell(
                "test -f /tmp/lidguard_caffeinate.pid && kill $(cat /tmp/lidguard_caffeinate.pid) 2>/dev/null; rm -f /tmp/lidguard_caffeinate.pid /tmp/lidguard_until /tmp/lidguard_revert.sh"
            )
            if sleepDisabled() {
                _ = adminShell("/usr/bin/pmset -a disablesleep 0; rm -f /tmp/lidguard_until; exit 0")
            } else {
                _ = shell("rm -f /tmp/lidguard_until")
            }
            DispatchQueue.main.async {
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
