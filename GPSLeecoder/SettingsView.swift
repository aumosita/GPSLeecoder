import SwiftUI

struct SettingsView: View {
    @AppStorage("flushIntervalMinutes") private var flushIntervalMinutes: Int = AppConfig.defaultFlushIntervalMinutes
    @AppStorage("recordIntervalSeconds") private var recordIntervalSeconds: Int = 5
    @AppStorage("saveMode") private var saveModeRaw: String = SaveMode.session.rawValue

    private var saveMode: SaveMode {
        get { SaveMode(rawValue: saveModeRaw) ?? .session }
    }

    var body: some View {
        Form {
            Section("settings_section_save_mode") {
                Picker(String(localized: "settings_save_mode"), selection: $saveModeRaw) {
                    Text("save_mode_session").tag(SaveMode.session.rawValue)
                    Text("save_mode_daily").tag(SaveMode.daily.rawValue)
                }
                .pickerStyle(.segmented)
            }

            Section("settings_section_recording") {
                Stepper(value: $flushIntervalMinutes, in: 1...60, step: 1) {
                    HStack {
                        Text("settings_sync_interval")
                        Spacer()
                        Text("settings_sync_interval_value \(flushIntervalMinutes)")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(String(localized: "settings_accessibility_update"))

                Slider(value: Binding(get: {
                    Double(flushIntervalMinutes)
                }, set: { newValue in
                    flushIntervalMinutes = Int(newValue)
                }), in: 1...60, step: 1) {
                    Text("settings_sync_label")
                } minimumValueLabel: {
                    Text("settings_sync_min_label")
                } maximumValueLabel: {
                    Text("settings_sync_max_label")
                }

                Stepper(value: $recordIntervalSeconds, in: 1...60, step: 1) {
                    HStack {
                        Text("settings_record_interval")
                        Spacer()
                        Text("settings_record_interval_value \(recordIntervalSeconds)")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(String(localized: "settings_accessibility_record"))

                Slider(value: Binding(get: {
                    Double(recordIntervalSeconds)
                }, set: { newValue in
                    recordIntervalSeconds = Int(newValue)
                }), in: 1...60, step: 1) {
                    Text("settings_record_label")
                } minimumValueLabel: {
                    Text("settings_record_min_label")
                } maximumValueLabel: {
                    Text("settings_record_max_label")
                }
            }

            Section {
                if recordIntervalSeconds < AppConfig.intermittentGPSThreshold {
                    Label {
                        Text("settings_gps_continuous")
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                    }
                } else {
                    Label {
                        Text("settings_gps_intermittent")
                    } icon: {
                        Image(systemName: "bolt.batteryblock")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("settings_section_gps_power")
            } footer: {
                Text("settings_gps_power_note")
            }

            Section(footer: Text("settings_footer")) {
                EmptyView()
            }
        }
        .navigationTitle(String(localized: "nav_title_settings"))
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
