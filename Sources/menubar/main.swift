// macmini-menubar — 選單列圖示，顯示 Mac mini 模式當前狀態，並可手動切換模式（不需要 root）。
// 診斷視窗在 Health.swift，合蓋熄屏在 LidScreen.swift。
// 切換通過 Darwin 通知發給 macmini-moded，由它去改系統設定。

import AppKit
import IOKit
import IOKit.ps
import notify

let logPath = "/var/log/macmini-mode.log"
let notifyPrefix = "com.macminimode"

// 介面和日誌跟隨系統首選語言：中文環境用中文，其餘用英文。
let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func L(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

// 與 macmini-moded 裡 Mode 的 rawValue / name 對應。
let modes: [(name: String, title: String, tip: String)] = [
    ("auto", L("插電時不睡眠（合蓋也是）", "Stay Awake on Power (Even Lid Closed)"),
     L("插電時，電腦持續運作，螢幕不會自動關閉。用電池時照系統設定睡眠。",
       "On power, the Mac keeps running and the screen stays on. On battery, it sleeps normally.")),
    ("on", L("插電或用電池都不睡眠", "Stay Awake on Power or Battery"),
     L("插電或用電池都持續運作。電量剩 10% 時，會恢復正常睡眠。",
       "The Mac keeps running on power or battery. At 10% battery, it sleeps normally again.")),
    ("off", L("照系統設定睡眠", "Use Normal Sleep Settings"),
     L("照 macOS 的設定睡眠，合蓋時也會睡眠。", "The Mac follows the macOS sleep settings, including when the lid closes.")),
]

func rootDomainFlag(_ key: String) -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    return (value as? Bool) ?? false
}

func powerDescription() -> String {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let type = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
    var text = type == kIOPSACPowerValue ? L("電源介面卡", "Power Adapter") : L("電池", "Battery")
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
    for source in sources {
        guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let percent = desc[kIOPSCurrentCapacityKey] as? Int else { continue }
        text += " · \(percent)%"
        break
    }
    return text
}

func daemonRunning() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", "macmini-moded"]
    task.standardOutput = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return false
    }
    return task.terminationStatus == 0
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let modeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let powerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let daemonItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var switchItems: [NSMenuItem] = []
    let health = HealthWindowController()
    let lidScreen = LidScreen()
    let lidScreenItem = NSMenuItem(title: L("合蓋時把內建螢幕調成全黑", "Black Out Built-in Screen When Lid Closes"), action: #selector(toggleLidScreen), keyEquivalent: "")
    var stateToken: Int32 = 0
    var timer: Timer?
    var lidTimer: Timer?
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    // 只有點了選單裡的「退出並恢復睡眠」才算使用者主動退出。其他途徑的退出（系統登出、重啟、
    // 活動監視器、指令碼）一律不改模式：把背景服務永久切到關閉必須是明確的使用者操作。
    private var userRequestedQuit = false
    @MainActor private lazy var quitController = QuitController(
        requestStop: { notify_post("\(notifyPrefix).set-off") },
        hasStopped: { QuitPolicy.isStopped(prefix: notifyPrefix) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for item in [modeItem, powerItem, daemonItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let header = NSMenuItem(title: L("電腦何時不睡眠", "When the Mac Stays Awake"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (index, mode) in modes.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = mode.tip
            item.tag = index
            switchItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        lidScreenItem.target = self
        lidScreenItem.toolTip = L("沒接外接螢幕時才會作用。只把亮度調到 0，不鎖定螢幕。萬一開蓋後螢幕還是黑的，按鍵盤上的亮度增加鍵（F2）即可。",
                                  "Only the backlight is switched off; the Mac does not lock. If the screen is still dark after opening the lid, press the brightness-up key (F2).")
        menu.addItem(lidScreenItem)
        menu.addItem(.separator())
        let healthItem = NSMenuItem(title: L("診斷…", "Health Check…"), action: #selector(openHealth), keyEquivalent: "")
        healthItem.target = self
        menu.addItem(healthItem)
        let logItem = NSMenuItem(title: L("檢視日誌", "View Log"), action: #selector(openLog), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L("退出並恢復睡眠", "Quit and Allow Sleep"),
                                 action: #selector(quitAndAllowSleep), keyEquivalent: "q")
        quitItem.target = self
        quitItem.toolTip = L("退出後不再防止 Mac 休眠。", "Quitting stops Mac mini Mode from preventing sleep.")
        menu.addItem(quitItem)
        statusItem.menu = menu

        if CommandLine.arguments.contains("--health-check") { health.show() }

        notify_register_dispatch("\(notifyPrefix).state", &stateToken, .main) { [weak self] _ in
            self?.refreshSoon()
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().refreshSoon()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        // 合蓋要儘快反應，單獨每秒看一次蓋子；只讀一個系統屬性，開銷可以忽略。
        lidTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.lidScreen.tick(modeOn: rootDomainFlag("SleepDisabled"), lidClosed: rootDomainFlag("AppleClamshellState"))
        }
        // 上次如果沒來得及恢復亮度（比如被強制結束），啟動時補上。
        if !rootDomainFlag("AppleClamshellState") { lidScreen.restore() }
        // 安裝器升級時會用訊號結束這個程序，退出前先把亮度還回去。
        signal(SIGTERM, SIG_IGN)
        termSource.setEventHandler { [weak self] in
            self?.lidScreen.restore()
            exit(0)
        }
        termSource.resume()
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lidScreen.restore()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 系統退出不等於使用者主動關閉 App，不能在重啟或登出時永久關閉自動模式。
        guard userRequestedQuit,
              !QuitPolicy.isSystemQuit(NSAppleEventManager.shared().currentAppleEvent) else { return .terminateNow }
        quitController.begin { [weak self] stopped in
            sender.reply(toApplicationShouldTerminate: stopped)
            guard !stopped else { return }
            self?.userRequestedQuit = false
            self?.refresh()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("未能確認防休眠已關閉", "Could Not Confirm Sleep Is Allowed")
            alert.informativeText = L(
                "App 尚未退出。請檢視「診斷」或日誌，解決問題後再退出。",
                "The app is still running. Check Health Check or View Log, then try quitting again.")
            alert.addButton(withTitle: L("好", "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        return .terminateLater
    }

    // 守護程序收到通知後才去改設定，立即讀一次，稍等再讀一次。
    func refreshSoon() {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func refresh() {
        let enabled = rootDomainFlag("SleepDisabled")
        let running = daemonRunning()
        var rawMode: UInt64 = 0
        notify_get_state(stateToken, &rawMode)

        let symbol = !running ? "exclamationmark.triangle" : (enabled ? "macmini.fill" : "laptopcomputer")
        let name = L("Mac mini 模式", "Mac mini Mode")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = name + L("：", ": ") + (enabled ? L("開啟", "On") : L("關閉", "Off"))

        modeItem.title = name + L("：", ": ") + (enabled
            ? L("開啟（合蓋繼續執行）", "On (keeps running with the lid closed)")
            : L("關閉（正常睡眠）", "Off (sleeps normally)"))
        powerItem.title = L("供電：", "Power: ") + powerDescription()
        daemonItem.title = L("背景服務：", "Background service: ") + (running ? L("執行中", "Running") : L("未執行", "Not running"))
        for item in switchItems {
            item.isEnabled = running
            item.state = running && item.tag == Int(rawMode) ? .on : .off
        }
        lidScreenItem.state = lidScreen.enabled ? .on : .off
    }

    @objc func toggleLidScreen() {
        lidScreen.enabled.toggle()
        refresh()
    }

    @objc func selectMode(_ sender: NSMenuItem) {
        notify_post("\(notifyPrefix).set-\(modes[sender.tag].name)")
    }

    @objc func quitAndAllowSleep() {
        userRequestedQuit = true
        NSApp.terminate(nil)
    }

    @objc func openHealth() {
        health.show()
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }
}

// 命令列的 `macminimode screen-on` 走這裡：開蓋後螢幕萬一還是黑的，可以遠端執行把背光開啟。
if CommandLine.arguments.contains("--screen-on") {
    exit(LidScreen().forceOn() ? 0 : 1)
}

// 命令列的 `macminimode check` 走這裡：把診斷結果和診斷資訊印出出來就退出，不啟動介面。
if CommandLine.arguments.contains("--print-diagnostics") {
    print(Health.report(Health.run()))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
