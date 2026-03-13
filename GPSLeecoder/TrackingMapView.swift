import SwiftUI
import MapKit
import CoreLocation

// MARK: - Main recording view (lightweight, no map)

struct TrackingMapView: View {
    @StateObject private var state = GPSLogger.shared.trackState
    @AppStorage("flushIntervalMinutes") private var flushIntervalMinutes: Int = AppConfig.defaultFlushIntervalMinutes
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showMap = false
    @State private var fileToShare: URL?
    @State private var showStopConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Heading compass
            CompassHeading(heading: state.currentHeading)
                .padding(.bottom, 24)

            // GPS accuracy badge
            if state.currentAccuracy >= 0 {
                Text("± \(String(format: "%.0f", state.currentAccuracy)) m")
                    .font(.system(.caption, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(state.currentAccuracy <= 5 ? .green : state.currentAccuracy <= 15 ? .primary : .orange)
                    .padding(.bottom, 8)
            }

            // Live stats grid
            if state.isLogging {
                StatsGrid(speed: state.currentSpeed,
                          altitude: state.currentAltitude,
                          distance: state.totalDistance,
                          pointCount: state.pointCount)
                    .padding(.horizontal, 24)
            } else if state.currentFileURL != nil {
                // 마지막 세션 요약
                StatsGrid(speed: 0,
                          altitude: state.currentAltitude,
                          distance: state.totalDistance,
                          pointCount: state.pointCount)
                    .padding(.horizontal, 24)
                    .opacity(0.5)
            }

            Spacer()

            // Big start / stop button
            recordButton
                .padding(.bottom, 32)
        }
        .onAppear {
            GPSLogger.shared.requestAuthorization()
            let status = CLLocationManager().authorizationStatus
            if status != .authorizedAlways {
                showOnboarding = true
            }
            GPSLogger.shared.requestInitialLocation()
            GPSLogger.shared.startHeadingUpdates()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    showHistory = true
                } label: {
                    Label(String(localized: "button_history"), systemImage: "icloud.and.arrow.up")
                }

                Button {
                    showSettings = true
                } label: {
                    Label(String(localized: "button_settings"), systemImage: "gear")
                }

                if state.isLogging {
                    Button {
                        showMap = true
                    } label: {
                        Label(String(localized: "button_view_map"), systemImage: "map")
                    }
                }

                if !state.isLogging, let url = state.currentFileURL {
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
        .sheet(isPresented: $showMap) {
            NavigationStack { LiveMapSheet(state: state) }
        }
        .sheet(isPresented: Binding(
            get: { fileToShare != nil },
            set: { if !$0 { fileToShare = nil } }
        )) {
            if let url = fileToShare {
                ShareSheetView(activityItems: [url])
            }
        }
        .confirmationDialog(
            String(localized: "stop_confirm_title"),
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "stop_confirm_stop"), role: .destructive) {
                GPSLogger.shared.stopLogging()
            }
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        if state.isLogging {
            Button {
                showStopConfirmation = true
            } label: {
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.15))
                        .frame(width: 100, height: 100)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.red)
                        .frame(width: 36, height: 36)
                }
            }
        } else {
            Button {
                let flush = min(max(flushIntervalMinutes, 0), 30)
                let record = UserDefaults.standard.integer(forKey: "recordIntervalSeconds")
                let recordClamped = max(1, record == 0 ? AppConfig.defaultRecordIntervalSeconds : record)
                let started = GPSLogger.shared.startLogging(
                    flushInterval: flush,
                    recordInterval: recordClamped
                )
                if !started {
                    showOnboarding = true
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.15))
                        .frame(width: 100, height: 100)
                    Circle()
                        .fill(.red)
                        .frame(width: 36, height: 36)
                }
            }
        }
    }
}

// MARK: - Compass heading display

private struct CompassHeading: View {
    let heading: Double

    /// Cumulative rotation angle that avoids the 359°→0° wrap-around jump.
    @State private var smoothAngle: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                    .frame(width: 120, height: 120)

                // Cardinal direction ticks (fixed)
                ForEach([0, 90, 180, 270], id: \.self) { deg in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 1.5, height: 10)
                        .offset(y: -55)
                        .rotationEffect(.degrees(Double(deg)))
                }

                // N label fixed at top
                Text("N")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .offset(y: -42)

                // Compass needle: red tip always points north
                if heading >= 0 {
                    CompassNeedle()
                        .rotationEffect(.degrees(smoothAngle))
                        .animation(.easeInOut(duration: 0.3), value: smoothAngle)
                } else {
                    Image(systemName: "location.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }

            if heading >= 0 {
                Text("\(Int(heading))\u{00B0}")
                    .font(.system(.title2, design: .rounded, weight: .medium))
                    .monospacedDigit()
            }
        }
        .onChange(of: heading) { _, newHeading in
            guard newHeading >= 0 else { return }
            let target = -newHeading
            // Compute shortest-path delta (range -180...180)
            var delta = target - smoothAngle
            delta = delta.truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            smoothAngle += delta
        }
        .onAppear {
            if heading >= 0 {
                smoothAngle = -heading
            }
        }
    }
}

private struct CompassNeedle: View {
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let len: CGFloat = 42
            let w: CGFloat = 6

            // North half — red
            var north = Path()
            north.move(to: CGPoint(x: cx, y: cy - len))
            north.addLine(to: CGPoint(x: cx + w, y: cy))
            north.addLine(to: CGPoint(x: cx, y: cy + 2))
            north.addLine(to: CGPoint(x: cx - w, y: cy))
            north.closeSubpath()
            ctx.fill(north, with: .color(.red))

            // South half — gray
            var south = Path()
            south.move(to: CGPoint(x: cx, y: cy + len))
            south.addLine(to: CGPoint(x: cx + w, y: cy))
            south.addLine(to: CGPoint(x: cx, y: cy - 2))
            south.addLine(to: CGPoint(x: cx - w, y: cy))
            south.closeSubpath()
            ctx.fill(south, with: .color(Color(UIColor.systemGray3)))

            // Pivot dot
            let pr: CGFloat = 3.5
            ctx.fill(Path(ellipseIn: CGRect(x: cx - pr, y: cy - pr, width: pr * 2, height: pr * 2)),
                     with: .color(Color(UIColor.systemBackground)))
        }
        .frame(width: 20, height: 100)
    }
}

// MARK: - Stats grid

private struct StatsGrid: View {
    let speed: Double
    let altitude: Double
    let distance: Double
    let pointCount: Int

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            statCell(icon: "speedometer", value: speedText, unit: "km/h")
            statCell(icon: "mountain.2", value: altitudeText, unit: "m")
            statCell(icon: "point.topleft.down.to.point.bottomright.curvepath", value: distanceText, unit: distanceUnit)
            statCell(icon: "mappin.and.ellipse", value: "\(pointCount)", unit: "pts")
        }
    }

    private func statCell(icon: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var speedText: String {
        String(format: "%.1f", max(0, speed) * 3.6)
    }

    private var altitudeText: String {
        String(format: "%.0f", altitude)
    }

    private var distanceText: String {
        distance >= 1000
            ? String(format: "%.2f", distance / 1000)
            : String(format: "%.0f", distance)
    }

    private var distanceUnit: String {
        distance >= 1000 ? "km" : "m"
    }
}

// MARK: - Live map sheet (loaded on demand)

private struct LiveMapSheet: View {
    @ObservedObject var state: TrackState
    @Environment(\.dismiss) private var dismiss

    @State private var cameraPosition: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var isFollowing = true
    @State private var isProgrammaticMove = false
    @State private var currentCameraDistance: Double = 500

    var body: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                UserAnnotation()
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
                    isFollowing = false
                }
            }
            .onChange(of: state.currentLocation) { _, newLoc in
                guard isFollowing, let loc = newLoc else { return }
                isProgrammaticMove = true
                withAnimation(.easeInOut(duration: 0.35)) {
                    cameraPosition = .camera(MapCamera(
                        centerCoordinate: loc,
                        distance: currentCameraDistance
                    ))
                }
            }
            .onAppear {
                if let loc = state.currentLocation {
                    isProgrammaticMove = true
                    cameraPosition = .camera(MapCamera(
                        centerCoordinate: loc,
                        distance: 500
                    ))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "button_close")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isFollowing = true
                        isProgrammaticMove = true
                        if let loc = state.currentLocation {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                cameraPosition = .camera(MapCamera(
                                    centerCoordinate: loc,
                                    distance: currentCameraDistance
                                ))
                            }
                        }
                    } label: {
                        Image(systemName: isFollowing ? "location.circle.fill" : "location.circle")
                    }
                }
            }
            .navigationTitle(String(localized: "nav_title_logging"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    NavigationStack { TrackingMapView() }
}
