import Foundation
import CoreLocation
import Combine
import UIKit

final class TrackState: ObservableObject {
    var coordinates: [CLLocationCoordinate2D] = []   // Not @Published — avoids costly SwiftUI diff on every append
    @Published var pointCount: Int = 0               // True recorded count (never decreases)
    @Published var isLogging: Bool = false
    @Published var currentFileURL: URL? = nil
    @Published var currentSpeed: Double = 0          // m/s, negative if invalid
    @Published var currentAltitude: Double = 0       // meters
    @Published var totalDistance: Double = 0          // meters
    @Published var currentAccuracy: Double = -1        // horizontal accuracy in meters, -1 = invalid
    @Published var currentHeading: Double = -1        // degrees, -1 = invalid
    @Published var currentLocation: CLLocationCoordinate2D? = nil
}

@MainActor
final class GPSLogger {
    static let shared = GPSLogger()

    private let locationManager = CLLocationManager()
    private let delegate = LocationDelegate()
    private let gpx = GPXWriter()

    // MARK: - State

    private var isRecording = false
    private var lastAcceptedTime: Date?
    private var lastFlushTime: Date?
    private var lastLocation: CLLocation?
    private var totalDistance: Double = 0
    private var lastTrueHeading: Double = -1
    private var lastHeadingTime: Date?

    private var saveMode: SaveMode = .daily
    private var flushIntervalSeconds: TimeInterval = TimeInterval(AppConfig.defaultFlushIntervalMinutes * 60)
    private var recordIntervalSeconds: Int = AppConfig.defaultRecordIntervalSeconds
    private var distanceFilterMeters: Double = Double(AppConfig.defaultDistanceFilterMeters)
    private var accuracyFilterMeters: Double = Double(AppConfig.defaultAccuracyFilterMeters)

    private var skipLogCounter: Int = 0

    // Power saving options
    private var hwDistanceFilter: Bool = AppConfig.defaultHwDistanceFilter
    private var activityTypeFitness: Bool = AppConfig.defaultActivityTypeFitness
    private var dutyCycling: Bool = AppConfig.defaultDutyCycling
    private var stationaryPowerSave: Bool = AppConfig.defaultStationaryPowerSave
    private var maxPerformance: Bool = AppConfig.defaultMaxPerformance
    private var dutyCycleTimer: Timer?
    private var isStationaryLowPower: Bool = false

    // Persistence keys for relaunch recovery
    private static let kWasLogging = "GPSLogger.wasLogging"
    private static let kSavedFlushInterval = "GPSLogger.flushInterval"
    private static let kSavedRecordInterval = "GPSLogger.recordInterval"

    private(set) var currentFileURL: URL? = nil

    // Shared UI state
    let trackState = TrackState()

    // MARK: - Init

    private init() {
        locationManager.delegate = delegate
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.headingFilter = kCLHeadingFilterNone
        locationManager.activityType = .other

        delegate.onLocations = { [weak self] locations in
            MainActor.assumeIsolated { self?.handleLocations(locations) }
        }
        delegate.onHeading = { [weak self] heading in
            MainActor.assumeIsolated { self?.handleHeading(heading) }
        }
        delegate.onError = { [weak self] error in
            MainActor.assumeIsolated { self?.handleLocationError(error) }
        }
        delegate.onAuthorizationChange = { [weak self] status in
            MainActor.assumeIsolated { self?.handleAuthorizationChange(status) }
        }

        // 백그라운드 진입 시 heading 중지 + flush
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.locationManager.stopUpdatingHeading()
                guard self.isRecording else { return }
                DiagLog.log("BACKGROUND — points=\(self.trackState.pointCount)")
                do { try self.gpx.flush() } catch {
                    DiagLog.log("Background flush error: \(error)")
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.locationManager.startUpdatingHeading()
                self.lastHeadingTime = nil
                guard self.isRecording else { return }
                DiagLog.log("FOREGROUND — points=\(self.trackState.pointCount)")
            }
        }
    }

    // MARK: - Public API

    func requestAuthorization() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func requestAlwaysAuthorization() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
    }

    func requestInitialLocation() {
        locationManager.requestLocation()
    }

    func startHeadingUpdates() {
        locationManager.startUpdatingHeading()
        lastHeadingTime = nil
    }

    func stopHeadingUpdates() {
        locationManager.stopUpdatingHeading()
        lastHeadingTime = nil
    }

    @discardableResult
    func startLogging(flushInterval: Int? = nil, recordInterval: Int? = nil) -> Bool {
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways else {
            requestAlwaysAuthorization()
            return false
        }

        // Apply settings
        if let f = flushInterval { flushIntervalSeconds = TimeInterval(max(0, f)) * 60 }
        if let r = recordInterval { recordIntervalSeconds = max(1, r) }

        let modeRaw = UserDefaults.standard.string(forKey: "saveMode") ?? SaveMode.daily.rawValue
        saveMode = SaveMode(rawValue: modeRaw) ?? .daily

        let distRaw = UserDefaults.standard.object(forKey: "distanceFilterMeters") as? Int
                      ?? AppConfig.defaultDistanceFilterMeters
        distanceFilterMeters = Double(distRaw)

        let accRaw = UserDefaults.standard.object(forKey: "accuracyFilterMeters") as? Int
                     ?? AppConfig.defaultAccuracyFilterMeters
        accuracyFilterMeters = Double(accRaw)

        // Power saving options
        let ud = UserDefaults.standard
        hwDistanceFilter = ud.object(forKey: "hwDistanceFilter") as? Bool ?? AppConfig.defaultHwDistanceFilter
        activityTypeFitness = ud.object(forKey: "activityTypeFitness") as? Bool ?? AppConfig.defaultActivityTypeFitness
        dutyCycling = ud.object(forKey: "dutyCycling") as? Bool ?? AppConfig.defaultDutyCycling
        stationaryPowerSave = ud.object(forKey: "stationaryPowerSave") as? Bool ?? AppConfig.defaultStationaryPowerSave
        maxPerformance = ud.object(forKey: "maxPerformance") as? Bool ?? AppConfig.defaultMaxPerformance

        // Max performance overrides all power saving
        if maxPerformance {
            hwDistanceFilter = false
            activityTypeFitness = false
            dutyCycling = false
            stationaryPowerSave = false
        }

        do {
            if saveMode == .daily {
                try gpx.startNewFileForDate(Date())
            } else {
                try gpx.startNewFile()
            }
            currentFileURL = gpx.fileURL

            // Load existing stats if resuming a daily file
            var existingPoints = 0
            var existingDistance: Double = 0
            var existingCoords: [CLLocationCoordinate2D] = []
            if saveMode == .daily, let url = gpx.fileURL {
                let stats = GPXWriter.statsFromFile(at: url)
                existingPoints = stats.points
                existingDistance = stats.distance
                existingCoords = stats.coordinates
                if let coord = stats.lastCoord {
                    lastLocation = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                }
                if existingPoints > 0 {
                    DiagLog.log("RESUME daily — existing \(existingPoints) pts, \(String(format: "%.0f", existingDistance))m")
                }
            }

            // Reset state
            lastAcceptedTime = nil
            lastFlushTime = Date()
            if existingPoints == 0 { lastLocation = nil }
            totalDistance = existingDistance
            skipLogCounter = 0
            isRecording = true

            trackState.coordinates = existingCoords
            trackState.pointCount = existingPoints
            trackState.totalDistance = existingDistance
            trackState.isLogging = true
            trackState.currentFileURL = currentFileURL

            // Apply power settings to CLLocationManager
            locationManager.activityType = activityTypeFitness ? .fitness : .other
            locationManager.distanceFilter = hwDistanceFilter ? distanceFilterMeters : kCLDistanceFilterNone
            locationManager.desiredAccuracy = maxPerformance ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
            isStationaryLowPower = false

            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true

            if dutyCycling && recordIntervalSeconds >= 5 {
                // Duty cycling: periodic requestLocation() instead of continuous
                locationManager.startMonitoringSignificantLocationChanges()
                scheduleDutyCycleTimer()
            } else {
                locationManager.startUpdatingLocation()
                locationManager.startMonitoringSignificantLocationChanges()
            }

            persistLoggingState()

            var powerFlags: [String] = []
            if maxPerformance { powerFlags.append("MAX") }
            if hwDistanceFilter { powerFlags.append("hwDist") }
            if activityTypeFitness { powerFlags.append("fitness") }
            if dutyCycling { powerFlags.append("duty") }
            if stationaryPowerSave { powerFlags.append("statSave") }
            DiagLog.log("START — mode=\(saveMode) record=\(recordIntervalSeconds)s flush=\(Int(flushIntervalSeconds/60))m dist=\(distanceFilterMeters)m acc=\(accuracyFilterMeters)m power=[\(powerFlags.joined(separator: ","))] file=\(gpx.fileURL?.lastPathComponent ?? "nil")")
            return true
        } catch {
            DiagLog.log("Failed to start logging: \(error)")
            return false
        }
    }

    func stopLogging() {
        guard isRecording else { return }
        DiagLog.log("STOP — points=\(trackState.pointCount) dist=\(String(format: "%.0f", totalDistance))m")

        isRecording = false
        dutyCycleTimer?.invalidate()
        dutyCycleTimer = nil
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        // Restore defaults
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .other
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        clearLoggingState()

        do { try gpx.close() } catch {
            DiagLog.log("Failed to close GPX: \(error)")
        }

        trackState.isLogging = false
        trackState.currentFileURL = currentFileURL
    }

    /// iOS가 위치 이벤트로 앱을 재실행했을 때 호출
    func resumeLoggingIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.kWasLogging) else { return }

        let flush = defaults.object(forKey: Self.kSavedFlushInterval) as? Int
        let record = defaults.object(forKey: Self.kSavedRecordInterval) as? Int

        DiagLog.log("App relaunched by iOS — resuming logging")
        startLogging(flushInterval: flush, recordInterval: record)
    }

    // MARK: - Handlers

    private func handleHeading(_ heading: CLHeading) {
        let h = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        lastTrueHeading = h

        // Throttle UI updates to ~10 Hz
        let now = Date()
        if let last = lastHeadingTime, now.timeIntervalSince(last) < 0.1 { return }
        lastHeadingTime = now
        trackState.currentHeading = h
    }

    private func handleLocations(_ locations: [CLLocation]) {
        guard isRecording, !locations.isEmpty else {
            // 기록 중이 아니어도 현재 위치는 업데이트 (초기 위치 표시용)
            if !isRecording, let loc = locations.last {
                trackState.currentLocation = loc.coordinate
                trackState.currentAccuracy = loc.horizontalAccuracy
            }
            return
        }

        var newCoords: [CLLocationCoordinate2D] = []
        let ordered = locations.sorted { $0.timestamp < $1.timestamp }

        for loc in ordered {
            // Daily mode: check for date change
            if saveMode == .daily {
                let cal = Calendar.current
                let locDay = cal.dateComponents([.year, .month, .day], from: loc.timestamp)
                if let currentDay = gpx.currentFileDate, currentDay != locDay {
                    do {
                        try gpx.close()
                        try gpx.startNewFileForDate(loc.timestamp)
                        currentFileURL = gpx.fileURL
                        trackState.currentFileURL = currentFileURL
                        DiagLog.log("Daily file rotated → \(gpx.fileURL?.lastPathComponent ?? "nil")")
                    } catch {
                        DiagLog.log("Date rotation error: \(error)")
                    }
                }
            }

            // Time filter
            if let last = lastAcceptedTime {
                let elapsed = loc.timestamp.timeIntervalSince(last)
                if elapsed < TimeInterval(recordIntervalSeconds) {
                    skipLogCounter += 1
                    if skipLogCounter % 30 == 1 {
                        DiagLog.log("SKIP interval: \(String(format: "%.1f", elapsed))s<\(recordIntervalSeconds)s ha=\(String(format: "%.0f", loc.horizontalAccuracy))m x\(skipLogCounter)")
                    }
                    continue
                }
            }

            // Accuracy filter
            if accuracyFilterMeters > 0 && loc.horizontalAccuracy > accuracyFilterMeters {
                skipLogCounter += 1
                if skipLogCounter % 30 == 1 {
                    DiagLog.log("SKIP accuracy: \(String(format: "%.0f", loc.horizontalAccuracy))m>\(String(format: "%.0f", accuracyFilterMeters))m x\(skipLogCounter)")
                }
                continue
            }

            // Distance filter
            if distanceFilterMeters > 0, let prev = lastLocation {
                let dist = loc.distance(from: prev)
                if dist < distanceFilterMeters {
                    skipLogCounter += 1
                    if skipLogCounter % 30 == 1 {
                        DiagLog.log("SKIP distance: \(String(format: "%.1f", dist))m<\(String(format: "%.0f", distanceFilterMeters))m x\(skipLogCounter)")
                    }
                    continue
                }
            }

            // Write point
            do {
                try gpx.append(location: loc, heading: lastTrueHeading)
            } catch {
                DiagLog.log("Append error: \(error)")
                continue
            }

            // Flush check (skip if interval is 0 = disabled)
            if flushIntervalSeconds > 0,
               let flushTime = lastFlushTime,
               Date().timeIntervalSince(flushTime) >= flushIntervalSeconds {
                do {
                    try gpx.flush()
                    lastFlushTime = Date()
                    DiagLog.log("FLUSH — points=\(trackState.pointCount + newCoords.count)")
                } catch {
                    DiagLog.log("Flush error: \(error)")
                }
            }

            // Update tracking state
            if let prev = lastLocation {
                totalDistance += loc.distance(from: prev)
            }
            lastLocation = loc
            lastAcceptedTime = loc.timestamp
            skipLogCounter = 0
            newCoords.append(loc.coordinate)
        }

        guard !newCoords.isEmpty else { return }

        trackState.coordinates.append(contentsOf: newCoords)
        trackState.pointCount += newCoords.count

        // Log every 10th point
        if trackState.pointCount % 10 < newCoords.count || trackState.pointCount == newCoords.count {
            DiagLog.log("POINT +\(newCoords.count) total=\(trackState.pointCount)")
        }

        // Memory protection: thin coordinates for map display
        let maxCoordinates = 5000
        if trackState.coordinates.count > maxCoordinates {
            let thinned = stride(from: 0, to: trackState.coordinates.count, by: 2)
                .map { trackState.coordinates[$0] }
            trackState.coordinates = thinned
        }

        let lastCoord = newCoords.last

        if let loc = ordered.last {
            trackState.currentSpeed = loc.speed
            trackState.currentAltitude = loc.altitude
            trackState.currentAccuracy = loc.horizontalAccuracy

            // Stationary power save: lower accuracy when speed ≈ 0
            if stationaryPowerSave && !dutyCycling {
                let isStationary = loc.speed < 0.3
                if isStationary && !isStationaryLowPower {
                    locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                    isStationaryLowPower = true
                    DiagLog.log("POWER — stationary → nearestTenMeters")
                } else if !isStationary && isStationaryLowPower {
                    locationManager.desiredAccuracy = kCLLocationAccuracyBest
                    isStationaryLowPower = false
                    DiagLog.log("POWER — moving → best accuracy")
                }
            }
        }
        trackState.totalDistance = totalDistance
        if let coord = lastCoord {
            trackState.currentLocation = coord
        }
    }

    // MARK: - Duty cycling

    private func scheduleDutyCycleTimer() {
        dutyCycleTimer?.invalidate()
        let interval = TimeInterval(max(5, recordIntervalSeconds))
        dutyCycleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.locationManager.requestLocation()
            }
        }
        // Fire immediately for first fix
        locationManager.requestLocation()
    }

    // MARK: - Error handling

    private func handleLocationError(_ error: Error) {
        guard isRecording else { return }

        let clError = error as? CLError
        let code = clError?.code ?? .locationUnknown

        if code == .denied {
            let actual = locationManager.authorizationStatus
            guard actual == .denied || actual == .restricted else {
                DiagLog.log("Transient denied error — actual status: \(actual.rawValue), ignoring")
                return
            }
            DiagLog.log("Location permission denied — stopping")
            stopLogging()
            return
        }

        // All other errors: just log. CLLocationManager retries automatically.
        DiagLog.log("ERROR code=\(code.rawValue) \(error.localizedDescription)")
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            // Nothing to do — location updates continue automatically
            break
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            if isRecording { stopLogging() }
        default:
            break
        }
    }

    // MARK: - Persistence

    private func persistLoggingState() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.kWasLogging)
        defaults.set(Int(flushIntervalSeconds / 60), forKey: Self.kSavedFlushInterval)
        defaults.set(recordIntervalSeconds, forKey: Self.kSavedRecordInterval)
    }

    private func clearLoggingState() {
        UserDefaults.standard.removeObject(forKey: Self.kWasLogging)
        UserDefaults.standard.removeObject(forKey: Self.kSavedFlushInterval)
        UserDefaults.standard.removeObject(forKey: Self.kSavedRecordInterval)
    }
}
