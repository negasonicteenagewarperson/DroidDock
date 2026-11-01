import SwiftUI

struct WelcomeView: View {
    @Binding var showPairing: Bool

    var body: some View {
        VStack(spacing: 24) {
            AppLogo(size: 112)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            VStack(spacing: 6) {
                Text("Connect your Android phone").font(.largeTitle.bold())
                Text("Plug it in with a USB cable, or connect over Wi-Fi.").font(.title3).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                StepCard(icon: "cable.connector", title: "Just plug it in", steps: [
                    "Connect the phone with a USB cable and unlock it",
                    "Pull down notifications › tap the USB notification",
                    "Choose “File transfer”",
                ])
                StepCard(icon: "hammer", title: "Unlock every feature", steps: [
                    "Settings › About phone › tap Build number 7 times",
                    "Developer options › turn on USB debugging",
                    "Replug and tap Allow: adds search, sync, Wi-Fi and more",
                ])
            }
            if ADB.path == nil {
                Text("USB debugging features also need Google's free adb tool: `brew install android-platform-tools`")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button { showPairing = true } label: {
                Label("Connect Wirelessly…", systemImage: "wifi")
            }
            .controlSize(.extraLarge)
            .glassButton()
            .help("Connect over Wi-Fi. Needs Wireless debugging (Android 11+) and adb")
            .disabled(ADB.path == nil)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StepCard: View {
    let icon: String
    let title: String
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(.primary)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white).frame(width: 20, height: 20)
                        .background(Color.accentColor, in: Circle())
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 280, alignment: .leading)
        .contentCard(cornerRadius: 20)
    }
}

struct DeviceStateView: View {
    let device: Device
    @Environment(DeviceManager.self) private var dm

    var body: some View {
        switch device.state {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to your phone…").foregroundStyle(.secondary)
            }
        case .unmounting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Unmounting \(dm.displayName(for: device))…").foregroundStyle(.secondary)
                Text("Don't unplug the cable yet.").font(.callout).foregroundStyle(.tertiary)
            }
        case .unmounted:
            ContentUnavailableView {
                Label("Safe to unplug", systemImage: "eject.circle")
            } description: {
                Text("\(dm.displayName(for: device)) is unmounted. You can remove the cable now.")
            } actions: {
                Button("Mount Again") { dm.mountAgain(device.serial) }
                    .help("Use the phone again without unplugging it")
            }
        case .locked:
            ContentUnavailableView("Unlock your phone", systemImage: "lock.iphone",
                                   description: Text("Android only shares files once the phone is unlocked. Cablehop will open it automatically."))
        case .unavailable:
            ContentUnavailableView {
                Label("Can't open the phone", systemImage: "exclamationmark.triangle")
            } description: {
                Text(dm.mtpErrors[device.serial] ?? "Another app may be using it.")
            } actions: {
                Button("Try Again") { dm.retryMTP(device.serial) }
            }
        case .unsupported:
            ContentUnavailableView("This Android version is too old for USB debugging", systemImage: "clock.arrow.circlepath",
                                   description: Text("Cablehop's USB debugging features need Android 6.0 or later. Turn off USB debugging on the phone and choose “File transfer” in its USB notification: browsing and copying work on every Android version."))
        case .unauthorized:
            ContentUnavailableView("Allow access on your phone", systemImage: "lock.iphone",
                                   description: Text("Unlock your phone and tap “Allow” on the USB debugging prompt. Tick “Always allow from this computer” so you don't get asked again."))
        case .offline:
            ContentUnavailableView("Phone is offline", systemImage: "bolt.horizontal.circle",
                                   description: Text("Unplug and reconnect the cable, or turn USB debugging off and on again."))
        case .noPermissions:
            ContentUnavailableView("No permission", systemImage: "exclamationmark.lock",
                                   description: Text("adb doesn't have permission to talk to this device. Reconnect it and accept the prompt."))
        default:
            ContentUnavailableView("Phone is in \(device.state.rawValue) mode", systemImage: "wrench.and.screwdriver",
                                   description: Text("Restart the phone normally to browse its files."))
        }
    }
}
