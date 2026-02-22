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
        let requestedInterval = intervalMinutes ?? UserDefaults.standard.integer(forKey: "flushIntervalMinutes")
        let sanitizedInterval = max(1, requestedInterval == 0 ? AppConfig.defaultFlushIntervalMinutes : requestedInterval)
        let requestedRecord = recordIntervalSeconds ?? UserDefaults.standard.integer(forKey: "recordIntervalSeconds")
        let sanitizedRecord = max(1, requestedRecord == 0 ? 5 : requestedRecord)

        let status = CLLocationManager.authorizationStatus()

        switch status {
        case .denied, .restricted:
            return .result(value: String(localized: "shortcut_error_denied"))
        case .notDetermined:
            return .result(value: String(localized: "shortcut_error_not_determined"))
        default:
            await GPSLogger.shared.startLogging(
                updateInterval: sanitizedInterval,
                suggestedName: sessionName,
                recordIntervalSeconds: sanitizedRecord
            )
            return .result(value: String(localized: "shortcut_result_ok"))
        }
    }
}

struct StopLoggingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop GPS Logging"
    static var description = IntentDescription("Stop the current GPX recording.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await GPSLogger.shared.stopLogging()
        return .result(value: String(localized: "shortcut_result_ok"))
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
