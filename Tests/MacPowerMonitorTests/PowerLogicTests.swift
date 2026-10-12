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

    func testNegotiatedPDWithoutBatteryConnectionWarnsPowerPathStuck() {
        // 真实故障样本：端口控制器已协商 65W，但 AppleSmartBattery 仍报告未接电，PDTR 约为 0。
        var props = mockProps(
            onAC: false,
            percent: 74,
            isCharging: false,
            adapterWatts: 65,
            amperageMa: -627
        )
        props["PortControllerInfo"] = [
            ["PortControllerMaxPower": 0],
            ["PortControllerMaxPower": 65_000],
        ]

        let info = PowerMonitor.parse(props, smcDcIn: 0, smcSystem: 8)

        XCTAssertTrue(info.isExternalPowerConnected)
        XCTAssertEqual(info.adapterLimitWatts, 65)
        XCTAssertEqual(info.systemPowerInWatts, 0)
        XCTAssertEqual(info.batteryStatus, "电源路径异常")
        XCTAssertTrue(info.diagnostics.contains {
            $0.kind == "power-path-stuck" && $0.severity == .warning
        })
        XCTAssertEqual(info.status, .warn)
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

final class PlugInTransitionFilterTests: XCTestCase {

    func testSuppressesTransientWarningsDuringGracePeriodAfterObservedPlugIn() {
        var filter = PlugInTransitionFilter(gracePeriod: 45)
        let unplugged = PowerMonitor.parse(
            mockProps(onAC: false, percent: 60),
            smcDcIn: nil,
            smcSystem: 9)
        let plugged = PowerMonitor.parse(
            mockProps(onAC: true, percent: 60, isCharging: false, adapterWatts: 65),
            smcDcIn: 0,
            smcSystem: 9)
        let unpluggedAt = Date(timeIntervalSince1970: 1_000)

        _ = filter.filter(unplugged, at: unpluggedAt)
        let result = filter.filter(plugged, at: unpluggedAt.addingTimeInterval(5))

        XCTAssertTrue(result.isSettlingAfterPlugIn)
        XCTAssertEqual(result.batteryStatus, "充电启动中")
        XCTAssertFalse(result.diagnostics.contains { $0.severity == .warning })
        XCTAssertTrue(result.diagnostics.contains { $0.kind == "plug-in-settling" })
        XCTAssertEqual(result.status, .ok)
    }

    func testRestoresRealWarningAfterGracePeriodExpires() {
        var filter = PlugInTransitionFilter(gracePeriod: 45)
        let unplugged = PowerMonitor.parse(
            mockProps(onAC: false, percent: 60),
            smcDcIn: nil,
            smcSystem: 9)
        let plugged = PowerMonitor.parse(
            mockProps(onAC: true, percent: 60, isCharging: false, adapterWatts: 65),
            smcDcIn: 0,
            smcSystem: 9)
        let unpluggedAt = Date(timeIntervalSince1970: 1_000)

        _ = filter.filter(unplugged, at: unpluggedAt)
        _ = filter.filter(plugged, at: unpluggedAt.addingTimeInterval(5))
        let result = filter.filter(plugged, at: unpluggedAt.addingTimeInterval(51))

        XCTAssertFalse(result.isSettlingAfterPlugIn)
        XCTAssertEqual(result.batteryStatus, "已接电，未充电")
        XCTAssertTrue(result.diagnostics.contains { $0.kind == "not-charging" })
        XCTAssertEqual(result.status, .warn)
    }

    func testEndsGracePeriodAsSoonAsChargingActuallyStarts() {
        var filter = PlugInTransitionFilter(gracePeriod: 45)
        let unplugged = PowerMonitor.parse(
            mockProps(onAC: false, percent: 60),
            smcDcIn: nil,
            smcSystem: 9)
        let waiting = PowerMonitor.parse(
            mockProps(onAC: true, percent: 60, isCharging: false, adapterWatts: 65),
            smcDcIn: 0,
            smcSystem: 9)
        let charging = PowerMonitor.parse(
            mockProps(onAC: true, percent: 60, isCharging: true, adapterWatts: 65),
            smcDcIn: 32,
            smcSystem: 10)
        let unpluggedAt = Date(timeIntervalSince1970: 1_000)

        _ = filter.filter(unplugged, at: unpluggedAt)
        _ = filter.filter(waiting, at: unpluggedAt.addingTimeInterval(5))
        let result = filter.filter(charging, at: unpluggedAt.addingTimeInterval(37))

        XCTAssertFalse(result.isSettlingAfterPlugIn)
        XCTAssertEqual(result.batteryStatus, "充电中")
        XCTAssertTrue(result.diagnostics.contains { $0.kind == "charging" })
        XCTAssertFalse(result.diagnostics.contains { $0.kind == "plug-in-settling" })
        XCTAssertEqual(result.status, .ok)
    }
}
