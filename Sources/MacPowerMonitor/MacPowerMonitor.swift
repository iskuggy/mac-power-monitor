import IOKit
import SwiftUI
import UserNotifications

@main
struct MacPowerMonitorApp: App {
    @StateObject private var store = PowerStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 800)

        MenuBarExtra {
            TrayMenuView(store: store)
        } label: {
            Image(systemName: "bolt.fill")
            Text(store.menuBarLabel)
        }
    }
}

struct TrayMenuView: View {
    @ObservedObject var store: PowerStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let info = store.powerInfo {
            Text("电源输入 \(String(format: "%.1f", info.systemPowerInWatts))W")
            if let percent = info.batteryPercent {
                Text("电池 \(percent)%\(info.isCharging == true ? "（充电中）" : "")")
            }
            if let adapterW = info.adapterLimitWatts {
                Text("适配器上限 \(adapterW)W")
            }
            Divider()
        }
        Button("打开 Mac Power Monitor") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Divider()
        Button("退出") {
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class PowerStore: ObservableObject {
    @Published var powerInfo: PowerInfo?
    @Published var isLoading = true
    @Published var history: [PowerHistoryPoint] = []
    @Published var errorMessage: String?

    private var timer: Timer?
    private var started = false
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

    func start() {
        guard !started else { return }
        started = true
        Task {
            await fetchOnce()
            await MainActor.run {
                self.timer = Timer.scheduledTimer(withTimeInterval: self.updateInterval, repeats: true) { _ in
                    Task { @MainActor in
                        await self.fetchOnce()
                    }
                }
            }
        }
    }

    private func fetchOnce() async {
        do {
            let info = try await PowerMonitor.fetch()
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
            info.adapterLimitWatts != nil && info.isCharging == false && (info.batteryPercent ?? 100) < 100
        }
        if notChargingWhilePlugged(new) && !notChargingWhilePlugged(old) {
            notify(title: "接电但未充电", body: "检查优化充电 / AlDente，或重新插拔电源线")
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

struct ContentView: View {
    @ObservedObject var store: PowerStore
    @AppStorage("appTheme") private var appTheme = "system"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text("Mac Power Monitor")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    ThemeToggleButton(theme: $appTheme)
                }
                .padding(.horizontal, 4)

                if store.isLoading {
                    ProgressView("正在读取电源数据...")
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else if let info = store.powerInfo {
                    HeroSection(info: info, history: store.history)
                    MetricsGridView(info: info)
                    BottomPanels(info: info)
                } else if let error = store.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.red)
                        Text("读取失败")
                            .font(.title2)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 400)
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .preferredColorScheme(colorScheme)
    }

    private var colorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

struct PowerHistoryPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let watts: Double        // 电源输入
    let batteryWatts: Double // 电池实测（负 = 放电）
}

// MARK: - Hero Section

struct HeroSection: View {
    let info: PowerInfo
    let history: [PowerHistoryPoint]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                PowerMeterView(info: info)
                    .frame(width: 340)
                MiniChartCard(info: info, history: history)
            }

            VStack(spacing: 20) {
                PowerMeterView(info: info)
                MiniChartCard(info: info, history: history)
            }
        }
    }
}

struct MiniChartCard: View {
    let info: PowerInfo
    let history: [PowerHistoryPoint]
    @State private var windowSeconds: Double = 1800

    private var visibleHistory: [PowerHistoryPoint] {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        return history.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("功率趋势")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                StatusPill(status: info.status)
            }

            HStack(spacing: 12) {
                LegendDot(color: .accentColor, label: "电源输入")
                LegendDot(color: .green, label: "电池充放电")
                Spacer()
                Picker("", selection: $windowSeconds) {
                    Text("5分").tag(300.0)
                    Text("30分").tag(1800.0)
                    Text("2时").tag(7200.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            if visibleHistory.count > 1 {
                RealtimeMiniChartView(history: visibleHistory)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Text("收集数据中...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    let status: PowerStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch status {
        case .ok: return .green
        case .warn: return .orange
        case .danger: return .red
        }
    }

    private var statusText: String {
        switch status {
        case .ok: return "正常"
        case .warn: return "注意"
        case .danger: return "异常"
        }
    }
}

// MARK: - Theme Toggle

struct ThemeToggleButton: View {
    @Binding var theme: String

    var body: some View {
        Button(action: toggleTheme) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("切换主题")
    }

    private var iconName: String {
        switch theme {
        case "light": return "sun.max.fill"
        case "dark": return "moon.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    private func toggleTheme() {
        switch theme {
        case "system": theme = "light"
        case "light": theme = "dark"
        default: theme = "system"
        }
    }
}

// MARK: - Power Meter

struct PowerMeterView: View {
    let info: PowerInfo

    // 接电时显示电源输入，电池模式显示放电功率
    private var displayWatts: Double {
        info.adapterLimitWatts != nil ? info.systemPowerInWatts : abs(info.batteryRealWatts ?? 0)
    }

    // 量程：接电按适配器上限，电池模式按 60W 典型放电上限
    private var fullScaleWatts: Double {
        Double(info.adapterLimitWatts ?? 60)
    }

    private var progress: Double {
        fullScaleWatts > 0 ? min(displayWatts / fullScaleWatts, 1.0) : 0
    }

    private var color: Color {
        switch info.status {
        case .ok: return .green
        case .warn: return .orange
        case .danger: return .red
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 16)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: progress)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color.opacity(0.3), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .blur(radius: 8)
                    .animation(.easeInOut(duration: 0.6), value: progress)

                VStack(spacing: 4) {
                    Text(String(format: "%.1f", displayWatts))
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                    Text("W / \(Int(fullScaleWatts))W")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 200)

            VStack(spacing: 4) {
                Text(info.adapterLimitWatts != nil
                     ? (info.systemPowerInWatts > 0
                        ? "电脑从电源拿到 \(String(format: "%.1f", info.systemPowerInWatts))W"
                        : "电源已接入，电池已充满")
                     : "电池放电中")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("更新时间 \(Date().formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
            }

            HStack(spacing: 10) {
                PowerBreakdownItem(
                    label: "系统负载",
                    value: info.systemLoadWatts != nil
                        ? String(format: "%.1f W", info.systemLoadWatts!)
                        : "-- W"
                )
                PowerBreakdownItem(
                    label: "电池入电",
                    value: info.batteryPowerWatts != nil
                        ? String(format: "%.1f W", info.batteryPowerWatts!)
                        : "-- W"
                )
                PowerBreakdownItem(
                    label: "电池实测",
                    value: info.batteryRealWatts != nil
                        ? String(format: "%+.1f W", info.batteryRealWatts!)
                        : "-- W"
                )
            }
        }
        .padding(28)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct PowerBreakdownItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Realtime Mini Chart (for Hero section)

struct RealtimeMiniChartView: View {
    let history: [PowerHistoryPoint]
    @State private var hoverX: CGFloat?

    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 20
            let bottom = size.height - 28
            let inputs = history.map { $0.watts }
            let batts = history.map { $0.batteryWatts }
            let maxV = max(inputs.max() ?? 1, batts.max() ?? 0, 1)
            let minV = min(inputs.min() ?? 0, batts.min() ?? 0, 0)

            func yFor(_ value: Double) -> CGFloat {
                bottom - CGFloat((value - minV) / (maxV - minV)) * (bottom - top)
            }
            func xFor(_ index: Int) -> CGFloat {
                history.count > 1 ? size.width / CGFloat(history.count - 1) * CGFloat(index) : 0
            }
            let zeroY = yFor(0)

            // Grid lines
            for i in 1..<4 {
                let y = top + (bottom - top) / 4 * CGFloat(i)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(Color.secondary.opacity(0.1)), lineWidth: 1)
            }

            // Zero line
            var zeroPath = Path()
            zeroPath.move(to: CGPoint(x: 0, y: zeroY))
            zeroPath.addLine(to: CGPoint(x: size.width, y: zeroY))
            context.stroke(zeroPath, with: .color(Color.secondary.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            func seriesPath(_ values: [Double]) -> Path {
                var path = Path()
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: xFor(index), y: yFor(value))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }

            // 电源输入：面积 + 主线
            var areaPath = seriesPath(inputs)
            areaPath.addLine(to: CGPoint(x: size.width, y: zeroY))
            areaPath.addLine(to: CGPoint(x: 0, y: zeroY))
            areaPath.closeSubpath()
            context.fill(areaPath, with: .color(Color.accentColor.opacity(0.08)))
            let inputLine = seriesPath(inputs)
            context.stroke(inputLine, with: .color(Color.accentColor.opacity(0.3)), lineWidth: 5)
            context.stroke(inputLine, with: .color(Color.accentColor), lineWidth: 2)

            // 电池充放电：细线（正=充电，负=放电）
            context.stroke(seriesPath(batts), with: .color(Color.green), lineWidth: 1.5)

            // 纵轴标签
            let axisFont = Font.system(size: 11, weight: .medium)
            context.draw(Text("\(Int(maxV))W").font(axisFont).foregroundColor(.secondary),
                         at: CGPoint(x: 4, y: top - 8), anchor: .leading)
            context.draw(Text("0W").font(axisFont).foregroundColor(.secondary),
                         at: CGPoint(x: 4, y: zeroY - 8), anchor: .leading)
            if minV < -0.5 {
                context.draw(Text("\(Int(minV))W").font(axisFont).foregroundColor(.secondary),
                             at: CGPoint(x: 4, y: bottom + 2), anchor: .topLeading)
            }

            // 时间标签（anchor 避免截断）
            if let first = history.first, let last = history.last {
                let fmt = Date.FormatStyle(date: .omitted, time: .shortened)
                let timeFont = Font.system(size: 10, weight: .medium)
                context.draw(Text(first.timestamp, format: fmt).font(timeFont).foregroundColor(.secondary),
                             at: CGPoint(x: 4, y: size.height - 2), anchor: .bottomLeading)
                context.draw(Text(last.timestamp, format: fmt).font(timeFont).foregroundColor(.secondary),
                             at: CGPoint(x: size.width - 4, y: size.height - 2), anchor: .bottomTrailing)
            }

            // 悬停查看
            if let hx = hoverX, history.count > 1 {
                let index = min(max(Int(round(hx / size.width * CGFloat(history.count - 1))), 0), history.count - 1)
                let point = history[index]
                let px = xFor(index)

                var cursor = Path()
                cursor.move(to: CGPoint(x: px, y: top - 4))
                cursor.addLine(to: CGPoint(x: px, y: bottom))
                context.stroke(cursor, with: .color(Color.secondary.opacity(0.4)), lineWidth: 1)

                for (value, color) in [(point.watts, Color.accentColor), (point.batteryWatts, Color.green)] {
                    let marker = CGRect(x: px - 3.5, y: yFor(value) - 3.5, width: 7, height: 7)
                    context.fill(Path(ellipseIn: marker), with: .color(color))
                }

                let timeText = point.timestamp.formatted(date: .omitted, time: .standard)
                let label = Text("\(timeText)  输入 \(String(format: "%.1f", point.watts))W  电池 \(String(format: "%+.1f", point.batteryWatts))W")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                let anchor: UnitPoint = px > size.width / 2 ? .topTrailing : .topLeading
                let labelX = px > size.width / 2 ? px - 8 : px + 8
                context.draw(label, at: CGPoint(x: labelX, y: 2), anchor: anchor)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
    }
}

// MARK: - Metrics Grid

struct MetricsGridView: View {
    let info: PowerInfo

    var body: some View {
        let columns = [
            GridItem(.adaptive(minimum: 180, maximum: 250))
        ]

        LazyVGrid(columns: columns, spacing: 16) {
            MetricCard(
                title: "适配器能力",
                value: info.adapterLimitWatts != nil ? "\(info.adapterLimitWatts!)W" : "--",
                subtitle: info.adapterProtocol ?? "未识别",
                icon: "powerplug.fill",
                color: .blue
            )
            MetricCard(
                title: "电池电流",
                value: info.amperage != nil ? "\(info.amperage!)mA" : "--",
                subtitle: info.voltage != nil ? String(format: "%.2fV", info.voltage!) : "--",
                icon: "bolt.fill",
                color: .green
            )
            MetricCard(
                title: "电量状态",
                value: info.batteryPercent != nil ? "\(info.batteryPercent!)%" : "--",
                subtitle: info.batteryStatus ?? "未知",
                icon: "battery.100",
                color: .orange
            )
            MetricCard(
                title: info.isCharging == true ? "预计充满" : "预计续航",
                value: timeCardValue,
                subtitle: info.temperature != nil ? "电池 \(String(format: "%.1f", info.temperature!))°C" : "--",
                icon: "clock.fill",
                color: .red
            )
            MetricCard(
                title: "电池健康",
                value: info.healthPercent != nil ? "\(info.healthPercent!)%" : "--",
                subtitle: info.cycleCount != nil ? "循环 \(info.cycleCount!) 次" : "--",
                icon: "heart.fill",
                color: .pink
            )
        }
    }

    private var timeCardValue: String {
        if info.isCharging == true { return formatTime(info.timeToFull) }
        if info.adapterLimitWatts != nil && (info.batteryPercent ?? 0) >= 100 { return "已充满" }
        return formatTime(info.timeRemaining)
    }

    private func formatTime(_ minutes: Int?) -> String {
        guard let minutes = minutes else { return "无估算" }
        if minutes < 60 { return "\(minutes)分钟" }
        return "\(minutes / 60)小时\(minutes % 60)分"
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fontDesign(.monospaced)
                .lineLimit(1)
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Bottom Panels

struct BottomPanels: View {
    let info: PowerInfo

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                PDProfilesPanel(info: info)
                DiagnosticsPanel(info: info)
            }

            VStack(spacing: 16) {
                PDProfilesPanel(info: info)
                DiagnosticsPanel(info: info)
            }
        }
    }
}

struct PDProfilesPanel: View {
    let info: PowerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PD 档位")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(info.profiles.count) 个档位")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !info.profiles.isEmpty {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 100))
                ], spacing: 10) {
                    ForEach(info.profiles) { profile in
                        let isActive = profile.index == info.activePDIndex
                        VStack(spacing: 4) {
                            Text("\(profile.watts)W")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundStyle(Color.accentColor)
                            Text("\(String(format: "%.0f", profile.voltageV))V × \(String(format: "%.2f", profile.currentA))A")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // 始终占位，保证各档位格子等高
                            Text(isActive ? "当前使用" : " ")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(isActive ? Color.accentColor : Color.clear)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                    }
                }
            } else {
                Text("暂未读取到 PD 档位。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct DiagnosticsPanel: View {
    let info: PowerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("系统诊断")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("实时判断")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if info.diagnostics.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                    Text("电源状态正常，无异常诊断。")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                }
                .padding(14)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                )
            } else {
                ForEach(info.diagnostics, id: \.self) { diagnostic in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(diagnostic.color)
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)

                        Text(diagnostic.text)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(diagnostic.color)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()
                    }
                    .padding(14)
                    .background(diagnostic.color.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(diagnostic.color.opacity(0.2), lineWidth: 1)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Data Model

enum PowerStatus {
    case ok, warn, danger
}

struct PowerProfile: Identifiable, Hashable {
    let id = UUID()
    let index: Int
    let voltageV: Double
    let currentA: Double
    let watts: Int
}

struct DiagnosticMessage: Hashable {
    let text: String
    let color: Color
}

struct PowerInfo: Sendable {
    let systemPowerInWatts: Double      // 总输入功率 = SystemPowerIn
    let systemLoadWatts: Double?        // 系统负载 = SystemLoad
    let batteryPowerWatts: Double?      // 电池入电结余 = SystemPowerIn - SystemLoad
    let batteryRealWatts: Double?       // 电池端实测功率 = 电压 × 电流（负值 = 放电）
    let adapterLimitWatts: Int?         // 适配器上限 = Watts
    let adapterProtocol: String?
    let amperage: Int?
    let voltage: Double?
    let batteryPercent: Int?
    let batteryStatus: String?
    let isCharging: Bool?
    let timeToFull: Int?
    let timeRemaining: Int?             // 放电剩余时间（分钟）
    let temperature: Double?
    let cycleCount: Int?                // 电池循环次数
    let healthPercent: Int?             // 健康度 = NominalChargeCapacity / DesignCapacity
    let activePDIndex: Int?             // 当前协商的 PD 档位 index
    let status: PowerStatus
    let profiles: [PowerProfile]
    let diagnostics: [DiagnosticMessage]
}

// MARK: - Power Monitor

enum PowerMonitor {
    static func fetch() async throws -> PowerInfo {
        let props = try batteryProperties()
        return parse(props)
    }

    // 直接读 IOKit 注册表，替代旧的 pmset/ioreg 子进程 + 正则解析
    private static func batteryProperties() throws -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            throw NSError(domain: "PowerMonitor", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到 AppleSmartBattery 服务"])
        }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            throw NSError(domain: "PowerMonitor", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "读取电池注册表属性失败"])
        }
        return props
    }

    // 根级优先，找不到再递归进嵌套字典/数组（对应旧版全文搜索的语义）
    private static func findValue(_ key: String, in container: Any) -> Any? {
        if let dict = container as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values {
                if let found = findValue(key, in: value) { return found }
            }
        } else if let array = container as? [Any] {
            for element in array {
                if let found = findValue(key, in: element) { return found }
            }
        }
        return nil
    }

    private static func findInt(_ key: String, in container: Any) -> Int? {
        findValue(key, in: container) as? Int
    }

    private static func parse(_ props: [String: Any]) -> PowerInfo {
        // 电量百分比（Apple Silicon 上 CurrentCapacity 即 0-100，兜底按 MaxCapacity 换算）
        var percent = props["CurrentCapacity"] as? Int
        if let cur = percent, let maxCap = props["MaxCapacity"] as? Int, maxCap > 0, maxCap != 100 {
            percent = cur * 100 / maxCap
        }

        let isCharging = props["IsCharging"] as? Bool
        let onAC = (props["ExternalConnected"] as? Bool) ?? false
        let fullyCharged = (props["FullyCharged"] as? Bool) ?? false

        let status: String
        if !onAC {
            status = "放电中"
        } else if isCharging == true {
            status = "充电中"
        } else if fullyCharged {
            status = "已充满"
        } else {
            status = "已接电，未充电"
        }

        let telemetry = props["PowerTelemetryData"] as? [String: Any] ?? [:]
        var adapter = props["AdapterDetails"] as? [String: Any] ?? [:]
        if adapter["Watts"] == nil,
           let rawAdapters = props["AppleRawAdapterDetails"] as? [[String: Any]],
           let first = rawAdapters.first(where: { $0["Watts"] != nil }) {
            adapter = first
        }

        let systemPowerInMw = telemetry["SystemPowerIn"] as? Int
        let systemLoadMw = telemetry["SystemLoad"] as? Int

        let adapterWatts = adapter["Watts"] as? Int
        let adapterVoltage = adapter["AdapterVoltage"] as? Int
        let adapterCurrent = adapter["Current"] as? Int

        let voltage = (props["Voltage"] as? Int).map { Double($0) / 1000 }
        let amperage = props["Amperage"] as? Int
        let temp = (props["Temperature"] as? Int).map { Double($0) / 100 }
        let timeFull = props["AvgTimeToFull"] as? Int
        let timeRemaining = props["TimeRemaining"] as? Int

        // 充电异常排查用的原因码
        let notChargingReason = findInt("NotChargingReason", in: props)
        let slowChargingReason = findInt("SlowChargingReason", in: props)
        let chargerInhibitReason = findInt("ChargerInhibitReason", in: props)
        let thermallyLimited = findInt("TimeChargingThermallyLimited", in: props)

        // 电池健康：健康度 = 当前标称容量 / 设计容量
        let cycleCount = findInt("CycleCount", in: props)
        let healthPercent: Int?
        if let design = findInt("DesignCapacity", in: props), design > 0,
           let nominal = findInt("NominalChargeCapacity", in: props) {
            healthPercent = nominal * 100 / design
        } else {
            healthPercent = nil
        }

        // 电池端实测功率 = 电压 × 电流（负值 = 放电）
        let batteryRealWatts: Double?
        if let v = voltage, let a = amperage {
            batteryRealWatts = v * Double(a) / 1000
        } else {
            batteryRealWatts = nil
        }

        // Convert to watts
        // 总输入 = SystemPowerIn
        // 系统负载 = SystemLoad（电脑实际耗电）
        // 电池入电/结余 = SystemPowerIn - SystemLoad（剩余给电池的）
        let systemPowerInWatts = systemPowerInMw.map { Double($0) / 1000 } ?? 0
        let systemLoadWatts = systemLoadMw.map { Double($0) / 1000 }
        let batteryPowerWatts: Double?
        if let sysIn = systemPowerInMw, let sysLoad = systemLoadMw {
            batteryPowerWatts = Double(sysIn - sysLoad) / 1000
        } else {
            batteryPowerWatts = nil
        }

        // 用电池供电是正常状态，不算异常；异常只针对接电后的问题
        let hasAdapter = adapterWatts != nil
        var powerStatus: PowerStatus = .ok
        if hasAdapter {
            if let battPower = batteryPowerWatts, battPower < -5 {
                // Battery discharging significantly while on AC - check if adapter is undersized
                powerStatus = .warn
            } else if isCharging == true && systemPowerInWatts > 0 && systemPowerInWatts < 5 {
                // 只有充电中输入还偏低才算异常；满电挂机低输入是正常的
                powerStatus = .warn
            } else if isCharging == false && (percent ?? 100) < 100 {
                // 接着电源但没在充电，也没充满
                powerStatus = .warn
            }
        } else if onAC {
            // 接了 AC 但读不到适配器信息
            powerStatus = .warn
        }

        // Build diagnostics
        var diagnostics: [DiagnosticMessage] = []

        if systemPowerInWatts > 0 {
            diagnostics.append(DiagnosticMessage(
                text: "当前电脑从电源拿到约 \(String(format: "%.1f", systemPowerInWatts))W",
                color: .green
            ))
        }

        if let battPower = batteryPowerWatts {
            if battPower > 0 {
                diagnostics.append(DiagnosticMessage(
                    text: "电池正在充电，入电约 \(String(format: "%.1f", battPower))W。",
                    color: .green
                ))
            } else if battPower < -2 {
                diagnostics.append(DiagnosticMessage(
                    text: "电脑高负载运行中，电源供给不足，电池正在辅助放电 \(String(format: "%.1f", abs(battPower)))W。",
                    color: .orange
                ))
            } else {
                diagnostics.append(DiagnosticMessage(
                    text: "电源已接入，电池电量维持中。",
                    color: .green
                ))
            }
        }

        if isCharging == true && systemPowerInWatts > 0 && systemPowerInWatts < 5 {
            diagnostics.append(DiagnosticMessage(
                text: "充电中但电源输入偏低，可能是适配器功率不足或 PD 协商异常。",
                color: .orange
            ))
        }

        // 接电但未充电（排除已充满的情况）
        if hasAdapter, isCharging == false, (percent ?? 100) < 100 {
            var text = "接着电源但电池未充电。检查优化充电 / AlDente 等限充工具，或重新插拔让 PD 重新协商。"
            if let reason = notChargingReason, reason != 0 {
                text += "（NotChargingReason=\(reason)）"
            }
            diagnostics.append(DiagnosticMessage(text: text, color: .orange))
        }

        // 充电中但电池实际入电很低
        if hasAdapter, isCharging == true, let real = batteryRealWatts, real > 0, real < 8 {
            diagnostics.append(DiagnosticMessage(
                text: "适配器已识别，但电池实际入电仅 \(String(format: "%.1f", real))W，可能是 PD 协商、线材、接口或充电控制状态异常。",
                color: .orange
            ))
        }

        if let slow = slowChargingReason, slow != 0 {
            diagnostics.append(DiagnosticMessage(
                text: "充电正被系统限速（SlowChargingReason=\(slow)）。",
                color: .orange
            ))
        }

        if let inhibit = chargerInhibitReason, inhibit != 0 {
            diagnostics.append(DiagnosticMessage(
                text: "充电器处于抑制状态（ChargerInhibitReason=\(inhibit)）。",
                color: .orange
            ))
        }

        if let thermal = thermallyLimited, thermal > 0 {
            diagnostics.append(DiagnosticMessage(
                text: "电池曾出现温度限制充电记录。",
                color: .orange
            ))
        }

        if let adapterW = adapterWatts {
            diagnostics.append(DiagnosticMessage(
                text: "适配器已协商 USB-C PD：上限 \(adapterW)W。",
                color: .green
            ))
        } else if onAC {
            diagnostics.append(DiagnosticMessage(
                text: "已接入 AC 但未读取到有效 PD 档位；优先检查线材、接口或重新插拔触发协商。",
                color: .orange
            ))
        } else if let real = batteryRealWatts, real < 0 {
            diagnostics.append(DiagnosticMessage(
                text: "电池供电中，放电功率约 \(String(format: "%.1f", abs(real)))W。",
                color: .green
            ))
        }

        // DailyMinSoc/DailyMaxSoc 是今日电量波动记录，仅作信息展示
        let dailyMinSoc = findInt("DailyMinSoc", in: props)
        let dailyMaxSoc = findInt("DailyMaxSoc", in: props)
        if let minSoc = dailyMinSoc, let maxSoc = dailyMaxSoc {
            diagnostics.append(DiagnosticMessage(
                text: "今日电量区间：最低 \(minSoc)%，最高 \(maxSoc)%。",
                color: .green
            ))
        }

        // PD 档位
        var profiles: [PowerProfile] = []
        if let menu = findValue("UsbHvcMenu", in: props) as? [[String: Any]] {
            for (i, item) in menu.enumerated() {
                guard let maxVoltage = item["MaxVoltage"] as? Int,
                      let maxCurrent = item["MaxCurrent"] as? Int else { continue }
                profiles.append(PowerProfile(
                    index: item["Index"] as? Int ?? i,
                    voltageV: Double(maxVoltage) / 1000,
                    currentA: Double(maxCurrent) / 1000,
                    watts: (maxVoltage * maxCurrent) / 1_000_000
                ))
            }
        }

        // 当前协商档位：优先注册表的 UsbHvcHvcIndex，否则按协商电压就近匹配
        var activePDIndex = findInt("UsbHvcHvcIndex", in: props)
        if activePDIndex == nil, let av = adapterVoltage, !profiles.isEmpty {
            let negotiatedV = Double(av) / 1000
            activePDIndex = profiles.min(by: { abs($0.voltageV - negotiatedV) < abs($1.voltageV - negotiatedV) })?.index
        }

        let adapterProtocol: String?
        if adapterVoltage != nil && adapterCurrent != nil {
            adapterProtocol = "USB-C PD"
        } else if adapterWatts != nil || onAC {
            adapterProtocol = "AC Power"
        } else {
            adapterProtocol = nil
        }

        return PowerInfo(
            systemPowerInWatts: systemPowerInWatts,
            systemLoadWatts: systemLoadWatts,
            batteryPowerWatts: batteryPowerWatts,
            batteryRealWatts: batteryRealWatts,
            adapterLimitWatts: adapterWatts,
            adapterProtocol: adapterProtocol,
            amperage: amperage,
            voltage: voltage,
            batteryPercent: percent,
            batteryStatus: status,
            isCharging: isCharging,
            timeToFull: timeFull == 65535 ? nil : timeFull,
            timeRemaining: timeRemaining == 65535 ? nil : timeRemaining,
            temperature: temp,
            cycleCount: cycleCount,
            healthPercent: healthPercent,
            activePDIndex: activePDIndex,
            status: powerStatus,
            profiles: profiles,
            diagnostics: diagnostics
        )
    }
}
