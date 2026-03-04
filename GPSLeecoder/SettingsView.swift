import SwiftUI

struct SettingsView: View {
    @AppStorage("flushIntervalMinutes") private var flushIntervalMinutes: Int = AppConfig.defaultFlushIntervalMinutes
    @AppStorage("recordIntervalSeconds") private var recordIntervalSeconds: Int = 30
    @AppStorage("saveMode") private var saveModeRaw: String = SaveMode.daily.rawValue
    @AppStorage("distanceFilterMeters") private var distanceFilterMeters: Int = 10
    @AppStorage("accuracyFilterMeters") private var accuracyFilterMeters: Int = 100
    @AppStorage("dropboxUploadEnabled") private var dropboxUploadEnabled: Bool = false

    @State private var dropboxLinked: Bool = false
    @State private var authCode: String = ""
    @State private var isExchanging: Bool = false
    @State private var authError: String? = nil

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

            Section {
                Stepper(value: $distanceFilterMeters, in: 0...500, step: 5) {
                    HStack {
                        Text("settings_distance_filter")
                        Spacer()
                        Text(distanceFilterMeters == 0
                             ? String(localized: "settings_filter_off")
                             : String(localized: "settings_distance_filter_value \(distanceFilterMeters)"))
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(value: $accuracyFilterMeters, in: 0...500, step: 5) {
                    HStack {
                        Text("settings_accuracy_filter")
                        Spacer()
                        Text(accuracyFilterMeters == 0
                             ? String(localized: "settings_filter_off")
                             : String(localized: "settings_accuracy_filter_value \(accuracyFilterMeters)"))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("settings_section_filters")
            } footer: {
                Text("settings_filters_note")
            }

            Section {
                Toggle(String(localized: "settings_dropbox_toggle"), isOn: $dropboxUploadEnabled)

                if dropboxUploadEnabled {
                    if dropboxLinked {
                        Label {
                            Text("settings_dropbox_connected")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }

                        Button(role: .destructive) {
                            DropboxUploader.unlink()
                            dropboxLinked = false
                            dropboxUploadEnabled = false
                        } label: {
                            Label(String(localized: "settings_dropbox_disconnect"),
                                  systemImage: "xmark.circle")
                        }
                    } else {
                        Button {
                            UIApplication.shared.open(DropboxUploader.authorizationURL)
                        } label: {
                            Label(String(localized: "settings_dropbox_connect"),
                                  systemImage: "arrow.up.right.square")
                        }

                        TextField(String(localized: "settings_dropbox_auth_code"), text: $authCode)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button {
                            guard !authCode.isEmpty else { return }
                            isExchanging = true
                            authError = nil
                            Task {
                                let success = await DropboxUploader.exchangeAuthorizationCode(authCode)
                                isExchanging = false
                                if success {
                                    dropboxLinked = true
                                    authCode = ""
                                } else {
                                    authError = String(localized: "settings_dropbox_auth_failed")
                                }
                            }
                        } label: {
                            if isExchanging {
                                ProgressView()
                            } else {
                                Text("settings_dropbox_auth_submit")
                            }
                        }
                        .disabled(authCode.isEmpty || isExchanging)

                        if let error = authError {
                            Label {
                                Text(error)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                            }
                            .font(.caption)
                        }
                    }
                }
            } header: {
                Text("settings_section_dropbox")
            } footer: {
                Text("settings_dropbox_note")
            }

            Section(footer: Text("settings_footer")) {
                EmptyView()
            }
        }
        .navigationTitle(String(localized: "nav_title_settings"))
        .onAppear {
            dropboxLinked = DropboxUploader.isLinked
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
