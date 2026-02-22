import Foundation
import CoreLocation
import Combine

final class TrackState: ObservableObject {
    @Published var coordinates: [CLLocationCoordinate2D] = []
    @Published var isLogging: Bool = false
    @Published var currentFileURL: URL? = nil
}

actor GPSLogger {
    static let shared = GPSLogger()

    private let locationManager = CLLocationManager()
    private let delegate = LocationDelegate()
    private let gpx = GPXWriter()

    private var flushIntervalMinutes: Int = AppConfig.defaultFlushIntervalMinutes
    private var recordIntervalSeconds: Int = 5
    private var lastSavedLocationTime: Date? = nil
    private var flushTask: Task<Void, Never>? = nil

    private(set) var currentFileURL: URL? = nil

    // Shared UI state (published on main thread)
    nonisolated let trackState = TrackState()

    private init() {
        locationManager.delegate = delegate
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone

        delegate.onAuthorizationChange = { [weak self] status in
            Task { await self?.handleAuthChange(status: status) }
        }
        delegate.onLocations = { [weak self] locations in
            Task { await self?.handleLocations(locations) }
        }
        delegate.onError = { error in
            // You may want to log or surface the error
            print("Location error: \(error)")
        }
    }

    func requestAuthorization() {
        if CLLocationManager.authorizationStatus() == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func requestAlwaysAuthorization() {
        let status = CLLocationManager.authorizationStatus()
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
    }

    func startLogging(updateInterval: Int? = nil, suggestedName: String? = nil, recordIntervalSeconds: Int? = nil) async {
        if let interval = updateInterval { flushIntervalMinutes = max(1, interval) }
        if let record = recordIntervalSeconds { self.recordIntervalSeconds = max(1, record) }
        do {
            try gpx.startNewFile(suggestedName: suggestedName)
            currentFileURL = gpx.fileURL
            lastSavedLocationTime = nil
            let url = self.currentFileURL
            await MainActor.run {
                trackState.coordinates = []
                trackState.isLogging = true
                trackState.currentFileURL = url
            }
            startLocationUpdates()
            startFlushTimer()
        } catch {
            print("Failed to start logging: \(error)")
        }
    }

    func stopLogging() async {
        stopFlushTimer()
        stopLocationUpdates()
        do { try gpx.close() } catch { print("Failed to close GPX: \(error)") }
        let url = self.currentFileURL
        await MainActor.run {
            trackState.isLogging = false
            trackState.currentFileURL = url
        }
    }

    private func startLocationUpdates() {
        let status = CLLocationManager.authorizationStatus()

        // Only allow background updates if we truly have Always authorization.
        locationManager.allowsBackgroundLocationUpdates = (status == .authorizedAlways)

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            // For long background logging, Always is preferred; still start for foreground
            locationManager.startUpdatingLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            // Do not start updates when denied or restricted
            break
        }
    }

    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
    }

    private func startFlushTimer() {
        stopFlushTimer()
        flushTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.flushIntervalMinutes) * 60 * 1_000_000_000)
                do { try self.gpx.flush() } catch { print("Flush error: \(error)") }
            }
        }
    }

    private func stopFlushTimer() {
        flushTask?.cancel()
        flushTask = nil
    }

    private func handleAuthChange(status: CLAuthorizationStatus) {
        // Keep background updates flag in sync with authorization changes.
        locationManager.allowsBackgroundLocationUpdates = (status == .authorizedAlways)
    }

    private func handleLocations(_ locations: [CLLocation]) async {
        guard !locations.isEmpty else { return }

        var newCoords: [CLLocationCoordinate2D] = []
        // Ensure chronological order to apply interval filtering correctly
        let ordered = locations.sorted { $0.timestamp < $1.timestamp }

        for loc in ordered {
            if let last = lastSavedLocationTime {
                if loc.timestamp.timeIntervalSince(last) < TimeInterval(recordIntervalSeconds) {
                    continue
                }
            }
            do { try gpx.append(location: loc) } catch { print("Append error: \(error)") }
            lastSavedLocationTime = loc.timestamp
            newCoords.append(loc.coordinate)
        }

        guard !newCoords.isEmpty else { return }

        await MainActor.run {
            trackState.coordinates.append(contentsOf: newCoords)
        }
    }
}

