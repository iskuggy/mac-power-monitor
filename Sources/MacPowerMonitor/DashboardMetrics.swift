/// 慢变化的指标独立比较，实时功率和采样时间变化不再使指标网格失效。
struct DashboardMetrics: Equatable {
    let adapterLimitWatts: Int?
    let adapterProtocol: String?
    let amperage: Int?
    let voltage: Double?
    let batteryPercent: Int?
    let batteryStatus: String?
    let isCharging: Bool?
    let isExternalPowerConnected: Bool
    let isSettlingAfterPlugIn: Bool
    let timeToFull: Int?
    let timeRemaining: Int?
    let temperature: Double?
    let cycleCount: Int?
    let healthPercent: Int?

    init(_ info: PowerInfo) {
        adapterLimitWatts = info.adapterLimitWatts
        adapterProtocol = info.adapterProtocol
        amperage = info.amperage
        voltage = info.voltage
        batteryPercent = info.batteryPercent
        batteryStatus = info.batteryStatus
        isCharging = info.isCharging
        isExternalPowerConnected = info.isExternalPowerConnected
        isSettlingAfterPlugIn = info.isSettlingAfterPlugIn
        timeToFull = info.timeToFull
        timeRemaining = info.timeRemaining
        temperature = info.temperature
        cycleCount = info.cycleCount
        healthPercent = info.healthPercent
    }
}
