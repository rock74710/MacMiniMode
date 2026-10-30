// 診斷：把「當 Mac mini 用」需要的幾樣東西逐項查一遍，並能把診斷資訊複製出來。
// 全部是隻讀檢查，不改任何設定。

import AppKit
import notify

struct HealthCheck {
    enum Level { case ok, warn, info }
    let level: Level
    let title: String
    let detail: String
}

enum Health {
    static func shell(_ command: String) -> (status: Int32, output: String) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func notifyState(_ name: String) -> UInt64 {
        var token: Int32 = 0
        var value: UInt64 = 0
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return 0 }
        notify_get_state(token, &value)
        notify_cancel(token)
        return value
    }

    static func portOpen(_ port: Int) -> Bool {
        shell("/usr/bin/nc -z -G 1 127.0.0.1 \(port)").status == 0
    }

    /// 會跑幾個系統命令，放在背景執行緒呼叫。
    static func run() -> [HealthCheck] {
        var checks: [HealthCheck] = []
        let running = daemonRunning()
        checks.append(running
            ? HealthCheck(level: .ok, title: L("背景服務執行中", "Background service is running"), detail: "")
            : HealthCheck(level: .warn, title: L("背景服務沒有執行", "Background service is not running"),
                          detail: L("重新安裝一次即可恢復。", "Reinstalling the app will bring it back.")))

        let awake = rootDomainFlag("SleepDisabled")
        checks.append(awake
            ? HealthCheck(level: .ok, title: L("Mac mini 模式已開啟", "Mac mini Mode is on"),
                          detail: L("現在合上蓋子，電腦會繼續執行。", "Close the lid now and the Mac keeps running."))
            : HealthCheck(level: .info, title: L("Mac mini 模式當前關閉", "Mac mini Mode is currently off"),
                          detail: L("沒插電，或設定為「始終關閉」。現在合蓋會正常睡眠。", "On battery, or set to Always Off. Closing the lid will sleep as usual.")))

        let overrides = notifyState("com.macminimode.overrides")
        checks.append(overrides == 0
            ? HealthCheck(level: .ok, title: L("沒有其他軟體改動電源設定", "No other software has changed power settings"), detail: "")
            : HealthCheck(level: .info, title: L("其他軟體改動過電源設定 \(overrides) 次，都已自動恢復", "Other software changed power settings \(overrides) times; all restored"),
                          detail: L("常見於遠端桌面、清理最佳化類軟體，不影響使用。", "Usually a remote desktop or cleaner app. Nothing to do.")))

        checks.append(portOpen(22)
            ? HealthCheck(level: .ok, title: L("遠端登入（SSH）已開啟", "Remote Login (SSH) is on"), detail: "")
            : HealthCheck(level: .info, title: L("遠端登入（SSH）未開啟", "Remote Login (SSH) is off"),
                          detail: L("需要的話，到 系統設定 → 通用 → 共享 開啟「遠端登入」。", "If you need it, turn on Remote Login in System Settings → General → Sharing.")))
        checks.append(portOpen(5900)
            ? HealthCheck(level: .ok, title: L("螢幕共享已開啟", "Screen Sharing is on"), detail: "")
            : HealthCheck(level: .info, title: L("螢幕共享未開啟", "Screen Sharing is off"),
                          detail: L("需要遠端看桌面的話，到 系統設定 → 通用 → 共享 開啟「螢幕共享」。", "To view the desktop remotely, turn on Screen Sharing in System Settings → General → Sharing.")))

        let battery = shell("/usr/bin/pmset -g ps").output
        if let range = battery.range(of: #"[0-9]+%"#, options: .regularExpression),
           let percent = Int(battery[range].dropLast()) {
            let plugged = battery.contains("AC Power")
            checks.append(plugged && percent >= 95
                ? HealthCheck(level: .warn, title: L("電量 \(percent)%，一直充到接近滿電", "Battery at \(percent)% and held near full"),
                              detail: L("長期插電建議到 系統設定 → 電池 把充電上限設為 80%，對電池更好。", "If it stays plugged in, set the charge limit to 80% in System Settings → Battery."))
                : HealthCheck(level: .ok, title: L("電量 \(percent)%", "Battery at \(percent)%"), detail: ""))
        }

        if shell("/usr/bin/fdesetup status").output.contains("FileVault is On") {
            checks.append(HealthCheck(level: .info, title: L("已開啟 FileVault", "FileVault is on"),
                                      detail: L("斷電重啟後，要先在這台電腦上輸入一次密碼，遠端才連得上。", "After a power loss and restart, the Mac needs its password typed locally before you can connect remotely.")))
        }

        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            checks.append(HealthCheck(level: .warn, title: L("機器溫度偏高", "The Mac is running hot"),
                                      detail: L("合蓋執行時把它放在通風的地方，最好豎起來放。", "Keep it somewhere ventilated when running with the lid closed, ideally upright.")))
        default:
            checks.append(HealthCheck(level: .ok, title: L("溫度正常", "Temperature is normal"), detail: ""))
        }
        return checks
    }

    /// 給使用者貼到回報裡的文本。只讀取，不上傳。
    static func report(_ checks: [HealthCheck]) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let model = shell("/usr/sbin/sysctl -n hw.model").output.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["Mac mini Mode \(version) · macOS \(system) · \(model)",
                     ISO8601DateFormatter().string(from: Date()), ""]
        lines.append("[checks]")
        for check in checks {
            let mark = check.level == .ok ? "✓" : check.level == .warn ? "!" : "-"
            lines.append("\(mark) \(check.title)")
        }
        lines.append("\n[setting] mode=\(notifyState("com.macminimode.state")) (0 auto, 1 on, 2 off)")
        lines.append("\n[pmset]")
        lines.append(shell("/usr/bin/pmset -g | grep -E 'SleepDisabled|hibernatemode|standby |powernap| sleep |displaysleep|lidwake|womp' | cut -c1-110").output)
        lines.append("[assertions]")
        // 我們自己的那條放最前面，其餘按程序去重，免得被同一個程序的十幾條刷掉。
        lines.append(shell("/usr/bin/pmset -g assertions | grep 'pid ' | grep -E 'PreventSystemSleep|PreventUserIdleSystemSleep' | awk '/macmini-moded/ {print; next} !seen[$2]++ {rest[n++] = $0} END {for (i = 0; i < n && i < 8; i++) print rest[i]}' | cut -c1-150").output)
        lines.append("[sleep / wake, last 15]")
        lines.append(shell("/usr/bin/pmset -g log | grep -E '^[0-9-]+ [0-9:]+ [+-][0-9]+ (Sleep|Wake|DarkWake)  ' | tail -n 15 | cut -c1-170").output)
        lines.append("[service log, last 40]")
        lines.append(shell("/usr/bin/tail -n 40 /var/log/macmini-mode.log").output)
        return lines.joined(separator: "\n")
    }
}

final class HealthWindowController: NSObject {
    private var window: NSWindow?
    private let rows = NSStackView()
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private var checks: [HealthCheck] = []

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func build() {
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12

        copyButton.title = L("複製診斷資訊", "Copy Diagnostics")
        copyButton.target = self
        copyButton.action = #selector(copyReport)
        copyButton.bezelStyle = .rounded
        refreshButton.title = L("重新檢查", "Check Again")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded

        let note = NSTextField(wrappingLabelWithString: L(
            "回報問題時，點「複製診斷資訊」把結果貼給開發者。內容只會放進剪貼簿，不會上傳。",
            "When reporting a problem, use Copy Diagnostics and paste the result. It only goes to your clipboard; nothing is uploaded."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 420

        let buttons = NSStackView(views: [copyButton, refreshButton])
        buttons.spacing = 10

        let content = NSStackView(views: [rows, NSBox.separator(), note, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        content.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 468, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("診斷", "Health Check")
        window.isReleasedWhenClosed = false
        let host = NSView()
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 468),
        ])
        window.contentView = host
        self.window = window
    }

    private func row(_ check: HealthCheck) -> NSView {
        let (symbol, color): (String, NSColor) = switch check.level {
        case .ok: ("checkmark.circle.fill", .systemGreen)
        case .warn: ("exclamationmark.triangle.fill", .systemOrange)
        case .info: ("info.circle.fill", .secondaryLabelColor)
        }
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        icon.contentTintColor = color
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let title = NSTextField(wrappingLabelWithString: check.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.preferredMaxLayoutWidth = 390
        let text = NSStackView(views: [title])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        if !check.detail.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: check.detail)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 390
            text.addArrangedSubview(detail)
        }
        let line = NSStackView(views: [icon, text])
        line.alignment = .top
        line.spacing = 8
        return line
    }

    private func setRows(_ views: [NSView]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach { rows.addArrangedSubview($0) }
    }

    @objc private func refresh() {
        copyButton.isEnabled = false
        refreshButton.isEnabled = false
        copyButton.title = L("複製診斷資訊", "Copy Diagnostics")
        setRows([row(HealthCheck(level: .info, title: L("正在檢查…", "Checking…"), detail: ""))])
        DispatchQueue.global(qos: .userInitiated).async {
            let checks = Health.run()
            DispatchQueue.main.async {
                self.checks = checks
                self.setRows(checks.map(self.row))
                self.copyButton.isEnabled = true
                self.refreshButton.isEnabled = true
            }
        }
    }

    @objc private func copyReport() {
        copyButton.isEnabled = false
        let checks = self.checks
        DispatchQueue.global(qos: .userInitiated).async {
            let report = Health.report(checks)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                self.copyButton.title = L("已複製", "Copied")
                self.copyButton.isEnabled = true
            }
        }
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 424).isActive = true
        return box
    }
}
