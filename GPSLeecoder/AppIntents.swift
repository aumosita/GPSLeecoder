import AppIntents
import CoreLocation

struct StartLoggingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start GPS Logging"
    static var description = IntentDescription("Start recording a GPX track.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let status = CLLocationManager.authorizationStatus()

        switch status {
        case .denied, .restricted:
            return .result(value: String(localized: "shortcut_error_denied"))
        case .notDetermined:
            return .result(value: String(localized: "shortcut_error_not_determined"))
        default:
            let flush = UserDefaults.standard.integer(forKey: "flushIntervalMinutes")
            let record = UserDefaults.standard.integer(forKey: "recordIntervalSeconds")
            await GPSLogger.shared.startLogging(
                updateInterval: max(1, flush == 0 ? AppConfig.defaultFlushIntervalMinutes : flush),
                recordIntervalSeconds: max(1, record == 0 ? 5 : record)
            )
            return .result(value: String(localized: "shortcut_result_ok"))
        }
    }
}

struct StopLoggingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop GPS Logging"
    static var description = IntentDescription("Stop the current GPX recording.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
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
