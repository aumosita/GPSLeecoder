import SwiftUI
import MapKit
import CoreLocation
import Combine

struct TrackingMapView: View {
    @StateObject private var state = GPSLogger.shared.trackState
    @AppStorage("flushIntervalMinutes") private var flushIntervalMinutes: Int = AppConfig.defaultFlushIntervalMinutes
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var fileToShare: URL?

    @State private var cameraPosition: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var currentCameraDistance: Double = 500  // meters (≈100m scale)
    @State private var hasSetInitialZoom = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $cameraPosition) {
                UserAnnotation()
                // Heading wedge indicator
                if state.currentHeading >= 0, let loc = state.currentLocation {
                    Annotation("", coordinate: loc) {
                        HeadingWedge(heading: state.currentHeading)
                            .allowsHitTesting(false)
                    }
                }
                if state.coordinates.count > 1 {
                    MapPolyline(coordinates: state.coordinates)
                        .stroke(.blue, lineWidth: 3)
                }
            }
            .mapControls {
                MapScaleView()
                MapCompass()
            }
            .mapControlVisibility(.visible)
            .onMapCameraChange(frequency: .continuous) { context in
                currentCameraDistance = context.camera.distance
            }

            if state.isLogging {
                LiveStatsBar(speed: state.currentSpeed,
                             altitude: state.currentAltitude,
                             distance: state.totalDistance)
            }
        }
        .safeAreaInset(edge: .top) {
            if state.isLogging {
                RecordingIndicator()
                    .padding(.top, 4)
            }
        }
        .onAppear {
            Task { await GPSLogger.shared.requestAuthorization() }
            let status = CLLocationManager.authorizationStatus()
            if status == .notDetermined || status == .denied {
                showOnboarding = true
            }
            // Request a one-time location fix to seed initial map position
            Task { await GPSLogger.shared.requestInitialLocation() }
        }
        .onReceive(state.$currentLocation.compactMap { $0 }.prefix(1)) { loc in
            guard !hasSetInitialZoom else { return }
            hasSetInitialZoom = true
            cameraPosition = .camera(MapCamera(
                centerCoordinate: loc,
                distance: 500
            ))
        }
        .navigationTitle(state.isLogging ? String(localized: "nav_title_logging") : String(localized: "nav_title_idle"))
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    showHistory = true
                } label: {
                    Label(String(localized: "button_history"), systemImage: "clock.arrow.circlepath")
                }

                Button {
                    showSettings = true
                } label: {
                    Label(String(localized: "button_settings"), systemImage: "gear")
                }

                Button {
                    if let loc = state.currentLocation {
                        cameraPosition = .camera(MapCamera(
                            centerCoordinate: loc,
                            distance: currentCameraDistance
                        ))
                    } else {
                        cameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
                    }
                } label: {
                    Label(String(localized: "button_current_location"), systemImage: "location.circle")
                }

                if state.isLogging {
                    Button(role: .destructive) {
                        Task { await GPSLogger.shared.stopLogging() }
                    } label: {
                        Label(String(localized: "button_stop"), systemImage: "stop.circle.fill")
                    }
                } else {
                    Button {
                        Task {
                            let flush = min(max(flushIntervalMinutes, 1), 60)
                            let record = UserDefaults.standard.integer(forKey: "recordIntervalSeconds")
                            let recordClamped = max(1, record == 0 ? 20 : record)
                            await GPSLogger.shared.startLogging(updateInterval: flush, suggestedName: nil, recordIntervalSeconds: recordClamped)
                        }
                    } label: {
                        Label(String(localized: "button_start"), systemImage: "record.circle")
                    }
                }

                if !state.isLogging, let url = state.currentFileURL {
                    Spacer()
                    Button {
                        ExportedFilesTracker.markAsExported(url)
                        fileToShare = url
                    } label: {
                        Label(String(localized: "button_share_gpx"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack { SessionsListView() }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingPermissionView()
        }
        .sheet(isPresented: Binding(
            get: { fileToShare != nil },
            set: { if !$0 { fileToShare = nil } }
        )) {
            if let url = fileToShare {
                ShareSheetView(activityItems: [url])
            }
        }
    }
}

#Preview {
    NavigationStack { TrackingMapView() }
}

// MARK: - Pulsing recording indicator
private struct RecordingIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(isPulsing ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            Text("nav_title_logging")
                .font(.headline)
        }
        .onAppear { isPulsing = true }
    }
}

// MARK: - Live stats overlay
private struct LiveStatsBar: View {
    let speed: Double      // m/s
    let altitude: Double   // m
    let distance: Double   // m

    var body: some View {
        HStack(spacing: 0) {
            statItem(icon: "speedometer", value: speedText, label: "km/h")
            Divider().frame(height: 30)
            statItem(icon: "mountain.2", value: altitudeText, label: "m")
            Divider().frame(height: 30)
            statItem(icon: "point.topleft.down.to.point.bottomright.curvepath", value: distanceText, label: distanceUnit)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 8)
        .padding(.horizontal, 16)
    }

    private func statItem(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var speedText: String {
        let kmh = max(0, speed) * 3.6
        return String(format: "%.1f", kmh)
    }

    private var altitudeText: String {
        String(format: "%.0f", altitude)
    }

    private var distanceText: String {
        if distance >= 1000 {
            return String(format: "%.2f", distance / 1000)
        } else {
            return String(format: "%.0f", distance)
        }
    }

    private var distanceUnit: String {
        distance >= 1000 ? "km" : "m"
    }
}

// MARK: - Heading wedge indicator
private struct HeadingWedge: View {
    let heading: Double  // degrees from true north

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let spreadAngle: Double = 50  // total spread in degrees
            let startAngle = Angle(degrees: -90 + heading - spreadAngle / 2)
            let endAngle = Angle(degrees: -90 + heading + spreadAngle / 2)

            var path = Path()
            path.move(to: center)
            path.addArc(center: center, radius: radius,
                        startAngle: startAngle, endAngle: endAngle, clockwise: false)
            path.closeSubpath()

            context.fill(path, with: .color(.blue.opacity(0.25)))
        }
        .frame(width: 80, height: 80)
    }
}
