import Foundation
import IOKit

// MARK: - SMC 实时功率

/// 读取 SMC 浮点功率键。PDTR（DC 输入）/PSTR（系统总功耗）亚秒级刷新，
/// 弥补注册表遥测和电池电量计几十秒才更新一次的滞后。
final class SMCPowerReader: @unchecked Sendable {
    static let shared = SMCPowerReader()

    // AppleSMC 用户客户端协议常量
    private static let kernelIndexSMC: UInt32 = 2   // kSMCHandleYPCEvent
    private static let cmdReadKey: UInt8 = 5        // kSMCReadKey
    private static let cmdGetKeyInfo: UInt8 = 9     // kSMCGetKeyInfo

    // @unchecked Sendable 依据：connection 在 init 后只读，
    // AppleSMC 用户客户端的 IOConnectCallStructMethod 本身线程安全
    private let connection: io_connect_t

    private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
    private struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private init() {
        var conn: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service != 0 {
            IOServiceOpen(service, mach_task_self_, 0, &conn)
            IOObjectRelease(service)
        }
        connection = conn
    }

    private func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(connection, Self.kernelIndexSMC, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outSize)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    /// 读取 flt 类型键，返回瓦特；键不存在或类型不符返回 nil
    func readWatts(_ key: String) -> Double? {
        guard connection != 0 else { return nil }
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = Self.cmdGetKeyInfo
        guard let info = call(&input),
              info.keyInfo.dataSize == 4,
              info.keyInfo.dataType == fourCC("flt ") else { return nil }
        input.keyInfo = info.keyInfo
        input.data8 = Self.cmdReadKey
        guard let out = call(&input) else { return nil }
        let b = out.bytes
        let raw = UInt32(b.0) | (UInt32(b.1) << 8) | (UInt32(b.2) << 16) | (UInt32(b.3) << 24)
        let value = Double(Float(bitPattern: raw))
        return value.isFinite ? value : nil
    }
}

// MARK: - Power Monitor

enum PowerMonitor {
    static func fetch() async throws -> PowerInfo {
        let props = try batteryProperties()
        let smcDcIn = SMCPowerReader.shared.readWatts("PDTR")
        let smcSystem = SMCPowerReader.shared.readWatts("PSTR")
        return parse(props, smcDcIn: smcDcIn, smcSystem: smcSystem)
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

    // internal 以便单元测试注入 mock 注册表字典和 SMC 值
    static func parse(_ props: [String: Any], smcDcIn: Double?, smcSystem: Double?) -> PowerInfo {
        // 电量百分比（Apple Silicon 上 CurrentCapacity 即 0-100，兜底按 MaxCapacity 换算）
        var percent = props["CurrentCapacity"] as? Int
        if let cur = percent, let maxCap = props["MaxCapacity"] as? Int, maxCap > 0, maxCap != 100 {
            percent = cur * 100 / maxCap
        }

        let isCharging = props["IsCharging"] as? Bool
        let batteryReportsAC = (props["ExternalConnected"] as? Bool) ?? false
        let negotiatedPortPowerMw = (props["PortControllerInfo"] as? [[String: Any]] ?? [])
            .compactMap { $0["PortControllerMaxPower"] as? Int }
            .max() ?? 0
        let portReportsPD = negotiatedPortPowerMw > 0
        let powerPathStuck = portReportsPD && !batteryReportsAC
        let onAC = batteryReportsAC || portReportsPD
        let fullyCharged = (props["FullyCharged"] as? Bool) ?? false

        let status: String
        if powerPathStuck {
            status = "电源路径异常"
        } else if !onAC {
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
        // 回退只在确实接电时生效：AppleRawAdapterDetails 拔电后可能残留上一个充电器的记录
        if onAC, adapter["Watts"] == nil,
           let rawAdapters = props["AppleRawAdapterDetails"] as? [[String: Any]],
           let first = rawAdapters.first(where: { $0["Watts"] != nil }) {
            adapter = first
        }

        let systemPowerInMw = telemetry["SystemPowerIn"] as? Int
        let systemLoadMw = telemetry["SystemLoad"] as? Int

        // 拔电后适配器信息一律视为无效，防止残留值"复活"已拔掉的充电器
        let adapterWatts = onAC ? adapter["Watts"] as? Int : nil
        let adapterVoltage = onAC ? adapter["AdapterVoltage"] as? Int : nil
        let adapterCurrent = onAC ? adapter["Current"] as? Int : nil

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

        // 电量计功率 = 电压 × 电流（负值 = 放电）。注意电量计几十秒才刷新，只作回退
        let gaugeWatts: Double?
        if let v = voltage, let a = amperage {
            gaugeWatts = v * Double(a) / 1000
        } else {
            gaugeWatts = nil
        }

        // 实时功率优先走 SMC：输入 = PDTR，负载 = PSTR，电池 = 输入 - 负载。
        // 三者恒等自洽且亚秒级刷新；SMC 不可用时回退到注册表遥测/电量计。
        // 拔电后输入定义上就是 0，按 ExternalConnected 钳制。
        let systemPowerInWatts = onAC ? (smcDcIn ?? systemPowerInMw.map { Double($0) / 1000 } ?? 0) : 0
        let systemLoadWatts: Double?
        let batteryRealWatts: Double?
        // PDTR/PSTR 必须同源才做减法：接电时若 PDTR 缺失，输入回退到滞后遥测，
        // 与实时 PSTR 相减会得出失真的电池功率。拔电时输入恒为 0，PSTR 可单独使用。
        if let sys = smcSystem, !onAC || smcDcIn != nil {
            systemLoadWatts = sys
            batteryRealWatts = systemPowerInWatts - sys
        } else if let gauge = gaugeWatts {
            systemLoadWatts = systemPowerInWatts - gauge
            batteryRealWatts = gauge
        } else {
            systemLoadWatts = systemLoadMw.map { Double($0) / 1000 }
            batteryRealWatts = nil
        }

        let hasAdapter = adapterWatts != nil

        // Build diagnostics（kind 是稳定标识，供跨采样去抖；状态胶囊由可见诊断推导）
        var diagnostics: [DiagnosticMessage] = []

        if powerPathStuck {
            let negotiatedWatts = negotiatedPortPowerMw / 1000
            diagnostics.append(DiagnosticMessage(
                kind: "power-path-stuck",
                text: "USB-C 端口已协商 \(negotiatedWatts)W，但电池控制器未接通电源。请换另一个 USB-C 接口；若反复出现，请重启 Mac 并检查该接口。",
                severity: .warning
            ))
        }

        if systemPowerInWatts > 0 {
            diagnostics.append(DiagnosticMessage(
                kind: "input-ok",
                text: "当前电脑从电源拿到约 \(String(format: "%.1f", systemPowerInWatts))W",
                severity: .info
            ))
        }

        if onAC, !powerPathStuck, let real = batteryRealWatts {
            if real > 0.5 {
                diagnostics.append(DiagnosticMessage(
                    kind: "charging",
                    text: "电池正在充电，入电约 \(String(format: "%.1f", real))W。",
                    severity: .info
                ))
            } else if real < -2 {
                diagnostics.append(DiagnosticMessage(
                    kind: "battery-assist",
                    text: "电脑高负载运行中，电源供给不足，电池正在辅助放电 \(String(format: "%.1f", abs(real)))W。",
                    severity: .warning
                ))
            } else {
                diagnostics.append(DiagnosticMessage(
                    kind: "maintain",
                    text: "电源已接入，电池电量维持中。",
                    severity: .info
                ))
            }
        }

        // 接电但未充电（排除已充满的情况）
        if hasAdapter, !powerPathStuck, isCharging == false, (percent ?? 100) < 100 {
            var text = "接着电源但电池未充电。检查优化充电 / AlDente 等限充工具，或重新插拔让 PD 重新协商。"
            if let reason = notChargingReason, reason != 0 {
                text += "（NotChargingReason=\(reason)）"
            }
            diagnostics.append(DiagnosticMessage(kind: "not-charging", text: text, severity: .warning))
        }

        // 充电中但电池实际入电很低（临近充满的涓流阶段除外）
        if hasAdapter, isCharging == true, (percent ?? 100) < 95,
           let real = batteryRealWatts, real > 0, real < 8 {
            diagnostics.append(DiagnosticMessage(
                kind: "low-intake",
                text: "适配器已识别，但电池实际入电仅 \(String(format: "%.1f", real))W，可能是 PD 协商、线材、接口或充电控制状态异常。",
                severity: .warning
            ))
        }

        if let slow = slowChargingReason, slow != 0 {
            diagnostics.append(DiagnosticMessage(
                kind: "slow-charging",
                text: "充电正被系统限速（SlowChargingReason=\(slow)）。",
                severity: .warning
            ))
        }

        if let inhibit = chargerInhibitReason, inhibit != 0 {
            diagnostics.append(DiagnosticMessage(
                kind: "charger-inhibit",
                text: "充电器处于抑制状态（ChargerInhibitReason=\(inhibit)）。",
                severity: .warning
            ))
        }

        if let thermal = thermallyLimited, thermal > 0 {
            diagnostics.append(DiagnosticMessage(
                kind: "thermal",
                text: "电池曾出现温度限制充电记录。",
                severity: .warning
            ))
        }

        if let adapterW = adapterWatts {
            diagnostics.append(DiagnosticMessage(
                kind: "pd-ok",
                text: "适配器已协商 USB-C PD：上限 \(adapterW)W。",
                severity: .info
            ))
        } else if onAC {
            diagnostics.append(DiagnosticMessage(
                kind: "no-pd",
                text: "已接入 AC 但未读取到有效 PD 档位；优先检查线材、接口或重新插拔触发协商。",
                severity: .warning
            ))
        } else if let real = batteryRealWatts, real < 0 {
            diagnostics.append(DiagnosticMessage(
                kind: "on-battery",
                text: "电池供电中，放电功率约 \(String(format: "%.1f", abs(real)))W。",
                severity: .info
            ))
        }

        // DailyMinSoc/DailyMaxSoc 是今日电量波动记录，仅作信息展示
        let dailyMinSoc = findInt("DailyMinSoc", in: props)
        let dailyMaxSoc = findInt("DailyMaxSoc", in: props)
        if let minSoc = dailyMinSoc, let maxSoc = dailyMaxSoc {
            diagnostics.append(DiagnosticMessage(
                kind: "soc-range",
                text: "今日电量区间：最低 \(minSoc)%，最高 \(maxSoc)%。",
                severity: .info
            ))
        }

        // 状态胶囊由诊断推导：有任一橙色警告即"注意"，单一事实源
        let powerStatus: PowerStatus = diagnostics.contains { $0.severity == .warning } ? .warn : .ok

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
            sampledAt: Date(),
            isExternalPowerConnected: onAC,
            systemPowerInWatts: systemPowerInWatts,
            systemLoadWatts: systemLoadWatts,
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
            isSettlingAfterPlugIn: false,
            status: powerStatus,
            profiles: profiles,
            diagnostics: diagnostics
        )
    }
}
