import SwiftUI

struct SidebarView: View {
    @Environment(DeviceManager.self) private var dm
    @Environment(TransferManager.self) private var transfers
    @Binding var showPairing: Bool
    @State private var actionError: String?

    private enum Item: Hashable {
        case device(String)
        case location(String)
    }

    /// Like Finder: when the browser is showing one of the sidebar locations, that row is
    /// highlighted; otherwise the phone itself is.
    private var selection: Binding<Item?> {
        Binding {
            guard let serial = dm.selectedSerial else { return nil }
            if dm.selectedDevice?.state == .device {
                let path = dm.browser(for: serial).path
                if QuickLocation.all.contains(where: { $0.path == path }) { return .location(path) }
            }
            return .device(serial)
        } set: { item in
            switch item {
            case .device(let serial):
                if serial == dm.selectedSerial, dm.selectedDevice?.state == .device {
                    dm.browser(for: serial).navigate(to: "/sdcard")  // clicking the current phone = its storage
                } else {
                    dm.selectedSerial = serial
                }
            case .location(let path):
                if let serial = dm.selectedSerial { dm.browser(for: serial).navigate(to: path) }
            case nil:
                break
            }
        }
    }

    var body: some View {
        List(selection: selection) {
            Section("Devices") {
                ForEach(dm.devices) { device in
                    DeviceRow(device: device, name: dm.displayName(for: device), info: dm.info[device.serial],
                              unmount: device.canUnmount ? { dm.requestUnmount(device) } : nil)
                        .tag(Item.device(device.serial))
                        .contextMenu { deviceMenu(device) }
                        .dropDestination(for: URL.self) { urls, _ in
                            guard device.state == .device else { return false }
                            // APKs get installed; anything else lands in the phone's Download folder.
                            let installable = device.hasFullAccess
                            let apks = installable ? urls.filter { $0.pathExtension.lowercased() == "apk" } : []
                            let others = urls.filter { !apks.contains($0) }
                            if !apks.isEmpty { transfers.install(apks, serial: device.serial) }
                            if !others.isEmpty { transfers.push(others, serial: device.serial, to: "/sdcard/Download") }
                            return true
                        }
                        .help("Drop files here to send them to Downloads, or .apk files to install")
                }
                if dm.devices.isEmpty {
                    Text("No phones connected").foregroundStyle(.secondary)
                }
            }

            if let device = dm.selectedDevice, device.state == .device {
                Section("Locations") {
                    ForEach(QuickLocation.all) { location in
                        Label(location.name, systemImage: location.icon)
                            .tag(Item.location(location.path))
                            .dropDestination(for: URL.self) { urls, _ in
                                transfers.push(urls, serial: device.serial, to: location.path)
                                return true
                            }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let device = dm.selectedDevice, let info = dm.info[device.serial], info.storageTotal > 0 {
                    StorageGauge(info: info)
                }
                Button {
                    showPairing = true
                } label: {
                    Label("Connect Wirelessly…", systemImage: "wifi")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .glassButton()
                .help("Connect to a phone over Wi-Fi (⌘K). Needs Wireless debugging.")
                .disabled(ADB.path == nil)
            }
            .padding(12)
        }
        .alert("Couldn't complete that", isPresented: .init(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private func deviceMenu(_ device: Device) -> some View {
        if device.canUnmount {
            Button("Unmount") { dm.requestUnmount(device) }
            Divider()
        } else if device.state == .unmounted {
            Button("Mount Again") { dm.mountAgain(device.serial) }
            Divider()
        }
        if device.isMTP {
            if device.state == .unavailable {
                Button("Try Again") { dm.retryMTP(device.serial) }
            }
        } else if device.isWireless {
            Button("Disconnect") { Task { await dm.disconnect(device) } }
        } else if device.state == .device {
            Button("Switch to Wi-Fi") {
                Task {
                    do { try await dm.switchToWiFi(device) } catch { actionError = error.localizedDescription }
                }
            }
        }
        Button("Refresh Info") { dm.refreshInfo(device.serial) }
        Divider()
        Button("Copy Serial") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(device.serial, forType: .string)
        }
    }
}

struct DeviceRow: View {
    let device: Device
    let name: String
    let info: DeviceInfo?
    /// Shown as an eject button, like a disk in Finder's sidebar.
    var unmount: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.title2)
                .foregroundStyle(device.state == .device ? Color.accentColor : .secondary)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: device.isWireless ? "wifi" : device.isMTP ? "folder.fill" : "cable.connector")
                        .font(.system(size: 8, weight: .bold))
                        .padding(2)
                        .background(.background, in: Circle())
                        .offset(x: 5, y: 3)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let unmount {
                Button(action: unmount) {
                    Image(systemName: "eject.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Unmount: safely disconnect the phone before you unplug the cable (⌘E)")
                .accessibilityLabel("Unmount \(name)")
            } else if device.state == .unmounting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch device.state {
        case .device:
            var parts: [String] = [device.isMTP ? "File transfer" : device.isWireless ? "Wi-Fi" : "USB"]
            if let v = info?.androidVersion, !v.isEmpty { parts.append("Android \(v)") }
            if let b = info?.battery { parts.append("\(b)%") }
            return parts.joined(separator: " · ")
        case .unauthorized: return "Tap “Allow” on your phone"
        case .offline: return "Offline"
        case .noPermissions: return "No permission"
        case .connecting: return "Connecting…"
        case .locked: return "Unlock your phone"
        case .unavailable: return "In use by another app"
        case .unsupported: return "Use File transfer mode"
        case .unmounting: return "Unmounting…"
        case .unmounted: return "Unmounted · safe to unplug"
        default: return device.state.rawValue.capitalized
        }
    }
}

struct StorageGauge: View {
    let info: DeviceInfo

    var body: some View {
        let used = info.storageTotal - info.storageFree
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(used), total: Double(max(info.storageTotal, 1)))
                .tint(Double(info.storageFree) / Double(max(info.storageTotal, 1)) < 0.1 ? .red : .accentColor)
            Text("\(bytes(info.storageFree)) free of \(bytes(info.storageTotal))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
