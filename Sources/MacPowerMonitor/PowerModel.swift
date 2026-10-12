import SwiftUI

// MARK: - 数据模型
// 全部为值类型；表现层信息只有 DiagnosticMessage.color 这一个派生属性

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

enum DiagnosticSeverity: Sendable, Hashable {
    case info, warning
}

struct DiagnosticMessage: Hashable {
    let kind: String   // 稳定标识，用于跨采样去抖（text 含动态数字，不能作 key）
    let text: String
    let severity: DiagnosticSeverity

    // 表现层映射：模型只存 severity，颜色在 View 侧派生
    var color: Color { severity == .warning ? .orange : .green }
}

struct PowerInfo: Sendable {
    let sampledAt: Date                 // 本次采样时间（读取失败时 UI 据此提示数据陈旧）
    let isExternalPowerConnected: Bool  // 物理电源连接状态，不能用适配器详情是否存在来替代
    let systemPowerInWatts: Double      // 总输入功率 = SystemPowerIn
    let systemLoadWatts: Double?        // 系统负载 = 输入 - 电池实测（遥测 SystemLoad 滞后不可靠）
    let batteryRealWatts: Double?       // 电池端实测功率 = 电压 × 电流（负值 = 放电）
    let adapterLimitWatts: Int?         // 适配器上限 = Watts
    let adapterProtocol: String?
    let amperage: Int?
    let voltage: Double?
    let batteryPercent: Int?
    var batteryStatus: String?
    let isCharging: Bool?
    let timeToFull: Int?
    let timeRemaining: Int?             // 放电剩余时间（分钟）
    let temperature: Double?
    let cycleCount: Int?                // 电池循环次数
    let healthPercent: Int?             // 健康度 = NominalChargeCapacity / DesignCapacity
    let activePDIndex: Int?             // 当前协商的 PD 档位 index
    var isSettlingAfterPlugIn: Bool     // 插电后充电控制器尚在切换状态
    var status: PowerStatus             // 由可见诊断推导；去抖过滤后由 PowerStore 重算
    let profiles: [PowerProfile]
    var diagnostics: [DiagnosticMessage]
}

struct PowerHistoryPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let watts: Double        // 电源输入
    let batteryWatts: Double // 电池实测（负 = 放电）
}
