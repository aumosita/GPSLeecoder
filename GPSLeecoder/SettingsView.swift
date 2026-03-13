import SwiftUI

struct SettingsView: View {
    @AppStorage("flushIntervalMinutes") private var flushIntervalMinutes: Int = AppConfig.defaultFlushIntervalMinutes
    @AppStorage("recordIntervalSeconds") private var recordIntervalSeconds: Int = AppConfig.defaultRecordIntervalSeconds
    @AppStorage("saveMode") private var saveModeRaw: String = SaveMode.daily.rawValue
    @AppStorage("distanceFilterMeters") private var distanceFilterMeters: Int = AppConfig.defaultDistanceFilterMeters
    @AppStorage("accuracyFilterMeters") private var accuracyFilterMeters: Int = AppConfig.defaultAccuracyFilterMeters

    @AppStorage("hwDistanceFilter") private var hwDistanceFilter: Bool = AppConfig.defaultHwDistanceFilter
    @AppStorage("activityTypeFitness") private var activityTypeFitness: Bool = AppConfig.defaultActivityTypeFitness
    @AppStorage("dutyCycling") private var dutyCycling: Bool = AppConfig.defaultDutyCycling
    @AppStorage("stationaryPowerSave") private var stationaryPowerSave: Bool = AppConfig.defaultStationaryPowerSave
    @AppStorage("maxPerformance") private var maxPerformance: Bool = AppConfig.defaultMaxPerformance

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
                Stepper(value: $flushIntervalMinutes, in: 0...30, step: 1) {
                    HStack {
                        Text("settings_sync_interval")
                        Spacer()
                        Text(flushIntervalMinutes == 0
                             ? String(localized: "settings_filter_off")
                             : String(localized: "settings_sync_interval_value \(flushIntervalMinutes)"))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(String(localized: "settings_accessibility_update"))

                Slider(value: Binding(get: {
                    Double(flushIntervalMinutes)
                }, set: { newValue in
                    flushIntervalMinutes = Int(newValue)
                }), in: 0...30, step: 1) {
                    Text("settings_sync_label")
                } minimumValueLabel: {
                    Text("settings_filter_off_short")
                } maximumValueLabel: {
                    Text("settings_sync_max_label")
                }

                Stepper(value: $recordIntervalSeconds, in: 1...30, step: 1) {
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
                }), in: 1...30, step: 1) {
                    Text("settings_record_label")
                } minimumValueLabel: {
                    Text("settings_record_min_label")
                } maximumValueLabel: {
                    Text("settings_record_max_label")
                }
            }

            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("settings_distance_filter")
                        Spacer()
                        Text(distanceFilterMeters == 0
                             ? String(localized: "settings_filter_off")
                             : String(localized: "settings_distance_filter_value \(distanceFilterMeters)"))
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: Binding(get: {
                        Double(distanceFilterMeters)
                    }, set: { newValue in
                        distanceFilterMeters = Int(newValue)
                    }), in: 0...50, step: 1) {
                        Text("settings_distance_filter")
                    } minimumValueLabel: {
                        Text("settings_filter_off_short")
                    } maximumValueLabel: {
                        Text("settings_distance_filter_max")
                    }
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("settings_accuracy_filter")
                        Spacer()
                        Text(accuracyFilterMeters == 0
                             ? String(localized: "settings_filter_off")
                             : String(localized: "settings_accuracy_filter_value \(accuracyFilterMeters)"))
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: Binding(get: {
                        Double(accuracyFilterMeters)
                    }, set: { newValue in
                        accuracyFilterMeters = Int(newValue)
                    }), in: 0...500, step: 5) {
                        Text("settings_accuracy_filter")
                    } minimumValueLabel: {
                        Text("settings_filter_off_short")
                    } maximumValueLabel: {
                        Text("settings_accuracy_filter_max")
                    }
                }
            } header: {
                Text("settings_section_filters")
            } footer: {
                Text("settings_filters_note")
            }

            Section {
                Toggle(isOn: $maxPerformance) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings_power_max_performance")
                        Text("settings_power_max_performance_desc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.orange)

                Toggle(isOn: $hwDistanceFilter) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings_power_hw_distance")
                        Text("settings_power_hw_distance_desc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(maxPerformance)

                Toggle(isOn: $activityTypeFitness) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings_power_activity_fitness")
                        Text("settings_power_activity_fitness_desc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(maxPerformance)

                Toggle(isOn: $dutyCycling) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings_power_duty_cycling")
                        Text("settings_power_duty_cycling_desc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(maxPerformance)

                Toggle(isOn: $stationaryPowerSave) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings_power_stationary")
                        Text("settings_power_stationary_desc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(maxPerformance)
            } header: {
                Text("settings_section_gps_power")
            } footer: {
                Text("settings_power_footer")
            }

            Section("Diagnostics") {
                if let url = DiagLog.fileURL {
                    ShareLink(item: url) {
                        Label("Export diag.log", systemImage: "doc.text")
                    }
                }
                Button(role: .destructive) {
                    DiagLog.clear()
                } label: {
                    Label("Clear log", systemImage: "trash")
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
