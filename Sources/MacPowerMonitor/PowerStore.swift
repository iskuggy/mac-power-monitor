import Foundation
import IOKit.ps
import SwiftUI
import UserNotifications

// MARK: - 警告去抖

/// 警告去抖：橙色警告需连续两个采样命中才展示，滤掉插拔瞬间的过渡样本。
/// 独立成值类型便于单测。
struct WarningDebouncer {
    private var pendingKinds: Set<String> = []

    mutating func filter(_ info: PowerInfo) -> PowerInfo {
        let currentKinds = Set(info.diagnostics.filter { $0.severity == .warning }.map { $0.kind })
        var result = info
        result.diagnostics = info.diagnostics.filter { $0.severity != .warning || pendingKinds.contains($0.kind) }
        result.status = result.diagnostics.contains { $0.severity == .warning } ? .warn : .ok
        pendingKinds = currentKinds
        return result
    }
}

/// 插电后的电源路径和电池控制器需要短暂切换。稳定期内保留事实数据，
/// 但不把瞬时的 0W、电池辅助放电或未充电状态误报为故障。
struct PlugInTransitionFilter {
    let gracePeriod: TimeInterval

    private var wasOnExternalPower: Bool?
    private var pluggedInAt: Date?

    init(gracePeriod: TimeInterval = 45) {
        self.gracePeriod = gracePeriod
    }

    mutating func filter(_ info: PowerInfo, at now: Date) -> PowerInfo {
        let onExternalPower = info.isExternalPowerConnected
        defer { wasOnExternalPower = onExternalPower }

        guard onExternalPower else {
            pluggedInAt = nil
            return info
        }

        if wasOnExternalPower == false {
            pluggedInAt = now
        }

        // 一旦系统已开始正常取电并给电池充电，就提前结束稳定期。
        if info.isCharging == true, info.systemPowerInWatts > 0.5 {
            pluggedInAt = nil
            return info
        }

        guard let pluggedInAt,
              now.timeIntervalSince(pluggedInAt) < gracePeriod else {
            self.pluggedInAt = nil
            return info
        }

        var result = info
        result.isSettlingAfterPlugIn = true
        result.batteryStatus = "充电启动中"

        let transientWarningKinds: Set<String> = [
            "battery-assist", "not-charging", "low-intake", "no-pd"
        ]
        result.diagnostics.removeAll {
            $0.severity == .warning && transientWarningKinds.contains($0.kind)
        }
        result.diagnostics.insert(
            DiagnosticMessage(
                kind: "plug-in-settling",
                text: "电源已接入，充电系统正在稳定，通常需要约 30 秒。",
                severity: .info
            ),
            at: 0
        )
        result.status = result.diagnostics.contains { $0.severity == .warning } ? .warn : .ok
        return result
    }
}

// MARK: - 状态中心

@MainActor
final class PowerStore: ObservableObject {
    @Published var powerInfo: PowerInfo?
    @Published var isLoading = true
    @Published var history: [PowerHistoryPoint] = []
    @Published var errorMessage: String?

    // nonisolated(unsafe)：只在 MainActor 上写入，deinit 时独占访问，仅为让 deinit 能清理
    nonisolated(unsafe) private var timer: Timer?
    private var started = false
    // 订阅系统电源事件用的 run loop source（插拔/电量变化，事件到达立即刷新）
    // nonisolated(unsafe)：只在 MainActor 上写入，deinit 时独占访问
    nonisolated(unsafe) private var powerSourceRunLoopSource: CFRunLoopSource?
    private let updateInterval: TimeInterval = 2.0
    private let maxHistoryDuration: TimeInterval = 7200 // 保留 2 小时

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        start()
    }

    var menuBarLabel: String {
        guard let info = powerInfo else { return "--" }
        if info.systemPowerInWatts > 0.5 {
            return String(format: "%.0fW", info.systemPowerInWatts)
        }
        if let percent = info.batteryPercent {
            return "\(percent)%"
        }
        return "--"
    }

    deinit {
        // PowerStore 实际是进程生命周期单例（App 级 @StateObject），此处纯属工程卫生
        timer?.invalidate()
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        registerPowerSourceNotification()
        Task {
            await fetchOnce()
            await MainActor.run {
                self.timer = Timer.scheduledTimer(withTimeInterval: self.updateInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        await self?.fetchOnce()
                    }
                }
            }
        }
    }

    private func registerPowerSourceNotification() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let store = Unmanaged<PowerStore>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                await store.fetchOnce()
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private var debouncer = WarningDebouncer()
    private var plugInTransitionFilter = PlugInTransitionFilter()

    private func fetchOnce() async {
        do {
            let rawInfo = try await PowerMonitor.fetch()
            let transitionFiltered = plugInTransitionFilter.filter(rawInfo, at: rawInfo.sampledAt)
            let info = debouncer.filter(transitionFiltered)
            checkTransitions(old: powerInfo, new: info)
            self.powerInfo = info
            self.isLoading = false
            self.errorMessage = nil

            let point = PowerHistoryPoint(
                timestamp: Date(),
                watts: info.systemPowerInWatts,
                batteryWatts: info.batteryRealWatts ?? 0
            )
            self.history.append(point)
            let cutoff = Date().addingTimeInterval(-maxHistoryDuration)
            if let firstValid = self.history.firstIndex(where: { $0.timestamp >= cutoff }), firstValid > 0 {
                self.history.removeFirst(firstValid)
            }

        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }

    // MARK: 状态跃迁通知

    private func checkTransitions(old: PowerInfo?, new: PowerInfo) {
        guard let old = old else { return }

        // 开始充电
        if old.isCharging != true && new.isCharging == true {
            notify(title: "开始充电",
                   body: "适配器\(new.adapterLimitWatts.map { " \($0)W" } ?? "")，当前电量 \(new.batteryPercent ?? 0)%")
        }

        // 充满
        if (old.batteryPercent ?? 0) < 100, (new.batteryPercent ?? 0) >= 100, new.adapterLimitWatts != nil {
            notify(title: "电池已充满", body: "可以拔掉电源了")
        }

        // 低电量（放电中跨过 20%）
        if (old.batteryPercent ?? 100) > 20, let p = new.batteryPercent, p <= 20, new.adapterLimitWatts == nil {
            notify(title: "电量偏低", body: "剩余 \(p)%，建议接入电源")
        }

        // 接电但未充电（状态新出现时提醒一次）
        func notChargingWhilePlugged(_ info: PowerInfo) -> Bool {
            info.diagnostics.contains { $0.kind == "not-charging" }
        }
        if notChargingWhilePlugged(new) && !notChargingWhilePlugged(old) {
            notify(title: "接电但未充电", body: "稳定期后仍未开始充电；检查优化充电、AlDente 或适配器状态")
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
