import XCTest
import Observation
@testable import MacPowerMonitor

final class DashboardRefreshTests: XCTestCase {
    private func sample(watts: Double) -> PowerInfo {
        PowerMonitor.parse([
            "ExternalConnected": true,
            "IsCharging": true,
            "CurrentCapacity": 60,
            "MaxCapacity": 100,
            "AdapterDetails": [
                "Watts": 35,
                "AdapterVoltage": 20000,
                "Current": 1750,
                "UsbHvcMenu": [["Index": 3, "MaxVoltage": 20000, "MaxCurrent": 1750]],
            ],
        ], smcDcIn: watts, smcSystem: 5)
    }

    @MainActor
    func testBackgroundFreezesDashboardWhileMenuBarKeepsUpdating() async {
        let store = PowerStore(startAutomatically: false)
        let window = UUID()
        store.setDashboardActive(true, for: window)
        store.receiveSample(sample(watts: 10))

        store.setDashboardActive(false, for: window)
        let changed = RefreshFlag()
        withObservationTracking {
            _ = store.powerInfo
            _ = store.history
            _ = store.metrics
            _ = store.errorMessage
        } onChange: { changed.mark() }
        store.receiveSample(sample(watts: 20))

        XCTAssertEqual(store.powerInfo?.systemPowerInWatts, 10,
                       "后台采样不应使主界面失效并重新布局")
        XCTAssertEqual(store.history.count, 1,
                       "后台历史记录应留在缓冲区，不发布到主界面")
        XCTAssertEqual(store.menuBarLabel, "20W")
        XCTAssertFalse(changed.wasSet, "后台主界面不能收到可观察属性变化通知")
    }

    @MainActor
    func testReturningToForegroundPublishesLatestSampleAndBackgroundHistory() async {
        let store = PowerStore(startAutomatically: false)
        let window = UUID()
        store.setDashboardActive(true, for: window)
        store.receiveSample(sample(watts: 10))
        store.setDashboardActive(false, for: window)
        store.receiveSample(sample(watts: 20))
        store.receiveSample(sample(watts: 30))

        store.setDashboardActive(true, for: window)

        XCTAssertEqual(store.powerInfo?.systemPowerInWatts, 30)
        XCTAssertEqual(store.history.map(\.watts), [10, 20, 30])
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testClosingOneWindowDoesNotPauseAnotherActiveWindow() async {
        let store = PowerStore(startAutomatically: false)
        let first = UUID()
        let second = UUID()
        store.setDashboardActive(true, for: first)
        store.setDashboardActive(true, for: second)
        store.receiveSample(sample(watts: 10))
        store.setDashboardActive(false, for: first)
        store.receiveSample(sample(watts: 20))
        XCTAssertEqual(store.powerInfo?.systemPowerInWatts, 20)

        store.setDashboardActive(false, for: second)
        store.receiveSample(sample(watts: 30))
        XCTAssertEqual(store.powerInfo?.systemPowerInWatts, 20)
    }

    @MainActor
    func testRealtimePowerChangesDoNotInvalidateMetricsOrPDProfiles() async {
        let store = PowerStore(startAutomatically: false)
        store.setDashboardActive(true, for: UUID())
        store.receiveSample(sample(watts: 10))
        let changed = RefreshFlag()
        withObservationTracking {
            _ = store.metrics
            _ = store.profiles
            _ = store.activePDIndex
        } onChange: { changed.mark() }

        store.receiveSample(sample(watts: 20))

        XCTAssertEqual(store.powerInfo?.systemPowerInWatts, 20)
        XCTAssertEqual(store.profiles.map(\.id), [3])
        XCTAssertFalse(changed.wasSet, "实时功率变化不应重建指标和 PD 档位")
    }

    @MainActor
    func testUnchangedRoundedMenuLabelDoesNotInvalidateStatusItem() async {
        let store = PowerStore(startAutomatically: false)
        store.receiveSample(sample(watts: 10.1))
        let changed = RefreshFlag()
        withObservationTracking {
            _ = store.menuBarLabel
        } onChange: { changed.mark() }

        store.receiveSample(sample(watts: 10.4))

        XCTAssertEqual(store.menuBarLabel, "10W")
        XCTAssertFalse(changed.wasSet)
    }

    @MainActor
    func testBackgroundErrorAndRecoveryAreSynchronizedOnResume() async {
        let store = PowerStore(startAutomatically: false)
        let window = UUID()
        store.setDashboardActive(true, for: window)
        store.receiveSample(sample(watts: 10))
        store.setDashboardActive(false, for: window)
        store.receiveFailure("读取失败")
        XCTAssertNil(store.errorMessage)

        store.setDashboardActive(true, for: window)
        XCTAssertEqual(store.errorMessage, "读取失败")
        XCTAssertEqual(store.powerInfo?.systemPowerInWatts, 10)
        XCTAssertFalse(store.isLoading)

        store.setDashboardActive(false, for: window)
        store.receiveSample(sample(watts: 20))
        XCTAssertEqual(store.errorMessage, "读取失败")
        store.setDashboardActive(true, for: window)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.powerInfo?.systemPowerInWatts, 20)
    }

    @MainActor
    func testInitialBackgroundSamplingDoesNotBuildDashboardUntilWindowActivates() async {
        let store = PowerStore(startAutomatically: false)
        store.receiveSample(sample(watts: 10))
        XCTAssertNil(store.powerInfo)
        XCTAssertTrue(store.isLoading)
        XCTAssertFalse(store.hasSample)
        XCTAssertEqual(store.menuBarLabel, "10W")

        store.setDashboardActive(true, for: UUID())
        XCTAssertEqual(store.powerInfo?.systemPowerInWatts, 10)
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.hasSample)
    }
}

/// Observation 的回调是 Sendable；标记由锁保护，不跨线程读写裸变量。
private final class RefreshFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var wasSet: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}
