import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var audioManager: AudioManager
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Setup Complete!")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Now configure your communication apps to use **BlackHole 2ch** as the input device.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                setupStep("1", "Open Zoom, Meet, or Discord")
                setupStep("2", "Go to Audio Settings")
                setupStep("3", "Select 'BlackHole 2ch' as input")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Button("Got it") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 320)
    }

    private func setupStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())

            Text(text)
                .font(.callout)
        }
    }
}
