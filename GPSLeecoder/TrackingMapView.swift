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
    @State private var isFollowing = true
    /// Guards against programmatic camera moves being treated as user drags.
    @State private var isProgrammaticMove = false

    var body: some View {
        MapReader { proxy in
        ZStack(alignment: .bottom) {
            Map(position: $cameraPosition) {
                // Unified location + heading indicator
                // UserAnnotation always stays visible regardless of camera position
                UserAnnotation {
                    DirectionArrow(heading: state.currentHeading)
                        .allowsHitTesting(false)
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
            .onMapCameraChange(frequency: .onEnd) { _ in
                if isProgrammaticMove {
                    isProgrammaticMove = false
                } else {
                    // User dragged the map manually → stop following
                    isFollowing = false
                }
            }

            if state.isLogging {
                LiveStatsBar(speed: state.currentSpeed,
                             altitude: state.currentAltitude,
                             distance: state.totalDistance,
                             pointCount: state.coordinates.count)
            }
        }
        .safeAreaInset(edge: .top) {
            if state.isLogging {
                RecordingIndicator()
                    .padding(.top, 4)
            }
        }
        .onAppear {
            GPSLogger.shared.requestAuthorization()
            let status = CLLocationManager().authorizationStatus
            if status != .authorizedAlways {
                showOnboarding = true
            }
            // Request a one-time location fix to seed initial map position
            GPSLogger.shared.requestInitialLocation()
        }

        .onReceive(state.$currentLocation.compactMap { $0 }.prefix(1)) { loc in
            guard !hasSetInitialZoom else { return }
            hasSetInitialZoom = true
            isProgrammaticMove = true
            cameraPosition = .camera(MapCamera(
                centerCoordinate: loc,
                distance: 500
            ))
        }
        .onChange(of: state.currentLocation) { _, newLoc in
            guard isFollowing, let loc = newLoc else { return }
            isProgrammaticMove = true
            let camera = MapCamera(
                centerCoordinate: loc,
                distance: currentCameraDistance
            )
            withMapCameraAnimation(.easeInOut(duration: 0.35), proxy) {
                cameraPosition = .camera(camera)
            }
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
                    isFollowing = true
                    isProgrammaticMove = true
                    if let loc = state.currentLocation {
                        let camera = MapCamera(
                            centerCoordinate: loc,
                            distance: currentCameraDistance
                        )
                        withMapCameraAnimation(.easeInOut(duration: 0.5), proxy) {
                            cameraPosition = .camera(camera)
                        }
                    } else {
                        cameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
                    }
                } label: {
                    Label(String(localized: "button_current_location"),
                          systemImage: isFollowing ? "location.circle.fill" : "location.circle")
                }

                if state.isLogging {
                    Button(role: .destructive) {
                        GPSLogger.shared.stopLogging()
                    } label: {
                        Label(String(localized: "button_stop"), systemImage: "stop.circle.fill")
                    }
                } else {
                    Button {
                        isFollowing = true
                        let flush = min(max(flushIntervalMinutes, 1), 60)
                        let record = UserDefaults.standard.integer(forKey: "recordIntervalSeconds")
                        let recordClamped = max(1, record == 0 ? 30 : record)
                        let started = GPSLogger.shared.startLogging(
                            updateInterval: flush,
                            suggestedName: nil,
                            recordIntervalSeconds: recordClamped
                        )
                        if !started {
                            showOnboarding = true
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
        } // MapReader
    }

    /// Animate map camera changes smoothly.
    private func withMapCameraAnimation(
        _ animation: Animation,
        _ proxy: MapProxy,
        body: @escaping () -> Void
    ) {
        withAnimation(animation) {
            body()
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
    let pointCount: Int

    var body: some View {
        HStack(spacing: 0) {
            statItem(icon: "speedometer", value: speedText, label: "km/h")
            Divider().frame(height: 30)
            statItem(icon: "mountain.2", value: altitudeText, label: "m")
            Divider().frame(height: 30)
            statItem(icon: "point.topleft.down.to.point.bottomright.curvepath", value: distanceText, label: distanceUnit)
            Divider().frame(height: 30)
            statItem(icon: "mappin.and.ellipse", value: "\(pointCount)", label: "pts")
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

// MARK: - Unified direction arrow (position + heading)
private struct DirectionArrow: View {
    let heading: Double  // degrees from true north, -1 = unknown
    @State private var isPulsing = false

    var body: some View {
        if heading >= 0 {
            // 3D navigation arrow
            Canvas { context, size in
                let cx = size.width / 2
                let cy = size.height / 2
                let h = size.height * 0.45  // arrow height from center
                let w = size.width * 0.28   // half-width at base
                let notch: CGFloat = h * 0.3 // depth of rear notch

                // Arrow pointing up (north), rotation handled by .rotationEffect
                var arrow = Path()
                arrow.move(to: CGPoint(x: cx, y: cy - h))         // tip
                arrow.addLine(to: CGPoint(x: cx + w, y: cy + h))  // right base
                arrow.addLine(to: CGPoint(x: cx, y: cy + h - notch)) // center notch
                arrow.addLine(to: CGPoint(x: cx - w, y: cy + h))  // left base
                arrow.closeSubpath()

                // Shadow for 3D effect
                var shadow = arrow
                shadow = shadow.offsetBy(dx: 1, dy: 2)
                context.fill(shadow, with: .color(.black.opacity(0.2)))

                // Fill with gradient for depth
                let gradient = Gradient(colors: [
                    Color(hue: 0.58, saturation: 0.9, brightness: 1.0),  // bright blue
                    Color(hue: 0.62, saturation: 1.0, brightness: 0.7)   // deep blue
                ])
                context.fill(arrow, with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: cx, y: cy - h),
                    endPoint: CGPoint(x: cx, y: cy + h)
                ))

                // White border
                context.stroke(arrow, with: .color(.white), lineWidth: 1.5)
            }
            .frame(width: 36, height: 36)
            .rotationEffect(.degrees(heading))
            .animation(.easeInOut(duration: 0.3), value: heading)
        } else {
            // Fallback: pulsing blue dot when heading is unknown
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.blue, .blue.opacity(0.6)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 8
                    )
                )
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().stroke(.white, lineWidth: 2.5)
                )
                .shadow(color: .blue.opacity(0.4), radius: 6)
                .scaleEffect(isPulsing ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
        }
    }
}
