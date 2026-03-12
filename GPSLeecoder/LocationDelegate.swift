import Foundation
import CoreLocation

@MainActor
final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onLocations: (([CLLocation]) -> Void)?
    var onHeading: ((CLHeading) -> Void)?
    var onError: ((Error) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onLocations?(locations)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        onHeading?(newHeading)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onError?(error)
    }

    /// iOS가 위치 업데이트를 일시정지하면 즉시 재시작 — 백그라운드 기록 유지
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        DiagLog.log("PAUSED by iOS — auto-resuming")
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }
}
