// 合蓋後關掉蓋子裡那塊螢幕的背光，開蓋時恢復原來的亮度。
// Mac mini 模式下系統不睡眠，如果顯示器睡眠被設成「永不」（遠端桌面軟體常這麼做），合蓋後螢幕會一直亮著。
// 只關背光、不讓顯示器睡眠：顯示器一睡就會觸發鎖屏，還會打斷視訊通話和遠端桌面這類正在用螢幕的應用。
// 亮度會被系統記住，所以原來的值存進偏好設定，開蓋、退出、被終止、下次啟動時都會嘗試恢復。

import AppKit

final class LidScreen {
    static let enabledKey = "screenOffWhenLidClosed"
    static let savedKey = "brightnessBeforeLidClosed"

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?

    init() {
        // 系統自帶的亮度介面，沒有公開標頭檔案，執行時查詢；找不到就什麼都不做。
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getBrightness = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetBrightness.self) }
        setBrightness = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetBrightness.self) }
    }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private var saved: Float? {
        get { UserDefaults.standard.object(forKey: Self.savedKey) as? Float }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.savedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.savedKey)
            }
        }
    }

    private func displays() -> (builtin: CGDirectDisplayID?, external: Bool) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return (nil, false) }
        let online = ids.prefix(Int(count))
        return (online.first { CGDisplayIsBuiltin($0) != 0 }, online.contains { CGDisplayIsBuiltin($0) == 0 })
    }

    /// 接著外接顯示器時不動：那時系統自己會關掉內建螢幕。
    static func shouldDim(enabled: Bool, lidClosed: Bool, modeOn: Bool, hasBuiltin: Bool, hasExternal: Bool) -> Bool {
        enabled && lidClosed && modeOn && hasBuiltin && !hasExternal
    }

    func tick(modeOn: Bool, lidClosed: Bool) {
        guard let getBrightness, let setBrightness else { return }
        let (builtin, external) = displays()
        if Self.shouldDim(enabled: enabled, lidClosed: lidClosed, modeOn: modeOn, hasBuiltin: builtin != nil, hasExternal: external),
           let builtin {
            var current: Float = 0
            guard getBrightness(builtin, &current) == 0, current > 0.001 else { return }
            // 只在第一次記下原來的亮度；之後如果亮度被別的東西調高，再壓回 0，但不覆蓋記下的值。
            if saved == nil { saved = current }
            _ = setBrightness(builtin, 0)
        } else if !lidClosed || !enabled {
            restore()
        }
    }

    /// 把亮度恢復成合蓋前的值。內建螢幕暫時不線上時保留記錄，下次再試。
    func restore() {
        guard let setBrightness, let value = saved, let builtin = displays().builtin else { return }
        if setBrightness(builtin, value) == 0 { saved = nil }
    }

    /// 應急用（命令列 `macminimode screen-on`）：先按記錄恢復；沒有記錄而螢幕仍然是黑的，就直接調到一個看得見的亮度。
    func forceOn() -> Bool {
        restore()
        guard let getBrightness, let setBrightness, let builtin = displays().builtin else { return false }
        var current: Float = 0
        guard getBrightness(builtin, &current) == 0 else { return false }
        if current < 0.05 { return setBrightness(builtin, 0.7) == 0 }
        return true
    }
}
