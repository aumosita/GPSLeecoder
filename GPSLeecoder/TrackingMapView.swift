import SwiftUI
import MapKit
import CoreLocation

struct TrackingMapView: View {
    @StateObject private var state = GPSLogger.shared.trackState
    @AppStorage("flushIntervalMinutes") private var flushIntervalMinutes: Int = AppConfig.defaultFlushIntervalMinutes
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var fileToShare: URL?

    @State private var cameraPosition: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)

    var body: some View {
        Map(position: $cameraPosition) {
            if state.coordinates.count > 1 {
                MapPolyline(coordinates: state.coordinates)
                    .stroke(.blue, lineWidth: 3)
            }
        }
        .onAppear {
            Task { await GPSLogger.shared.requestAuthorization() }
            let status = CLLocationManager.authorizationStatus()
            if status == .notDetermined || status == .denied {
                showOnboarding = true
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
                    cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
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
                            let recordClamped = max(1, record == 0 ? 5 : record)
                            await GPSLogger.shared.startLogging(updateInterval: flush, suggestedName: nil, recordIntervalSeconds: recordClamped)
                        }
                    } label: {
                        Label(String(localized: "button_start"), systemImage: "record.circle")
                    }
                }

                if !state.isLogging, let url = state.currentFileURL {
                    Spacer()
                    Button {
                        markAsExported(url)
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

    private func markAsExported(_ url: URL) {
        let key = "exportedFiles"
        let data = UserDefaults.standard.data(forKey: key) ?? Data()
        var names = (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
        names.insert(url.lastPathComponent)
        if let encoded = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
}

#Preview {
    NavigationStack { TrackingMapView() }
}
