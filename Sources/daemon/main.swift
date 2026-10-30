// macmini-moded — 插電時禁止睡眠（合蓋也繼續跑），拔電時恢復正常睡眠。
// 以 root 身份作為 LaunchDaemon 執行；--dry-run 只打印不執行。
// 測試用引數（僅 --dry-run 下生效）：--simulate-power=ac|battery、--simulate-battery=<百分比>；--log-file=<路徑> 把日誌寫到指定檔案。
// 選單欄通過 Darwin 通知切換模式：<prefix>.set-auto / set-on / set-off，當前模式釋出在 <prefix>.state。

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import notify

let dryRun = CommandLine.arguments.contains("--dry-run")
let notifyPrefix = dryRun ? "com.macminimode.dryrun" : "com.macminimode"
let modeFile = "/var/db/macmini-mode"
setvbuf(stdout, nil, _IOLBF, 0)

func argValue(_ name: String) -> String? {
    CommandLine.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
}
let logFile = argValue("--log-file") ?? "/var/log/macmini-mode.log"
let logToFile = !dryRun || argValue("--log-file") != nil
let simulatedPower = dryRun ? argValue("--simulate-power") : nil
let simulatedBattery = dryRun ? argValue("--simulate-battery").flatMap { Int($0) } : nil

// 介面和日誌跟隨系統首選語言：中文環境用中文，其餘用英文。
let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func L(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

enum Mode: UInt64, CaseIterable {
    case auto = 0, on = 1, off = 2

    var name: String {
        switch self {
        case .auto: return "auto"
        case .on: return "on"
        case .off: return "off"
        }
    }

    var label: String {
        switch self {
        case .auto: return L("自動", "Automatic")
        case .on: return L("始終開啟", "Always On")
        case .off: return L("始終關閉", "Always Off")
        }
    }
}

enum State {
    nonisolated(unsafe) static var mode = Mode.auto
    nonisolated(unsafe) static var applied: Bool?
    nonisolated(unsafe) static var stateToken: Int32 = 0
    nonisolated(unsafe) static var assertion: IOPMAssertionID = 0
    nonisolated(unsafe) static var displayAssertion: IOPMAssertionID = 0
    nonisolated(unsafe) static var overrides = 0
    nonisolated(unsafe) static var burstStart = Date.distantPast
    nonisolated(unsafe) static var burst = 0
    nonisolated(unsafe) static var overridesToken: Int32 = 0
    nonisolated(unsafe) static var lowBattery = false
}

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard logToFile else {
        print(line, terminator: "")
        return
    }
    // 每寫一行都重新開啟檔案：清理類軟體會刪掉 /var/log 下的檔案，這樣刪了也能自己重建。
    var info = stat()
    if stat(logFile, &info) == 0, info.st_size > 1_000_000 {
        rename(logFile, logFile + ".1")
    }
    let fd = open(logFile, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

func onACPower() -> Bool {
    if let simulatedPower { return simulatedPower == "ac" }
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let type = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
    return type == kIOPSACPowerValue
}

func batteryPercent() -> Int? {
    if let simulatedBattery { return simulatedBattery }
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    for source in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
        guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let percent = desc[kIOPSCurrentCapacityKey] as? Int else { continue }
        return percent
    }
    return nil
}

func rootDomainFlag(_ key: String) -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    return (value as? Bool) ?? false
}

@discardableResult
func pmset(_ args: [String]) -> Bool {
    if dryRun {
        log("[dry-run] pmset \(args.joined(separator: " "))")
        return true
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = args
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        log("pmset \(args.joined(separator: " ")) \(L("啟動失敗", "failed to launch")): \(error.localizedDescription)")
        return false
    }
    if task.terminationStatus != 0 {
        log("pmset \(args.joined(separator: " ")) \(L("退出碼", "exited with status")) \(task.terminationStatus)")
        return false
    }
    return true
}

// 「始終開啟」時用電池硬撐，電量降到 10% 就放行睡眠，免得直接斷電。回到 15% 以上或接上電源後恢復。
func updateLowBattery() {
    let was = State.lowBattery
    if State.mode == .on, !onACPower(), let percent = batteryPercent() {
        if percent <= 10 {
            State.lowBattery = true
        } else if percent >= 15 {
            State.lowBattery = false
        }
    } else {
        State.lowBattery = false
    }
    // 是切換模式導致的解除就不用記了，模式切換本身已經有一行日誌。
    guard State.lowBattery != was, State.mode == .on else { return }
    log(State.lowBattery
        ? L("電量降到 10%，暫時放行睡眠，免得直接斷電", "Battery at 10%: allowing sleep for now to avoid a hard power-off")
        : L("電量或供電已恢復，低電量保護解除", "Battery or power is back: low-battery protection lifted"))
}

func wantsMacMiniMode() -> Bool {
    switch State.mode {
    case .auto: return onACPower()
    case .on: return !State.lowBattery
    case .off: return false
    }
}

// 第二道保險。disablesleep 管的是合蓋睡眠，但別的程式改電源設定時會把它清掉；
// 這個斷言管空閒睡眠，在 disablesleep 被清掉到我們補回去之間，機器不會因為沒人操作而睡著。
// 另外再拿一個防顯示器睡眠的斷言：顯示器一睡，遠端桌面就只看得到黑屏。合蓋時背光由選單欄關掉。
func holdAssertion(_ on: Bool) {
    holdAssertion(on, type: "PreventSystemSleep", id: &State.assertion)
    holdAssertion(on, type: "PreventUserIdleDisplaySleep", id: &State.displayAssertion)
}

func holdAssertion(_ on: Bool, type: String, id: inout IOPMAssertionID) {
    if on, id == 0 {
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Mac mini Mode" as CFString, &newID)
        if result == kIOReturnSuccess {
            id = newID
        } else {
            log(L("建立防睡眠斷言失敗", "Could not create the sleep assertion") + " \(type) (\(result))")
        }
    } else if !on, id != 0 {
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else {
            log(L("釋放防睡眠斷言失敗", "Could not release the sleep assertion") + " \(type) (\(result))")
            return
        }
        id = 0
    }
}

func sync() {
    updateLowBattery()
    let want = wantsMacMiniMode()
    holdAssertion(want)
    // 以系統裡的真實值為準，別的工具或手動 pmset 改掉了也要糾正回來。
    let current = dryRun ? State.applied : rootDomainFlag("SleepDisabled")
    guard want != current else {
        State.applied = want
        return
    }
    let overridden = State.applied == want
    if overridden {
        // 萬一對方也是一被改就立刻改回去，兩邊會無休止地拉鋸。每 10 秒最多糾正 5 次，其餘的留給下一輪。
        let now = Date()
        if now.timeIntervalSince(State.burstStart) > 10 {
            State.burstStart = now
            State.burst = 0
        }
        State.burst += 1
        guard State.burst <= 5 else { return }
    }
    guard pmset(["-a", "disablesleep", want ? "1" : "0"]) else { return }
    State.applied = want
    if overridden {
        // 有的機器上每隔幾分鐘就會被改一次，只記前幾次和之後每 50 次，免得日誌刷屏。
        State.overrides += 1
        notify_set_state(State.overridesToken, UInt64(State.overrides))
        if State.overrides <= 3 || State.overrides % 50 == 0 {
            log(L("睡眠設定被其他程式改動，已恢復為 disablesleep \(want ? 1 : 0)（第 \(State.overrides) 次）",
                  "Sleep setting was changed by another program; restored disablesleep \(want ? 1 : 0) (#\(State.overrides))"))
        }
        return
    }
    let reason: String
    if State.mode == .auto {
        reason = want ? L("接入電源", "On AC power") : L("使用電池", "On battery")
    } else if State.mode == .on, State.lowBattery {
        reason = L("電量不足", "Battery low")
    } else {
        reason = State.mode.label
    }
    let outcome = want
        ? L("Mac mini 模式開啟 (disablesleep 1)", "Mac mini mode on (disablesleep 1)")
        : L("Mac mini 模式關閉 (disablesleep 0)", "Mac mini mode off (disablesleep 0)")
    log("\(reason) → \(outcome)")

    // 清掉 disablesleep 並不會讓已經合蓋的機器自己睡下去，這裡補一腳，免得在包裡發熱。
    // AppleClamshellCausesSleep 是核心自己的判斷：接著外接顯示器時為 No，就不打擾。
    if !want {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !wantsMacMiniMode(),
                  rootDomainFlag("AppleClamshellState"),
                  rootDomainFlag("AppleClamshellCausesSleep") else { return }
            log(L("已合蓋且允許睡眠 → 立即睡眠", "Lid closed and sleep allowed → sleeping now"))
            pmset(["sleepnow"])
        }
    }
}

func publishMode() {
    notify_set_state(State.stateToken, State.mode.rawValue)
    notify_post("\(notifyPrefix).state")
}

func setMode(_ mode: Mode) {
    // 退出時會再次請求關閉；即使模式已經是 off，也重試儲存和應用，修復先前的失敗。
    guard mode != State.mode || mode == .off else { return }
    if mode != State.mode {
        log(L("模式切換為：", "Mode set to: ") + mode.label)
    }
    State.mode = mode
    if !dryRun {
        do {
            try mode.name.write(toFile: modeFile, atomically: true, encoding: .utf8)
        } catch {
            log(L("儲存模式失敗", "Failed to save mode") + ": \(error.localizedDescription)")
        }
    }
    publishMode()
    sync()
}

func shutdown(_ name: String) {
    log(L("收到 \(name)，恢復 disablesleep 0 後退出", "Received \(name), restoring disablesleep 0 and exiting"))
    pmset(["-a", "disablesleep", "0"])
    exit(0)
}

var signalSources: [DispatchSourceSignal] = []
for (sig, name) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { shutdown(name) }
    source.resume()
    signalSources.append(source)
}

guard let runLoopSource = IOPSNotificationCreateRunLoopSource({ _ in sync() }, nil)?.takeRetainedValue() else {
    log(L("無法註冊電源變化通知", "Could not register for power source notifications"))
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

if !dryRun,
   let saved = try? String(contentsOfFile: modeFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
   let mode = Mode.allCases.first(where: { $0.name == saved }) {
    State.mode = mode
}

notify_register_check("\(notifyPrefix).state", &State.stateToken)
// 選單欄的體檢視窗從這裡讀「被其他程式改動了多少次」。
notify_register_check("\(notifyPrefix).overrides", &State.overridesToken)
notify_set_state(State.overridesToken, 0)
var commandTokens: [Int32] = []
for mode in Mode.allCases {
    var token: Int32 = 0
    notify_register_dispatch("\(notifyPrefix).set-\(mode.name)", &token, .main) { _ in setMode(mode) }
    commandTokens.append(token)
}

// 別的程式改電源設定時會順帶清掉 disablesleep（實測有機器每 10 分鐘被清一次）。
// 系統在設定變化時會發這個通知，但通知到達時新值還沒寫進核心，所以收到後隔一小會兒再對幾次賬。
var prefsToken: Int32 = 0
notify_register_dispatch("com.apple.system.powermanagement.prefschange", &prefsToken, .main) { _ in
    for delay in [0, 0.2, 1, 2.5] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sync() }
    }
}

// 兜底：萬一漏掉通知（比如睡眠期間拔電），每 5 秒對一次賬。只讀一個系統屬性，開銷可以忽略。
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 5, repeating: 5)
timer.setEventHandler { sync() }
timer.resume()

// 只記錄，不據此自動睡眠：過熱保護交給系統自己，這裡留痕方便事後排查。
var thermalWasHigh = false
NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
    let state = ProcessInfo.processInfo.thermalState
    let high = state == .serious || state == .critical
    if high {
        log(state == .critical
            ? L("機器溫度過高（危險級別）", "Thermal state: critical")
            : L("機器溫度偏高", "Thermal state: serious"))
    } else if thermalWasHigh {
        log(L("機器溫度恢復正常", "Thermal state back to normal"))
    }
    thermalWasHigh = high
}

log(L("macmini-moded 啟動", "macmini-moded started") + (dryRun ? " (dry-run)" : "")
    + L("，模式：", ", mode: ") + State.mode.label)
publishMode()
sync()
CFRunLoopRun()
