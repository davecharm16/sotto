import SwiftUI

struct SottoMenuView: View {
    @EnvironmentObject var audioManager: AudioManager

    var body: some View {
        VStack(spacing: 12) {
            header

            if !audioManager.isBlackHoleInstalled {
                blackHolePrompt
            } else {
                mainControls
            }

            Divider()

            footer
        }
        .padding()
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            Text("Sotto")
                .font(.headline)
            Spacer()
            AudioLevelView(level: audioManager.inputLevel)
                .frame(width: 60, height: 8)
        }
    }

    private var blackHolePrompt: some View {
        VStack(spacing: 8) {
            Text("Virtual audio device required")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("BlackHole 2ch routes your processed voice to other apps")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Get BlackHole") {
                audioManager.installBlackHole()
            }
            .buttonStyle(.borderedProminent)

            Button("Check Again") {
                audioManager.checkBlackHoleStatus()
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(.vertical, 8)
    }

    private var mainControls: some View {
        VStack(spacing: 12) {
            Toggle("Noise Cancellation", isOn: $audioManager.isEnabled)
                .toggleStyle(.switch)

            DevicePickerView()
                .environmentObject(audioManager)
        }
    }

    private var footer: some View {
        HStack {
            if let device = audioManager.selectedDevice {
                Text(device.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Quit") {
                audioManager.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }
}
