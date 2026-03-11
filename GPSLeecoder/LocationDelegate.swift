import Foundation
import CoreLocation

@MainActor
final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onLocations: (([CLLocation]) -> Void)?
    var onHeading: ((CLHeading) -> Void)?
    var onError: ((Error) -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
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

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        onPause?()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        onResume?()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }
}
