import SwiftUI

@main
struct CablehopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var devices: DeviceManager
    @State private var transfers: TransferManager
    @State private var ui = UIState()

    init() {
        // Must run before anything reads settings (the transfer history loads as soon as it's created).
        RenameMigration.run()
        _devices = State(initialValue: DeviceManager())
        _transfers = State(initialValue: TransferManager())
    }

    var body: some Scene {
        // One window, like most Mac utilities; ⌘N is "New Folder" instead of a duplicate window.
        Window("Cablehop", id: "main") {
            ContentView()
                .environment(devices)
                .environment(transfers)
                .environment(ui)
                .frame(minWidth: 920, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 720)
        .commands {
            CablehopCommands(devices: devices,
                             showPairing: { ui.showPairing = true },
                             toggleTransfers: { TransfersPopover.shared.toggle() },
                             reportProblem: { ui.showReportProblem = true })
        }

        Window("Logs", id: "logs") {
            LogsView()
        }
        .defaultSize(width: 860, height: 540)
        .commandsRemoved()

        Settings {
            SettingsView()
        }
    }
}

@MainActor
@Observable
final class UIState {
    var showPairing = false
    var showReportProblem = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets the app show a Dock icon and menu bar even when launched as a bare binary.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Log.info("Cablehop \(AppInfo.version) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString) (\(LogStore.architecture)); adb \(ADB.path == nil ? "not installed" : "available")")
        DispatchQueue.global(qos: .background).async { Caches.prune() }
        MainActor.assumeIsolated { Updater.shared.checkInBackgroundIfDue() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("Cablehop quit")
        LogStore.shared.flush()
    }

    /// Closing the window keeps Cablehop running, like Finder, so copies in progress carry on and an
    /// accidental click doesn't quit. Click the Dock icon to bring the window back; quit with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let transfers = TransferManager.current, transfers.activeCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Transfers are still in progress"
        alert.informativeText = "\(transfers.activeCount) transfer\(transfers.activeCount == 1 ? " is" : "s are") not finished. Quitting will cancel \(transfers.activeCount == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Keep Transferring")
        alert.addButton(withTitle: "Quit Anyway")
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        transfers.cancelAllBeforeQuit()
        return .terminateNow
    }
}

struct ContentView: View {
    @Environment(DeviceManager.self) private var dm
    @Environment(TransferManager.self) private var transfers
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        NavigationSplitView {
            SidebarView(showPairing: $ui.showPairing)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            if let device = dm.selectedDevice {
                if device.state == .device {
                    FileBrowserView(device: device, model: dm.browser(for: device.serial))
                        .id(device.serial)
                } else {
                    DeviceStateView(device: device)
                        .logoInTitleBar()
                }
            } else {
                WelcomeView(showPairing: $ui.showPairing)
                    .logoInTitleBar()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                TransfersToolbarButton()
            }
        }
        .onAppear { TransfersPopover.shared.transfers = transfers }
        .onChange(of: transfers.startedTick) {
            // Pop the transfers list open whenever a copy starts.
            TransfersPopover.shared.show(automatically: true)
        }
        .onChange(of: transfers.activeCount) { _, active in
            guard active == 0, TransfersPopover.shared.openedAutomatically else { return }
            let anyFailed = transfers.items.contains { if case .failed = $0.state { return true }; return false }
            guard !anyFailed else { return }  // leave it open so the error is seen
            Task {
                try? await Task.sleep(for: .seconds(3))
                if transfers.activeCount == 0 { TransfersPopover.shared.closeIfOpenedAutomatically() }
            }
        }
        .sheet(isPresented: $ui.showPairing) {
            WirelessPairingView()
        }
        .sheet(isPresented: $ui.showReportProblem) {
            ReportProblemView()
        }
        .sheet(isPresented: Bindable(Updater.shared).isPresented) {
            UpdateView()
        }
        .confirmationDialog(unmountTitle,
                            isPresented: .init(get: { dm.pendingUnmount != nil }, set: { if !$0 { dm.pendingUnmount = nil } }),
                            presenting: dm.pendingUnmount) { device in
            Button("Stop Transfers and Unmount", role: .destructive) { Task { await dm.unmount(device) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Unmounting stops them. Half-copied files on your Mac are removed, and files being sent to the phone may be left incomplete there.")
        }
    }

    private var unmountTitle: String {
        guard let device = dm.pendingUnmount else { return "" }
        let count = transfers.activeCount(for: device.serial)
        return "\(count) transfer\(count == 1 ? " is" : "s are") still running on \(dm.displayName(for: device))"
    }
}
