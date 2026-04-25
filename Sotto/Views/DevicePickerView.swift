import SwiftUI

struct DevicePickerView: View {
    @EnvironmentObject var audioManager: AudioManager

    var body: some View {
        Picker("Input Device", selection: selectedDeviceBinding) {
            ForEach(audioManager.inputDevices) { device in
                Text(device.name)
                    .tag(device as AudioDevice?)
            }
        }
        .pickerStyle(.menu)
    }

    private var selectedDeviceBinding: Binding<AudioDevice?> {
        Binding(
            get: { audioManager.selectedDevice },
            set: { audioManager.selectedDevice = $0 }
        )
    }
}
