import AppKit
import SwiftUI

// MARK: - App 入口

@main
struct MacPowerMonitorApp: App {
    @State private var store = PowerStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 800)

        MenuBarExtra {
            TrayMenuView(store: store)
        } label: {
            MenuBarLabelView(store: store)
        }
    }
}

struct MenuBarLabelView: View {
    let store: PowerStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
            Text(store.menuBarLabel)
        }
    }
}

struct TrayMenuView: View {
    let store: PowerStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let info = store.menuPowerInfo {
            Text("电源输入 \(String(format: "%.1f", info.systemPowerInWatts))W")
            if let percent = info.batteryPercent {
                Text("电池 \(percent)%\(batteryStateSuffix(info))")
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

    private func batteryStateSuffix(_ info: PowerInfo) -> String {
        if info.isSettlingAfterPlugIn { return "（启动中）" }
        if info.isCharging == true { return "（充电中）" }
        return ""
    }
}

// MARK: - 主界面

struct ContentView: View {
    let store: PowerStore
    @AppStorage("appTheme") private var appTheme = "system"

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - 48)
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
                    } else if store.hasSample {
                        if store.errorMessage != nil, let info = store.powerInfo {
                            StaleDataBanner(sampledAt: info.sampledAt)
                        }
                        HeroSection(store: store, isWide: contentWidth >= 820)
                        MetricsSection(store: store, contentWidth: contentWidth)
                        BottomPanels(store: store, contentWidth: contentWidth)
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
                .frame(width: contentWidth)
                .padding(24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .background(DashboardWindowObserver(store: store).frame(width: 0, height: 0))
        .preferredColorScheme(colorScheme)
        .frame(minWidth: 560, minHeight: 500)
    }

    private var colorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// 数据读取失败但仍有旧数据可显示时的提示条
struct StaleDataBanner: View {
    let sampledAt: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("电源数据读取失败，以下显示的是 \(sampledAt.formatted(date: .omitted, time: .standard)) 的数据")
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Hero Section

struct HeroSection: View {
    let store: PowerStore
    let isWide: Bool

    var body: some View {
        let layout = isWide
            ? AnyLayout(HStackLayout(spacing: 20))
            : AnyLayout(VStackLayout(spacing: 20))
        layout {
            LivePowerMeter(store: store)
                .frame(width: isWide ? 340 : nil)
            MiniChartCard(store: store)
        }
    }
}

struct LivePowerMeter: View {
    let store: PowerStore

    var body: some View {
        if let info = store.powerInfo {
            PowerMeterView(info: info)
        }
    }
}

struct MiniChartCard: View {
    let store: PowerStore
    @State private var windowSeconds: Double = 1800

    var body: some View {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        let visibleHistory = store.history.filter { $0.timestamp >= cutoff }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("功率趋势")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                StatusPill(status: store.powerStatus)
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
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
            } else {
                Text("收集数据中...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
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
        info.isExternalPowerConnected ? info.systemPowerInWatts : abs(info.batteryRealWatts ?? 0)
    }

    // 量程：接电按适配器上限，电池模式按 60W 典型放电上限
    private var fullScaleWatts: Double {
        info.isExternalPowerConnected ? Double(info.adapterLimitWatts ?? 60) : 60
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
                Text(powerSummary)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("更新时间 \(info.sampledAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
            }

            HStack(spacing: 10) {
                PowerBreakdownItem(
                    label: "电源输入",
                    value: String(format: "%.1f W", info.systemPowerInWatts)
                )
                PowerBreakdownItem(
                    label: "系统负载",
                    value: info.systemLoadWatts != nil
                        ? String(format: "%.1f W", info.systemLoadWatts!)
                        : "-- W"
                )
                PowerBreakdownItem(
                    label: "电池充放",
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

    private var powerSummary: String {
        guard info.isExternalPowerConnected else { return "电池放电中" }
        if info.isSettlingAfterPlugIn { return "电源已接入，充电系统启动中" }
        if info.systemPowerInWatts > 0.5 {
            return "电脑从电源拿到 \(String(format: "%.1f", info.systemPowerInWatts))W"
        }
        if (info.batteryPercent ?? 0) >= 100 { return "电源已接入，电池已充满" }
        return "电源已接入，当前未充电"
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
            let leftGutter: CGFloat = 42
            let rightGutter: CGFloat = 46
            let top: CGFloat = 16
            let bottom = size.height - 24
            let plotLeft = leftGutter
            let plotRight = size.width - rightGutter
            let plotWidth = plotRight - plotLeft

            let inputs = history.map { $0.watts }
            let batts = history.map { $0.batteryWatts }

            // 步长取整到 1/2/5 × 10^n
            func niceStep(_ raw: Double) -> Double {
                let magnitude = pow(10, floor(log10(max(raw, 0.001))))
                let normalized = raw / magnitude
                return (normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10) * magnitude
            }

            // 左轴（蓝，电源输入）：0 ~ inTop，4 格
            let inStep = niceStep(max(inputs.max() ?? 1, 1) / 4)
            let inTop = inStep * 4

            // 右轴（绿，电池充放）：零点居中，±battHalf，上下各 2 格
            let battStep = niceStep(max(batts.map { abs($0) }.max() ?? 1, 1) / 2)
            let battHalf = battStep * 2

            func yForInput(_ value: Double) -> CGFloat {
                bottom - CGFloat(value / inTop) * (bottom - top)
            }
            func yForBatt(_ value: Double) -> CGFloat {
                let mid = (top + bottom) / 2
                return mid - CGFloat(value / battHalf) * (bottom - top) / 2
            }
            func xFor(_ index: Int) -> CGFloat {
                plotLeft + (history.count > 1 ? plotWidth / CGFloat(history.count - 1) * CGFloat(index) : 0)
            }

            // 网格线（共 5 行）+ 双侧刻度：左侧输入值，右侧电池值
            let axisFont = Font.system(size: 10, weight: .medium)
            func format(_ value: Double, step: Double, signed: Bool) -> String {
                let text = step < 1 ? String(format: "%.1f", value) : "\(Int(value))"
                return (signed && value > 0 ? "+" : "") + text + "W"
            }
            for i in 0...4 {
                let y = top + (bottom - top) / 4 * CGFloat(i)
                var line = Path()
                line.move(to: CGPoint(x: plotLeft, y: y))
                line.addLine(to: CGPoint(x: plotRight, y: y))
                if i == 2 {
                    // 中线 = 电池零点
                    context.stroke(line, with: .color(Color.green.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                } else {
                    context.stroke(line, with: .color(Color.secondary.opacity(0.12)), lineWidth: 1)
                }
                let inputValue = inTop * Double(4 - i) / 4
                context.draw(Text(format(inputValue, step: inStep, signed: false)).font(axisFont).foregroundColor(Color.accentColor.opacity(0.75)),
                             at: CGPoint(x: plotLeft - 6, y: y), anchor: .trailing)
                let battValue = battHalf * Double(2 - i) / 2
                context.draw(Text(format(battValue, step: battStep, signed: true)).font(axisFont).foregroundColor(Color.green.opacity(0.85)),
                             at: CGPoint(x: plotRight + 6, y: y), anchor: .leading)
            }

            func seriesPoints(_ values: [Double], yFor: (Double) -> CGFloat) -> [CGPoint] {
                values.enumerated().map { CGPoint(x: xFor($0.offset), y: yFor($0.element)) }
            }

            // Catmull-Rom 样条平滑，替代生硬的折线
            func smoothPath(_ points: [CGPoint]) -> Path {
                var path = Path()
                guard let first = points.first else { return path }
                path.move(to: first)
                guard points.count > 1 else { return path }
                for i in 1..<points.count {
                    let p0 = points[max(i - 2, 0)]
                    let p1 = points[i - 1]
                    let p2 = points[i]
                    let p3 = points[min(i + 1, points.count - 1)]
                    let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                    let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                    path.addCurve(to: p2, control1: c1, control2: c2)
                }
                return path
            }

            let softStroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)

            // 电源输入：面积（到左轴零点=底部）+ 主线
            let inputPoints = seriesPoints(inputs, yFor: yForInput)
            var areaPath = smoothPath(inputPoints)
            areaPath.addLine(to: CGPoint(x: plotRight, y: bottom))
            areaPath.addLine(to: CGPoint(x: plotLeft, y: bottom))
            areaPath.closeSubpath()
            context.fill(areaPath, with: .color(Color.accentColor.opacity(0.08)))
            let inputLine = smoothPath(inputPoints)
            context.stroke(inputLine, with: .color(Color.accentColor.opacity(0.3)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            context.stroke(inputLine, with: .color(Color.accentColor), style: softStroke)

            // 电池充放电：中线上方=充电，下方=放电
            context.stroke(smoothPath(seriesPoints(batts, yFor: yForBatt)), with: .color(Color.green), style: softStroke)

            // 时间标签
            if let first = history.first, let last = history.last {
                let fmt = Date.FormatStyle(date: .omitted, time: .shortened)
                let timeFont = Font.system(size: 10, weight: .medium)
                context.draw(Text(first.timestamp, format: fmt).font(timeFont).foregroundColor(.secondary),
                             at: CGPoint(x: plotLeft, y: size.height - 2), anchor: .bottomLeading)
                context.draw(Text(last.timestamp, format: fmt).font(timeFont).foregroundColor(.secondary),
                             at: CGPoint(x: plotRight, y: size.height - 2), anchor: .bottomTrailing)
            }

            // 悬停查看
            if let hx = hoverX, history.count > 1, hx >= plotLeft, hx <= plotRight {
                let index = min(max(Int(round((hx - plotLeft) / plotWidth * CGFloat(history.count - 1))), 0), history.count - 1)
                let point = history[index]
                let px = xFor(index)

                var cursor = Path()
                cursor.move(to: CGPoint(x: px, y: top - 4))
                cursor.addLine(to: CGPoint(x: px, y: bottom))
                context.stroke(cursor, with: .color(Color.secondary.opacity(0.4)), lineWidth: 1)

                let markers: [(CGFloat, Color)] = [
                    (yForInput(point.watts), Color.accentColor),
                    (yForBatt(point.batteryWatts), Color.green)
                ]
                for (my, color) in markers {
                    let marker = CGRect(x: px - 3.5, y: my - 3.5, width: 7, height: 7)
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
            guard NSApp.isActive else { return }
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
    }

}

// MARK: - Metrics Grid

struct MetricsSection: View {
    let store: PowerStore
    let contentWidth: CGFloat

    var body: some View {
        if let metrics = store.metrics {
            MetricsGridView(info: metrics, columnCount: max(1, min(5, Int((contentWidth + 16) / 196))))
        }
    }
}

struct MetricsGridView: View {
    let info: DashboardMetrics
    let columnCount: Int

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16), count: columnCount)

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
        if info.isSettlingAfterPlugIn { return "启动中" }
        if info.isCharging == true { return formatTime(info.timeToFull) }
        if info.isExternalPowerConnected && (info.batteryPercent ?? 0) >= 100 { return "已充满" }
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
    let store: PowerStore
    let contentWidth: CGFloat

    var body: some View {
        let isWide = contentWidth >= 820
        let panelWidth = isWide ? (contentWidth - 16) / 2 : contentWidth
        let layout = isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(spacing: 16))
        layout {
            PDProfilesPanel(store: store, panelWidth: panelWidth)
                .frame(width: panelWidth)
            DiagnosticsPanel(store: store)
                .frame(width: panelWidth)
        }
    }
}

struct PDProfilesPanel: View {
    let store: PowerStore
    let panelWidth: CGFloat

    var body: some View {
        let profiles = store.profiles
        let columnCount = max(1, Int((panelWidth - 40 + 10) / 110))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PD 档位")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(profiles.count) 个档位")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !profiles.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0)), count: columnCount), spacing: 10) {
                    ForEach(profiles) { profile in
                        let isActive = profile.index == store.activePDIndex
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
    let store: PowerStore

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

            if store.diagnostics.isEmpty {
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
                ForEach(store.diagnostics, id: \.kind) { diagnostic in
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
