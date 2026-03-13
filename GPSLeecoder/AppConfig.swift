import Foundation

enum SaveMode: String, CaseIterable {
    case session  // Start-to-stop = 1 file
    case daily    // Split at midnight
}

enum AppConfig {
    static let iCloudContainerIdentifier = "iCloud.com.aumosita.GPSLeecoder"

    // Defaults
    static let defaultFlushIntervalMinutes: Int = 10
    static let defaultRecordIntervalSeconds: Int = 30
    static let defaultDistanceFilterMeters: Int = 10
    static let defaultAccuracyFilterMeters: Int = 100

    // Power saving defaults
    static let defaultHwDistanceFilter: Bool = true
    static let defaultActivityTypeFitness: Bool = true
    static let defaultDutyCycling: Bool = false
    static let defaultStationaryPowerSave: Bool = true
    static let defaultMaxPerformance: Bool = false
}
