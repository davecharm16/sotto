import AVFoundation
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var audioManager: AudioManager
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Welcome to Sotto")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                blackHoleStep
                microphoneStep
                setupStep("3", "Toggle noise cancellation with \u{2318}\u{21E7}N, then pick **BlackHole 2ch** as the input in Zoom, Meet or Discord.")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Button("Done", action: onFinish)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 340)
    }

    private var blackHoleStep: some View {
        setupStep("1", audioManager.isBlackHoleInstalled ? "BlackHole 2ch is installed." : "Install BlackHole 2ch, the virtual mic other apps listen to.") {
            if !audioManager.isBlackHoleInstalled {
                HStack {
                    Button("Get BlackHole") { audioManager.installBlackHole() }
                    Button("Check Again") { audioManager.checkBlackHoleStatus() }
                }
                .font(.caption)
            }
        }
    }

    private var microphoneStep: some View {
        setupStep("2", audioManager.micStatus == .authorized ? "Microphone access is on." : "Allow Sotto to use your microphone.") {
            switch audioManager.micStatus {
            case .authorized:
                EmptyView()
            case .notDetermined:
                Button("Allow Microphone") { audioManager.requestMicrophoneAccess() }
                    .font(.caption)
            default:
                Button("Open Microphone Settings") { NSWorkspace.shared.open(AudioStartError.microphoneSettingsURL) }
                    .font(.caption)
            }
        }
    }

    private func setupStep<Accessory: View>(_ number: String, _ text: LocalizedStringKey,
                                            @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.callout)
                accessory()
            }
        }
    }
}
