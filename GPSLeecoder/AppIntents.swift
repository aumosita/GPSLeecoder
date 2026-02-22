import AppIntents
import CoreLocation

struct StartLoggingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start GPS Logging"
    static var description = IntentDescription("Start recording a GPX track.")

    @Parameter(title: "Flush Interval (minutes)")
    var intervalMinutes: Int?

    @Parameter(title: "Session Name")
    var sessionName: String?

    @Parameter(title: "Record Interval (seconds)")
    var recordIntervalSeconds: Int?

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let requestedInterval = intervalMinutes ?? AppConfig.defaultFlushIntervalMinutes
        let sanitizedInterval = max(1, requestedInterval)
        let requestedRecord = recordIntervalSeconds ?? 5
        let sanitizedRecord = max(1, requestedRecord)
        let status = CLLocationManager.authorizationStatus()

        switch status {
        case .denied, .restricted:
            return .result(value: "ERROR: Location access is denied or restricted. Please enable in Settings.")
        case .notDetermined:
            return .result(value: "ERROR: Location permission not granted. Please open the app first to grant access.")
        case .authorizedWhenInUse:
            await GPSLogger.shared.startLogging(updateInterval: sanitizedInterval, suggestedName: sessionName, recordIntervalSeconds: sanitizedRecord)
            return .result(value: "OK")
        case .authorizedAlways:
            await GPSLogger.shared.startLogging(updateInterval: sanitizedInterval, suggestedName: sessionName, recordIntervalSeconds: sanitizedRecord)
            return .result(value: "OK")
        @unknown default:
            await GPSLogger.shared.startLogging(updateInterval: sanitizedInterval, suggestedName: sessionName, recordIntervalSeconds: sanitizedRecord)
            return .result(value: "OK")
        }
    }
}

struct StopLoggingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop GPS Logging"
    static var description = IntentDescription("Stop the current GPX recording.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await GPSLogger.shared.stopLogging()
        return .result(value: "OK")
    }
}

struct LoggingShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartLoggingIntent(), phrases: [
            "Start logging in \(.applicationName)"
        ], shortTitle: "Start Logging", systemImageName: "record.circle")
        AppShortcut(intent: StopLoggingIntent(), phrases: [
            "Stop logging in \(.applicationName)"
        ], shortTitle: "Stop Logging", systemImageName: "stop.circle")
    }
}
