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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Sotto")
                    .font(.headline)
                Spacer()
                AudioLevelView(level: audioManager.inputLevel)
                    .frame(width: 60, height: 8)
            }
            Text("Toggle: \u{2318}\u{21E7}N")
                .font(.caption2)
                .foregroundColor(.secondary)
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
            HStack {
                Toggle("Noise Cancellation", isOn: $audioManager.isEnabled)
                    .toggleStyle(.switch)

                if audioManager.isEnabled {
                    Circle()
                        .fill(audioManager.isBypassed ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                }
            }

            if audioManager.isEnabled {
                Toggle("Bypass", isOn: $audioManager.isBypassed)
                    .toggleStyle(.switch)
                    .font(.caption)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Strength")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(audioManager.attenuation * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $audioManager.attenuation, in: 0...1)
                        .disabled(audioManager.isBypassed)
                }
            }

            DevicePickerView()
                .environmentObject(audioManager)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Toggle("Launch at Login", isOn: $audioManager.launchAtLogin)
                .toggleStyle(.switch)
                .font(.caption)

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
}
