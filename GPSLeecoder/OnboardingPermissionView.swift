import SwiftUI
import UIKit
import CoreLocation

struct OnboardingPermissionView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let status = CLLocationManager().authorizationStatus

        VStack(spacing: 16) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("onboarding_title")
                .font(.title2).bold()
                .multilineTextAlignment(.center)

            Text("onboarding_description")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "onboarding_when_in_use"), systemImage: "checkmark.circle")
                Label(
                    String(localized: "onboarding_always"),
                    systemImage: status == .authorizedAlways ? "checkmark.circle" : "circle"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            VStack(spacing: 12) {
                if status == .notDetermined {
                    Button(String(localized: "onboarding_request_when_in_use")) {
                        GPSLogger.shared.requestAuthorization()
                    }
                    .buttonStyle(.borderedProminent)
                } else if status == .authorizedWhenInUse {
                    Button(String(localized: "onboarding_request_always")) {
                        GPSLogger.shared.requestAlwaysAuthorization()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if status == .denied || status == .restricted {
                    Text("onboarding_denied")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Button(String(localized: "button_open_settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }

                if status == .authorizedAlways {
                    Button(String(localized: "button_close")) {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)

            Text("onboarding_footer")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    OnboardingPermissionView()
}
