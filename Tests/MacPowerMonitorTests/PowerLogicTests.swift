import XCTest
@testable import MacPowerMonitor

/// 构造 mock 的 AppleSmartBattery 注册表字典
private func mockProps(
    onAC: Bool,
    percent: Int = 80,
    isCharging: Bool = false,
    fullyCharged: Bool = false,
    adapterWatts: Int? = nil,
    voltageMv: Int = 12800,
    amperageMa: Int = 0
) -> [String: Any] {
    var props: [String: Any] = [
        "ExternalConnected": onAC,
        "IsCharging": isCharging,
        "FullyCharged": fullyCharged,
        "CurrentCapacity": percent,
        "MaxCapacity": 100,
        "Voltage": voltageMv,
        "Amperage": amperageMa,
        "Temperature": 3050,
        "CycleCount": 100,
        "DesignCapacity": 4563,
        "NominalChargeCapacity": 3996,
    ]
    if let watts = adapterWatts {
        props["AdapterDetails"] = [
            "Watts": watts,
            "AdapterVoltage": 20000,
            "Current": 1740,
            "UsbHvcMenu": [
                ["Index": 0, "MaxVoltage": 5000, "MaxCurrent": 2960],
                ["Index": 3, "MaxVoltage": 20000, "MaxCurrent": 1740],
            ],
        ] as [String: Any]
    }
    return props
}

final class ParseTests: XCTestCase {

    func testUnpluggedDerivesBatteryFromPSTRAlone() {
        // 拔电：输入定义为 0，PDTR 缺失也应能用 PSTR 推出电池放电
        let info = PowerMonitor.parse(mockProps(onAC: false), smcDcIn: nil, smcSystem: 6.0)
        XCTAssertEqual(info.systemPowerInWatts, 0)
        XCTAssertEqual(info.systemLoadWatts, 6.0)
        XCTAssertEqual(info.batteryRealWatts, -6.0)
        XCTAssertEqual(info.status, .ok) // 用电池供电不是异常
    }

    func testOnACWithoutPDTRDoesNotMixSources() {
        // 接电但 PDTR 缺失：输入回退到滞后遥测，禁止与实时 PSTR 相减
        var props = mockProps(onAC: true, isCharging: true, adapterWatts: 35, amperageMa: -70)
        props["PowerTelemetryData"] = ["SystemPowerIn": 6300, "SystemLoad": 12600]
        let info = PowerMonitor.parse(props, smcDcIn: nil, smcSystem: 12.6)
        // 电池功率应回退到电量计 V×A（12.8V × -0.07A），而不是 6.3 - 12.6 = -6.3
        XCTAssertEqual(info.batteryRealWatts!, 12.8 * -70 / 1000, accuracy: 0.001)
    }

    func testChargingProducesChargingDiagnostic() {
        let info = PowerMonitor.parse(
            mockProps(onAC: true, percent: 50, isCharging: true, adapterWatts: 35),
            smcDcIn: 30, smcSystem: 10)
        XCTAssertEqual(info.batteryRealWatts, 20)
        XCTAssertTrue(info.diagnostics.contains { $0.kind == "charging" })
        XCTAssertEqual(info.status, .ok)
    }

    func testPluggedNotChargingWarns() {
        let info = PowerMonitor.parse(
            mockProps(onAC: true, percent: 80, isCharging: false, adapterWatts: 35),
            smcDcIn: 5, smcSystem: 5)
        XCTAssertTrue(info.diagnostics.contains { $0.kind == "not-charging" && $0.severity == .warning })
        XCTAssertEqual(info.status, .warn)
    }

    func testFullBatteryLowInputIsNormal() {
        // 满电挂机低输入是正常状态，不得告警（曾出现过的误报）
        let info = PowerMonitor.parse(
            mockProps(onAC: true, percent: 100, isCharging: false, fullyCharged: true, adapterWatts: 35),
            smcDcIn: 4.2, smcSystem: 4.2)
        XCTAssertEqual(info.status, .ok)
        XCTAssertFalse(info.diagnostics.contains { $0.severity == .warning })
    }

    func testActivePDIndexMatchesNegotiatedVoltage() {
        let info = PowerMonitor.parse(
            mockProps(onAC: true, percent: 100, fullyCharged: true, adapterWatts: 35),
            smcDcIn: 4, smcSystem: 4)
        XCTAssertEqual(info.activePDIndex, 3) // AdapterVoltage 20000mV → 20V 档
    }

    func testBatteryHealth() {
        let info = PowerMonitor.parse(mockProps(onAC: false), smcDcIn: nil, smcSystem: 5)
        XCTAssertEqual(info.healthPercent, 3996 * 100 / 4563)
        XCTAssertEqual(info.cycleCount, 100)
    }

    func testUnpluggedAdapterDoesNotResurrect() {
        // 拔电后即使注册表残留适配器字段，也不得识别出适配器
        let info = PowerMonitor.parse(
            mockProps(onAC: false, adapterWatts: 35),
            smcDcIn: nil, smcSystem: 5)
        XCTAssertNil(info.adapterLimitWatts)
    }
}

final class DebounceTests: XCTestCase {

    func testWarningNeedsTwoConsecutiveSamples() {
        var debouncer = WarningDebouncer()
        let raw = PowerMonitor.parse(
            mockProps(onAC: true, percent: 80, isCharging: false, adapterWatts: 35),
            smcDcIn: 5, smcSystem: 5)

        // 第一次采样：警告被抑制，状态正常
        let first = debouncer.filter(raw)
        XCTAssertFalse(first.diagnostics.contains { $0.severity == .warning })
        XCTAssertEqual(first.status, .ok)

        // 第二次采样连续命中：警告展示，状态转为注意
        let second = debouncer.filter(raw)
        XCTAssertTrue(second.diagnostics.contains { $0.kind == "not-charging" })
        XCTAssertEqual(second.status, .warn)

        // 条件消失后立即恢复正常
        let okRaw = PowerMonitor.parse(mockProps(onAC: false), smcDcIn: nil, smcSystem: 5)
        let third = debouncer.filter(okRaw)
        XCTAssertEqual(third.status, .ok)
    }
}
