import SwiftUI

/// What the menu bar can do to the file browser that's currently on screen.
struct BrowserCommands {
    var hasSelection: Bool
    var fullAccess: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var canGoUp: Bool
    var showHidden: Binding<Bool>
    var viewMode: Binding<ViewMode>

    var newFolder: () -> Void
    var upload: () -> Void
    var download: () -> Void
    var downloadTo: () -> Void
    var delete: () -> Void
    var quickLook: () -> Void
    var refresh: () -> Void
    var sync: () -> Void
    var screenshot: () -> Void
    var installAPK: () -> Void
    var back: () -> Void
    var forward: () -> Void
    var up: () -> Void
    var go: (String) -> Void
}

private struct BrowserCommandsKey: FocusedValueKey {
    typealias Value = BrowserCommands
}

extension FocusedValues {
    var browser: BrowserCommands? {
        get { self[BrowserCommandsKey.self] }
        set { self[BrowserCommandsKey.self] = newValue }
    }
}

struct CablehopCommands: Commands {
    @FocusedValue(\.browser) private var browser
    let devices: DeviceManager
    let showPairing: () -> Void
    let toggleTransfers: () -> Void
    let reportProblem: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await Updater.shared.check(userInitiated: true) } }
        }

        CommandGroup(replacing: .help) {
            Button("Report a Problem…") { reportProblem() }
            Button("View Logs") { openWindow(id: "logs") }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Save Logs…") { LogStore.saveWithPanel() }
            Divider()
            Button("Cablehop on GitHub") { openURL(AppInfo.repositoryURL) }
            Button("Release Notes") { openURL(AppInfo.releasesURL) }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Folder") { browser?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser == nil)
            Button("Connect Wirelessly…") { showPairing() }
                .keyboardShortcut("k", modifiers: .command)
            // Like Finder's File › Eject: safely disconnect before pulling the cable.
            Button(devices.selectedDevice.map { "Unmount “\(devices.displayName(for: $0))”" } ?? "Unmount Phone") {
                if let device = devices.selectedDevice { devices.requestUnmount(device) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(devices.selectedDevice?.canUnmount != true)
            Divider()
            Button("Send Files to Phone…") { browser?.upload() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(browser == nil)
            Button("Download") { browser?.download() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(browser?.hasSelection != true)
            Button("Download To…") { browser?.downloadTo() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(browser?.hasSelection != true)
            Button("Quick Look") { browser?.quickLook() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(browser?.hasSelection != true)
            Divider()
            Button("Sync Folders…") { browser?.sync() }
                .disabled(browser?.fullAccess != true)
            Button("Install App (APK)…") { browser?.installAPK() }
                .disabled(browser?.fullAccess != true)
            Button("Take Phone Screenshot") { browser?.screenshot() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(browser?.fullAccess != true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete…") { browser?.delete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(browser?.hasSelection != true)
        }

        CommandGroup(before: .toolbar) {
            Button("as List") { browser?.viewMode.wrappedValue = .list }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(browser == nil)
            Button("as Grid") { browser?.viewMode.wrappedValue = .grid }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(browser == nil)
            Divider()
            Button(browser?.showHidden.wrappedValue == true ? "Hide Hidden Files" : "Show Hidden Files") {
                browser?.showHidden.wrappedValue.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(browser == nil)
            Button("Refresh") { browser?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(browser == nil)
            Button("Show Transfers") { toggleTransfers() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { browser?.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(browser?.canGoBack != true)
            Button("Forward") { browser?.forward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(browser?.canGoForward != true)
            Button("Enclosing Folder") { browser?.up() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(browser?.canGoUp != true)
            Divider()
            ForEach(Array(QuickLocation.all.enumerated()), id: \.offset) { index, location in
                if let key = QuickLocation.shortcut(at: index) {
                    Button(location.name) { browser?.go(location.path) }
                        .keyboardShortcut(key, modifiers: [.command, .shift])
                        .disabled(browser == nil)
                } else {
                    Button(location.name) { browser?.go(location.path) }
                        .disabled(browser == nil)
                }
            }
        }
    }
}
