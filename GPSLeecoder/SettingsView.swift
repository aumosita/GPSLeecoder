import SwiftUI

struct SettingsView: View {
    @AppStorage("flushIntervalMinutes") private var flushIntervalMinutes: Int = AppConfig.defaultFlushIntervalMinutes
    @AppStorage("recordIntervalSeconds") private var recordIntervalSeconds: Int = 5

    var body: some View {
        Form {
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
