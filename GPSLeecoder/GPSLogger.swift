import Foundation
import CoreLocation
import Combine
import UIKit

final class TrackState: ObservableObject {
    @Published var coordinates: [CLLocationCoordinate2D] = []
    @Published var isLogging: Bool = false
    @Published var currentFileURL: URL? = nil
    @Published var currentSpeed: Double = 0        // m/s, negative if invalid
    @Published var currentAltitude: Double = 0      // meters
    @Published var totalDistance: Double = 0         // meters
    @Published var currentHeading: Double = -1       // degrees, -1 = invalid
    @Published var currentLocation: CLLocationCoordinate2D? = nil
}

@MainActor
final class GPSLogger {
    static let shared = GPSLogger()

    private struct PendingStartRequest {
        let updateInterval: Int?
        let suggestedName: String?
        let recordIntervalSeconds: Int?
    }

    /// Runtime check: does the built Info.plist actually contain UIBackgroundModes = [location]?
    nonisolated static var hasBackgroundLocationCapability: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        return modes.contains("location")
    }

    private let locationManager = CLLocationManager()
    private let delegate = LocationDelegate()
    private let gpx = GPXWriter()

    private var flushIntervalMinutes: Int = AppConfig.defaultFlushIntervalMinutes
    private var recordIntervalSeconds: Int = 30
    private var lastSavedLocationTime: Date? = nil
    private var flushTask: Task<Void, Never>? = nil

    private var saveMode: SaveMode = .daily
    private var isIntermittentMode: Bool = false
    private var intermittentTimer: Task<Void, Never>? = nil
    /// When in intermittent mode, this flag indicates we are waiting for a single location fix.
    private var waitingForFix: Bool = false
    private var fixTimeoutTask: Task<Void, Never>? = nil
    private var isActivelyLogging: Bool = false
    private var isInBackground = false
    private var pendingStartRequest: PendingStartRequest? = nil
    private var isDeferringLocationUpdates = false

    // Error recovery
    private var errorRetryCount: Int = 0
    private static let maxErrorRetries = 10
    private var errorRetryTask: Task<Void, Never>? = nil

    private var distanceFilterMeters: Double = 10  // default 10m
    private var accuracyFilterMeters: Double = 100  // default 100m

    private var lastLocation: CLLocation? = nil
    private var totalDistance: Double = 0
    private var lastAcceptedSpeed: Double = 0
    private var lastAcceptedAltitude: Double = 0
    private var lastTrueHeading: Double = -1

    private var isLocationPaused: Bool = false

    private(set) var currentFileURL: URL? = nil

    // Shared UI state (published on main thread)
    let trackState = TrackState()

    private init() {
        locationManager.delegate = delegate
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .other
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.startUpdatingHeading()

        delegate.onLocations = { [weak self] locations in
            Task { @MainActor in self?.handleLocations(locations) }
        }
        delegate.onHeading = { [weak self] heading in
            Task { @MainActor in self?.handleHeading(heading) }
        }
        delegate.onError = { [weak self] error in
            print("Location error: \(error)")
            Task { @MainActor in self?.handleLocationError(error) }
        }
        delegate.onPause = { [weak self] in
            Task { @MainActor in self?.handleLocationPause() }
        }
        delegate.onResume = { [weak self] in
            Task { @MainActor in self?.handleLocationResume() }
        }
        delegate.onAuthorizationChange = { [weak self] status in
            Task { @MainActor in self?.handleAuthorizationChange(status) }
        }
        delegate.onDeferredUpdatesFinished = { [weak self] error in
            Task { @MainActor in self?.handleDeferredUpdatesFinished(error) }
        }

        // NotificationCenter 기반 생명주기 감지 — scenePhase보다 신뢰성 높음
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applicationDidEnterBackground() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applicationDidBecomeActive() }
        }
    }

    func requestAuthorization() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// Request a one-time location fix to seed the initial map position.
    func requestInitialLocation() {
        locationManager.requestLocation()
    }

    func requestAlwaysAuthorization() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
    }

    @discardableResult
    func startLogging(updateInterval: Int? = nil, suggestedName: String? = nil, recordIntervalSeconds: Int? = nil) -> Bool {
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways else {
            pendingStartRequest = PendingStartRequest(
                updateInterval: updateInterval,
                suggestedName: suggestedName,
                recordIntervalSeconds: recordIntervalSeconds
            )
            requestAlwaysAuthorization()
            return false
        }

        if let interval = updateInterval { flushIntervalMinutes = max(1, interval) }
        if let record = recordIntervalSeconds { self.recordIntervalSeconds = max(1, record) }

        // Read save mode from UserDefaults
        let modeRaw = UserDefaults.standard.string(forKey: "saveMode") ?? SaveMode.daily.rawValue
        saveMode = SaveMode(rawValue: modeRaw) ?? .session

        // Determine GPS power mode
        isIntermittentMode = self.recordIntervalSeconds >= AppConfig.intermittentGPSThreshold

        // Read filter settings (use defaults if not explicitly set)
        let distRaw = UserDefaults.standard.object(forKey: "distanceFilterMeters") as? Int ?? 10
        distanceFilterMeters = Double(distRaw)
        let accRaw = UserDefaults.standard.object(forKey: "accuracyFilterMeters") as? Int ?? 100
        accuracyFilterMeters = Double(accRaw)

        // Apply distance filter to CLLocationManager
        locationManager.distanceFilter = distanceFilterMeters > 0 ? distanceFilterMeters : kCLDistanceFilterNone

        do {
            if saveMode == .daily {
                try gpx.startNewFileForDate(Date())
            } else {
                try gpx.startNewFile(suggestedName: suggestedName)
            }
            currentFileURL = gpx.fileURL
            lastSavedLocationTime = nil
            trackState.coordinates = []
            trackState.isLogging = true
            trackState.currentFileURL = currentFileURL
            isActivelyLogging = true
            isInBackground = UIApplication.shared.applicationState != .active
            lastLocation = nil
            totalDistance = 0
            pendingStartRequest = nil

            configureBackgroundLocationSupport()
            updateDesiredAccuracy()

            startFlushTimer()
            restoreTrackingModeForCurrentScene()
            return true
        } catch {
            print("Failed to start logging: \(error)")
            return false
        }
    }

    func stopLogging() {
        isActivelyLogging = false
        isInBackground = false
        isLocationPaused = false
        errorRetryCount = 0
        errorRetryTask?.cancel()
        errorRetryTask = nil
        pendingStartRequest = nil
        stopFlushTimer()
        stopIntermittentTimer()
        stopLocationUpdates()
        endDeferredUpdatesIfNeeded()
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false
        do { try gpx.close() } catch { print("Failed to close GPX: \(error)") }
        trackState.isLogging = false
        trackState.currentFileURL = currentFileURL
    }

    func applicationDidEnterBackground() {
        guard isActivelyLogging else { return }
        isInBackground = true
        isLocationPaused = false
        locationManager.pausesLocationUpdatesAutomatically = false

        if isIntermittentMode {
            stopIntermittentTimer()
        }

        updateDesiredAccuracy()
        startLocationUpdates()
        beginDeferredUpdatesIfNeeded()
    }

    func applicationDidBecomeActive() {
        guard isActivelyLogging else { return }
        isInBackground = false
        isLocationPaused = false
        endDeferredUpdatesIfNeeded()
        updateDesiredAccuracy()
        restoreTrackingModeForCurrentScene()
    }

    // MARK: - Continuous GPS mode

    private func startLocationUpdates() {
        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedAlways:
            configureBackgroundLocationSupport()
            updateDesiredAccuracy()
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse, .notDetermined:
            requestAlwaysAuthorization()
        default:
            break
        }
    }

    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
    }

    // MARK: - Intermittent GPS mode

    private func startIntermittentTimer() {
        stopIntermittentTimer()
        locationManager.stopUpdatingLocation()

        // Fire once immediately, then repeat at interval while the app is active.
        requestSingleFix()
        intermittentTimer = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.recordIntervalSeconds) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                self.requestSingleFix()
            }
        }
    }

    private func stopIntermittentTimer() {
        intermittentTimer?.cancel()
        intermittentTimer = nil
        waitingForFix = false
        cancelFixTimeout()
    }

    private func requestSingleFix() {
        waitingForFix = true
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.startUpdatingLocation()
        startFixTimeout()
    }

    /// Timeout for intermittent fix: if no valid location within 30s, restart location manager.
    private func startFixTimeout() {
        cancelFixTimeout()
        fixTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.waitingForFix else { return }
            print("[GPS Recovery] Fix timeout — restarting location manager")
            self.locationManager.stopUpdatingLocation()
            try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.locationManager.startUpdatingLocation()
        }
    }

    private func cancelFixTimeout() {
        fixTimeoutTask?.cancel()
        fixTimeoutTask = nil
    }

    // MARK: - Flush timer

    private func startFlushTimer() {
        stopFlushTimer()
        flushTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.flushIntervalMinutes) * 60 * 1_000_000_000)
                do { try self.gpx.flush() } catch { print("Flush error: \(error)") }

                // Upload latest location + GPX file to Dropbox (fire-and-forget)
                if DropboxUploader.isConfigured,
                   let coord = self.trackState.currentLocation {
                    let alt = self.lastAcceptedAltitude
                    let gpxURL = self.currentFileURL
                    Task.detached {
                        await DropboxUploader.uploadLocation(
                            coordinate: coord,
                            altitude: alt,
                            timestamp: Date()
                        )
                        if let gpxURL {
                            await DropboxUploader.uploadFile(localURL: gpxURL)
                        }
                    }
                }
            }
        }
    }

    private func stopFlushTimer() {
        flushTask?.cancel()
        flushTask = nil
    }

    // MARK: - Handlers

    private func handleLocationPause() {
        guard isActivelyLogging else { return }
        isLocationPaused = true
        print("[GPS] Location updates paused by iOS")
        // iOS가 위치 업데이트를 일시 중지했으므로 즉시 재시작
        print("[GPS Recovery] Auto-resuming paused location updates")
        locationManager.startUpdatingLocation()
        isLocationPaused = false
    }

    private func handleLocationResume() {
        guard isActivelyLogging else { return }
        isLocationPaused = false
        print("[GPS] Location updates resumed")
    }

    private func handleHeading(_ heading: CLHeading) {
        let h = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        lastTrueHeading = h
        trackState.currentHeading = h
    }

    private func handleLocations(_ locations: [CLLocation]) {
        guard !locations.isEmpty else { return }

        var newCoords: [CLLocationCoordinate2D] = []
        let ordered = locations.sorted { $0.timestamp < $1.timestamp }

        for loc in ordered {
            // Daily mode: check for date change
            if saveMode == .daily {
                let cal = Calendar.current
                let locDay = cal.dateComponents([.year, .month, .day], from: loc.timestamp)
                if let currentDay = gpx.currentFileDate, currentDay != locDay {
                    // Date changed — rotate file
                    let previousURL = gpx.fileURL
                    do {
                        try gpx.close()
                        try gpx.startNewFileForDate(loc.timestamp)
                        currentFileURL = gpx.fileURL
                        trackState.currentFileURL = currentFileURL
                    } catch {
                        print("Date rotation error: \(error) — attempting fallback")
                        // Fallback: try to reopen the previous file
                        if let prev = previousURL {
                            do {
                                try gpx.startNewFileForDate(Date().addingTimeInterval(-86400))
                                currentFileURL = gpx.fileURL
                                trackState.currentFileURL = currentFileURL
                                print("[Fallback] Reopened previous daily file")
                            } catch {
                                print("[Fallback] Failed to reopen previous file: \(error)")
                            }
                        }
                    }
                }
            }

            // Preserve the requested save interval even when intermittent mode falls back
            // to continuous updates in the background.
            if !isIntermittentMode || isInBackground {
                if let last = lastSavedLocationTime {
                    if loc.timestamp.timeIntervalSince(last) < TimeInterval(recordIntervalSeconds) {
                        continue
                    }
                }
            }

            // Accuracy filter: drop locations with poor GPS accuracy
            if accuracyFilterMeters > 0 && loc.horizontalAccuracy > accuracyFilterMeters {
                continue
            }

            do {
                try gpx.append(location: loc, heading: lastTrueHeading)
            } catch {
                print("Append error: \(error) — attempting file handle recovery")
                // Attempt to recover the file handle
                if let url = gpx.fileURL {
                    do {
                        try gpx.recoverFileHandle(at: url)
                        try gpx.append(location: loc, heading: lastTrueHeading)
                        print("[Recovery] File handle recovered successfully")
                    } catch {
                        print("[Recovery] Failed: \(error)")
                    }
                }
            }

            // Compute distance
            if let prev = lastLocation {
                totalDistance += loc.distance(from: prev)
            }
            lastLocation = loc
            lastAcceptedSpeed = loc.speed
            lastAcceptedAltitude = loc.altitude

            lastSavedLocationTime = loc.timestamp
            newCoords.append(loc.coordinate)
        }

        // In intermittent mode, lower GPS accuracy after getting a fix
        // (keep GPS alive at low power to prevent iOS from suspending the app)
        if isIntermittentMode && !isInBackground && waitingForFix && !newCoords.isEmpty {
            waitingForFix = false
            cancelFixTimeout()
            locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        }

        guard !newCoords.isEmpty else {
            beginDeferredUpdatesIfNeeded()
            return
        }

        errorRetryCount = 0

        let lastCoord = newCoords.last
        trackState.coordinates.append(contentsOf: newCoords)
        trackState.currentSpeed = lastAcceptedSpeed
        trackState.currentAltitude = lastAcceptedAltitude
        trackState.totalDistance = self.totalDistance
        if let coord = lastCoord {
            trackState.currentLocation = coord
        }

        beginDeferredUpdatesIfNeeded()
    }

    // MARK: - Location error recovery

    private func handleLocationError(_ error: Error) {
        guard isActivelyLogging else { return }

        let clError = error as? CLError
        let code = clError?.code ?? .locationUnknown

        switch code {
        case .denied:
            // User revoked permission — stop logging gracefully
            print("[GPS Recovery] Location permission denied — stopping logging")
            stopLogging()
            return

        case .locationUnknown, .network:
            // Transient errors — retry with backoff
            errorRetryCount += 1
            if errorRetryCount > Self.maxErrorRetries {
                print("[GPS Recovery] Max retries (\(Self.maxErrorRetries)) reached — resetting counter and restarting")
                errorRetryCount = 0
            }

            // Exponential backoff: 2, 4, 8 … capped at 30 seconds
            let delay = min(30.0, pow(2.0, Double(errorRetryCount)))
            print("[GPS Recovery] Retry #\(errorRetryCount) in \(delay)s (code: \(code.rawValue))")

            errorRetryTask?.cancel()
            errorRetryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.isActivelyLogging else { return }

                // Restart location updates
                self.locationManager.stopUpdatingLocation()
                self.locationManager.startUpdatingLocation()
                print("[GPS Recovery] Location manager restarted")
            }

        default:
            // Other errors — log and do a simple retry
            print("[GPS Recovery] Unhandled error code \(code.rawValue) — attempting restart")
            locationManager.stopUpdatingLocation()
            locationManager.startUpdatingLocation()
        }
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            if isActivelyLogging {
                configureBackgroundLocationSupport()
                updateDesiredAccuracy()
                restoreTrackingModeForCurrentScene()
            } else if let pending = pendingStartRequest {
                pendingStartRequest = nil
                _ = startLogging(
                    updateInterval: pending.updateInterval,
                    suggestedName: pending.suggestedName,
                    recordIntervalSeconds: pending.recordIntervalSeconds
                )
            }
        case .authorizedWhenInUse:
            if pendingStartRequest != nil {
                locationManager.requestAlwaysAuthorization()
            }
        case .denied, .restricted:
            pendingStartRequest = nil
            if isActivelyLogging {
                stopLogging()
            }
        default:
            break
        }
    }

    private func handleDeferredUpdatesFinished(_ error: Error?) {
        isDeferringLocationUpdates = false

        if let error {
            print("[GPS] Deferred updates ended with error: \(error)")
        }

        beginDeferredUpdatesIfNeeded()
    }

    private func configureBackgroundLocationSupport() {
        let supportsBackgroundUpdates = Self.hasBackgroundLocationCapability
        locationManager.allowsBackgroundLocationUpdates = supportsBackgroundUpdates
        locationManager.showsBackgroundLocationIndicator = supportsBackgroundUpdates
    }

    private func updateDesiredAccuracy() {
        if isInBackground && isIntermittentMode {
            let backgroundAccuracy = max(
                accuracyFilterMeters > 0 ? accuracyFilterMeters : kCLLocationAccuracyNearestTenMeters,
                kCLLocationAccuracyNearestTenMeters
            )
            locationManager.desiredAccuracy = backgroundAccuracy
            return
        }

        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    private func beginDeferredUpdatesIfNeeded() {
        guard isActivelyLogging, isInBackground else { return }
        guard locationManager.authorizationStatus == .authorizedAlways else { return }
        guard !isDeferringLocationUpdates else { return }
        guard CLLocationManager.deferredLocationUpdatesAvailable() else { return }

        isDeferringLocationUpdates = true
        locationManager.allowDeferredLocationUpdates(
            untilTraveled: CLLocationDistanceMax,
            timeout: TimeInterval(recordIntervalSeconds)
        )
    }

    private func endDeferredUpdatesIfNeeded() {
        guard isDeferringLocationUpdates else { return }
        isDeferringLocationUpdates = false
        locationManager.disallowDeferredLocationUpdates()
    }

    private func restoreTrackingModeForCurrentScene() {
        if isInBackground || !isIntermittentMode {
            startLocationUpdates()
            return
        }

        startIntermittentTimer()
    }
}
