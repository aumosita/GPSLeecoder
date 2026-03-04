import Foundation

enum SaveMode: String, CaseIterable {
    case session  // Start-to-stop = 1 file
    case daily    // Split at midnight
}

enum AppConfig {
    // Replace this with your actual iCloud container ID after enabling iCloud capability
    // in Signing & Capabilities. Typical format: "iCloud.<your.bundle.identifier>"
    static let iCloudContainerIdentifier: String = "iCloud.com.leecoder.GPSLogger"

    // Default flush interval (minutes) for writing GPX to iCloud
    static let defaultFlushIntervalMinutes: Int = 10

    /// Threshold: record interval >= this value triggers intermittent GPS mode
    static let intermittentGPSThreshold: Int = 5
}
