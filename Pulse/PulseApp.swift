import PulseCore
import SwiftUI

@main
struct PulseApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Temporary shell. The real experience arrives with the UI milestone; this exists so the project
/// builds, signs, and installs on the device from day one — the deployment path is the thing we most
/// want de-risked early.
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tint)
            Text("Pulse")
                .font(.largeTitle.weight(.semibold))
            Text(verbatim: Money(major: 45_000, currency: .uzs).description)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    RootView()
}
