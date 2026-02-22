import Foundation
import CoreLocation
import Combine

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

actor GPSLogger {
    static let shared = GPSLogger()

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
    private var recordIntervalSeconds: Int = 20
    private var lastSavedLocationTime: Date? = nil
    private var flushTask: Task<Void, Never>? = nil

    private var saveMode: SaveMode = .daily
    private var isIntermittentMode: Bool = false
    private var intermittentTimer: Task<Void, Never>? = nil
    /// When in intermittent mode, this flag indicates we are waiting for a single location fix.
    private var waitingForFix: Bool = false
    private var isActivelyLogging: Bool = false

    private var distanceFilterMeters: Double = 0  // 0 = no filter
    private var accuracyFilterMeters: Double = 0  // 0 = no filter

    private var lastLocation: CLLocation? = nil
    private var totalDistance: Double = 0

    private(set) var currentFileURL: URL? = nil

    // Shared UI state (published on main thread)
    nonisolated let trackState = TrackState()

    private init() {
        locationManager.delegate = delegate
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.startUpdatingHeading()

        delegate.onAuthorizationChange = { [weak self] status in
            Task { await self?.handleAuthChange(status: status) }
        }
        delegate.onLocations = { [weak self] locations in
            Task { await self?.handleLocations(locations) }
        }
        delegate.onHeading = { [weak self] heading in
            Task { await self?.handleHeading(heading) }
        }
        delegate.onError = { error in
            print("Location error: \(error)")
        }
    }

    func requestAuthorization() {
        if CLLocationManager.authorizationStatus() == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// Request a one-time location fix to seed the initial map position.
    func requestInitialLocation() {
        locationManager.requestLocation()
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

        // Read save mode from UserDefaults
        let modeRaw = UserDefaults.standard.string(forKey: "saveMode") ?? SaveMode.daily.rawValue
        saveMode = SaveMode(rawValue: modeRaw) ?? .session

        // Determine GPS power mode
        isIntermittentMode = self.recordIntervalSeconds >= AppConfig.intermittentGPSThreshold

        // Read filter settings
        let distRaw = UserDefaults.standard.integer(forKey: "distanceFilterMeters")
        distanceFilterMeters = distRaw > 0 ? Double(distRaw) : 0
        let accRaw = UserDefaults.standard.integer(forKey: "accuracyFilterMeters")
        accuracyFilterMeters = accRaw > 0 ? Double(accRaw) : 0

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
            let url = self.currentFileURL
            await MainActor.run {
                trackState.coordinates = []
                trackState.isLogging = true
                trackState.currentFileURL = url
            }
            isActivelyLogging = true
            lastLocation = nil
            totalDistance = 0

            // Set background location permission ONCE at start — only if the app actually
            // has UIBackgroundModes=location in Info.plist (prevents CoreLocation assertion crash)
            let status = CLLocationManager.authorizationStatus()
            if status == .authorizedAlways, Self.hasBackgroundLocationCapability {
                locationManager.allowsBackgroundLocationUpdates = true
            }

            startFlushTimer()

            if isIntermittentMode {
                startIntermittentTimer()
            } else {
                startLocationUpdates()
            }
        } catch {
            print("Failed to start logging: \(error)")
        }
    }

    func stopLogging() async {
        isActivelyLogging = false
        stopFlushTimer()
        stopIntermittentTimer()
        stopLocationUpdates()
        locationManager.allowsBackgroundLocationUpdates = false
        do { try gpx.close() } catch { print("Failed to close GPX: \(error)") }
        let url = self.currentFileURL
        await MainActor.run {
            trackState.isLogging = false
            trackState.currentFileURL = url
        }
    }

    // MARK: - Continuous GPS mode

    private func startLocationUpdates() {
        let status = CLLocationManager.authorizationStatus()
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
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
        // Fire once immediately, then repeat at interval
        requestSingleFix()
        intermittentTimer = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(await self.recordIntervalSeconds) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self.requestSingleFix()
            }
        }
    }

    private func stopIntermittentTimer() {
        intermittentTimer?.cancel()
        intermittentTimer = nil
        waitingForFix = false
    }

    private func requestSingleFix() {
        waitingForFix = true
        locationManager.startUpdatingLocation()
    }

    // MARK: - Flush timer

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

    // MARK: - Handlers

    private func handleAuthChange(status: CLAuthorizationStatus) {
        // Background updates are set once in startLogging/stopLogging.
        // No action needed here to avoid CoreLocation assertion crashes.
    }

    private func handleHeading(_ heading: CLHeading) {
        let h = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        lastTrueHeading = h
        Task { @MainActor in
            trackState.currentHeading = h
        }
    }

    private func handleLocations(_ locations: [CLLocation]) async {
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
                    do {
                        try gpx.close()
                        try gpx.startNewFileForDate(loc.timestamp)
                        currentFileURL = gpx.fileURL
                        let url = self.currentFileURL
                        await MainActor.run {
                            trackState.currentFileURL = url
                        }
                    } catch {
                        print("Date rotation error: \(error)")
                    }
                }
            }

            // Interval filtering (only for continuous mode; intermittent mode already spaces out)
            if !isIntermittentMode {
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

            do { try gpx.append(location: loc, heading: lastTrueHeading) } catch { print("Append error: \(error)") }

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

        // In intermittent mode, turn off GPS after getting a fix
        if isIntermittentMode && waitingForFix && !newCoords.isEmpty {
            waitingForFix = false
            locationManager.stopUpdatingLocation()
        }

        guard !newCoords.isEmpty else { return }

        let speed = lastAcceptedSpeed
        let alt = lastAcceptedAltitude
        let dist = self.totalDistance

        let lastCoord = newCoords.last
        await MainActor.run {
            trackState.coordinates.append(contentsOf: newCoords)
            trackState.currentSpeed = speed
            trackState.currentAltitude = alt
            trackState.totalDistance = dist
            if let coord = lastCoord {
                trackState.currentLocation = coord
            }
        }
    }

    private var lastAcceptedSpeed: Double = 0
    private var lastAcceptedAltitude: Double = 0
    private var lastTrueHeading: Double = -1
}
