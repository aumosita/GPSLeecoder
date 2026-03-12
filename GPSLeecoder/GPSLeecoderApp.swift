import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        DiagLog.initialize()
        DiagLog.log("App launched")

        // iCloud container를 백그라운드에서 초기화
        let isLocationRelaunch = launchOptions?[.location] != nil
        Task {
            _ = await GPXWriter.resolveICloudContainer()
            // iOS가 위치 이벤트로 앱을 재실행한 경우 → iCloud 초기화 후 로깅 재개
            if isLocationRelaunch {
                await MainActor.run {
                    GPSLogger.shared.resumeLoggingIfNeeded()
                }
            }
        }

        return true
    }
}

@main
struct GPSLeecoderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TrackingMapView()
            }
        }
    }
}
