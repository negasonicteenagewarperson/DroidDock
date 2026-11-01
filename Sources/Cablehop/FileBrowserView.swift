import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    let device: Device
    @Bindable var model: FileBrowserModel
    @Environment(DeviceManager.self) private var dm
    @Environment(TransferManager.self) private var transfers

    @AppStorage("viewMode") private var viewMode = ViewMode.list
    @State private var selection = Set<RemoteFile.ID>()
    @State private var sort = FileSort()
    @State private var search = ""
    @State private var searchScope = SearchScope.folder
    @State private var isDropTargeted = false
    @State private var quickLookURL: URL?
    @State private var opError: String?
    @State private var busyMessage: String?
    @State private var lastAutoRefresh = Date.distantPast

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: RemoteFile?
    @State private var renameText = ""
    @State private var deleteTargets: [RemoteFile] = []
    @State private var pendingUpload: PendingUpload?
    @State private var showSync = false
    @State private var pendingRevealID: RemoteFile.ID?
    @AppStorage("hideMTPBanner") private var hideMTPBanner = false

    /// False in plain file-transfer mode, where only browsing and copying files are available.
    private var full: Bool { device.hasFullAccess }

    private struct PendingUpload {
        let urls: [URL]
        let dir: String
        let conflicts: Set<String>
    }

    private var isGlobalSearch: Bool {
        searchScope == .everywhere && !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var visibleFiles: [RemoteFile] {
        let source = isGlobalSearch
            ? (model.searchResults ?? [])
            : model.files.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return sort.apply(source.filter { model.showHidden || !$0.isHidden })
    }

    private var selectedFiles: [RemoteFile] { visibleFiles.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            if isGlobalSearch {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Searching all of Internal Storage for “\(search)”")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .glassCapsule()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            } else {
                PathBar(path: model.path) { model.navigate(to: $0) }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                if device.isWired && !dm.reminderDismissed.contains(device.serial) {
                    UnplugReminder(unmount: { dm.requestUnmount(device) },
                                   close: { dm.dismissUnplugReminder(device.serial) })
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
                if !full && !hideMTPBanner {
                    FileTransferModeBanner(hidden: $hideMTPBanner)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
            }
            Divider()
            ZStack {
                if viewMode == .grid {
                    grid
                } else {
                    FileTable(files: visibleFiles, selection: $selection, sort: $sort, serial: device.serial,
                              showLocation: isGlobalSearch,
                              onOpen: { open($0) }, onQuickLook: { quickLook($0) },
                              menu: { menuSpecs(for: $0) },
                              onDrop: { urls, folder in upload(urls, to: folder ?? model.path) },
                              onCopy: { copySelection(cut: false) }, onCut: { copySelection(cut: true) },
                              onPaste: { pasteFromMacClipboard() }, canCopy: full)
                }
                overlayState
            }
            Divider()
            statusBar
        }
        .navigationTitle(dm.displayName(for: device))
        .navigationSubtitle(device.isMTP ? "File transfer over USB" : device.isWireless ? "Connected over Wi-Fi" : "Connected over USB")
        .searchable(text: $search, placement: .toolbar, prompt: searchScope == .folder ? "Filter this folder" : "Search phone")
        .modifier(SearchScopes(enabled: full, scope: $searchScope))
        .toolbar { toolbarContent }
        .focusedSceneValue(\.browser, menuCommands)
        .quickLookPreview($quickLookURL)
        .onAppear { model.loadIfNeeded() }
        .onChange(of: model.path) {
            selection.removeAll()
            if !isGlobalSearch { search = "" }
        }
        .onChange(of: model.files) {
            // "Show in Enclosing Folder": select the item once its folder has loaded.
            if let id = pendingRevealID, model.files.contains(where: { $0.id == id }) {
                selection = [id]
                pendingRevealID = nil
            }
        }
        .onChange(of: search) { updateSearch() }
        .onChange(of: searchScope) { updateSearch() }
        .onChange(of: transfers.completionTick) { handleTransferCompleted() }
        .sheet(isPresented: $showSync) {
            SyncView(device: device, currentPath: model.path)
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { run { try await model.makeFolder(named: newFolderName) } }
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: .init(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget { run { try await model.rename(target, to: renameText) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: .init(get: { !deleteTargets.isEmpty }, set: { if !$0 { deleteTargets = [] } })) {
            Button("Delete", role: .destructive) {
                let targets = deleteTargets
                run { try await model.delete(targets) }
            }
        } message: {
            Text("This permanently deletes them from your phone. It can't be undone.")
        }
        .confirmationDialog(conflictTitle, isPresented: .init(get: { pendingUpload != nil }, set: { if !$0 { pendingUpload = nil } })) {
            if let pending = pendingUpload {
                Button("Replace") { transfers.push(pending.urls, serial: device.serial, to: pending.dir) }
                let fresh = pending.urls.filter { !pending.conflicts.contains($0.lastPathComponent) }
                if !fresh.isEmpty {
                    Button("Skip Existing") { transfers.push(fresh, serial: device.serial, to: pending.dir) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text("Replacing overwrites the copies on your phone. Folders are merged.")
        }
        .alert("Something went wrong", isPresented: .init(get: { opError != nil }, set: { if !$0 { opError = nil } })) {
            Button("OK") {}
        } message: {
            Text(opError ?? "")
        }
    }

    // MARK: Grid

    private var grid: some View {
        FileGridView(files: visibleFiles, serial: device.serial, selection: $selection,
                     open: { open([$0]) },
                     dropIntoFolder: { folder, urls in upload(urls, to: folder.path) },
                     menu: { menuSpecs(for: $0) })
            .onCopyCommand { copySelection(cut: false); return [] }
            .onCutCommand { copySelection(cut: true); return [] }
            .onPasteCommand(of: [.fileURL, .plainText]) { _ in pasteFromMacClipboard() }
            .onDeleteCommand { if !selection.isEmpty { deleteTargets = selectedFiles } }
            .onKeyPress(.space) {
                guard let file = selectedFiles.first, !file.isDirectory else { return .ignored }
                quickLook(file)
                return .handled
            }
            // Dropping on empty space in the grid uploads into the folder being shown.
            .dropDestination(for: URL.self) { urls, _ in
                upload(urls.filter(\.isFileURL), to: model.path)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var overlayState: some View {
        if isGlobalSearch {
            if model.isSearching && (model.searchResults ?? []).isEmpty {
                ProgressView("Searching your phone…").allowsHitTesting(false)
            } else if !model.isSearching && visibleFiles.isEmpty {
                ContentUnavailableView.search(text: search).allowsHitTesting(false)
            }
        } else if let error = model.error {
            ContentUnavailableView {
                Label("Can't open this folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Go to Internal Storage") { model.navigate(to: "/sdcard") }
            }
        } else if model.isLoading && model.files.isEmpty {
            ProgressView().allowsHitTesting(false)
        } else if model.hasLoaded && visibleFiles.isEmpty {
            ContentUnavailableView {
                Label(search.isEmpty ? "This folder is empty" : "No matches",
                      systemImage: search.isEmpty ? "tray" : "magnifyingglass")
            } description: {
                Text(search.isEmpty
                     ? "Drag files from Finder here to send them to your phone."
                     : full ? "Nothing named “\(search)” in this folder. Try searching the entire phone."
                            : "Nothing named “\(search)” in this folder.")
            }
            .allowsHitTesting(false)
        }
    }

    private var statusBar: some View {
        HStack {
            if let busyMessage {
                ProgressView().controlSize(.mini)
                Text(busyMessage)
            } else if selection.isEmpty {
                if isGlobalSearch {
                    Text(model.isSearching ? "Searching…" : "\(visibleFiles.count) results" + (visibleFiles.count >= 500 ? " (showing first 500)" : ""))
                } else {
                    Text("\(visibleFiles.count) items")
                }
            } else {
                let files = selectedFiles
                let total = files.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
                Text("\(files.count) of \(visibleFiles.count) selected" + (total > 0 ? ", \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))" : ""))
            }
            if let clip = model.clipboard {
                Text("· \(clip.items.count) item\(clip.items.count == 1 ? "" : "s") \(clip.cut ? "cut" : "copied"), ready to paste")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if (model.isLoading && !model.files.isEmpty) || (model.isSearching && isGlobalSearch) {
                ProgressView().controlSize(.mini)
            }
            Text("Drop files anywhere to upload").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: Toolbar & menus

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Back (⌘[)")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("Forward (⌘])")
            Button { model.goUp() } label: { Label("Enclosing Folder", systemImage: "arrow.turn.left.up") }
                .disabled(model.path == "/")
                .help("Go to the enclosing folder (⌘↑)")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("View as a list or as a photo grid (⌘1 / ⌘2)")
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { chooseFilesToUpload() } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .help("Upload: send files from your Mac to this folder (⌘U)")
            Button { download(selectedFiles, to: Prefs.downloadFolder) } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .help("Download: save the selected items to your Mac (⌘D)")
            .disabled(selection.isEmpty)
            Button { newFolderName = ""; showNewFolder = true } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New folder on the phone (⇧⌘N)")
            Button { showSync = true } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(!full)
                .help(full ? "Sync: keep a phone folder and a Mac folder up to date" : "Sync. " + FileTransferModeBanner.needsDebugging)
            Button { deleteTargets = selectedFiles } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
                .help("Delete the selected items from the phone (⌘⌫)")
            Menu {
                Toggle("Show Hidden Files", isOn: $model.showHidden)
                Button("Refresh") { model.refresh() }
                Divider()
                Button("Take Phone Screenshot") { takeScreenshot() }
                    .disabled(!full)
                Button("Install App (APK)…") { chooseAPKs() }
                    .disabled(!full)
                if !full {
                    Text("Screenshots and app installs need USB debugging")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More: hidden files, refresh, screenshots and app installs")
        }
        if device.isWired {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { dm.requestUnmount(device) } label: { Label("Unmount", systemImage: "eject") }
                    .help("Unmount: safely disconnect the phone before you unplug the cable (⌘E)")
            }
        }
    }

    /// The right-click menu, shared by the list and the grid.
    private func menuSpecs(for ids: Set<RemoteFile.ID>) -> [MenuSpec] {
        let files = visibleFiles.filter { ids.contains($0.id) }
        if files.isEmpty {
            var specs: [MenuSpec] = [
                .item("Upload Files…") { chooseFilesToUpload() },
                .item("New Folder…") { newFolderName = ""; showNewFolder = true },
            ]
            if full && model.clipboard != nil {
                specs.append(.item("Paste") { pasteFromPhoneClipboard(into: model.path) })
            }
            specs.append(.item("Refresh") { model.refresh() })
            return specs
        }
        var specs: [MenuSpec] = [.item("Open") { open(files) }]
        if files.count == 1, let file = files.first, !file.isDirectory {
            specs.append(.item("Quick Look") { quickLook(file) })
        }
        if isGlobalSearch, files.count == 1, let file = files.first {
            specs.append(.item("Show in Enclosing Folder") { reveal(file) })
        }
        specs += [
            .separator,
            .item("Download") { download(files, to: Prefs.downloadFolder) },
            .item("Download To…") { chooseDownloadFolder(for: files) },
            .separator,
            .item("Copy", enabled: full) { setPhoneClipboard(files, cut: false) },
            .item("Cut", enabled: full) { setPhoneClipboard(files, cut: true) },
        ]
        if full, model.clipboard != nil, files.count == 1, let folder = files.first, folder.isDirectory {
            specs.append(.item("Paste Into “\(folder.name)”") { pasteFromPhoneClipboard(into: folder.path) })
        }
        if files.count == 1, let file = files.first {
            specs.append(.item("Rename…") { renameText = file.name; renameTarget = file })
        }
        specs += [
            .item("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            },
            .separator,
            .item("Delete…") { deleteTargets = files },
        ]
        return specs
    }

    private var deleteTitle: String {
        deleteTargets.count == 1 ? "Delete “\(deleteTargets[0].name)”?" : "Delete \(deleteTargets.count) items?"
    }

    private var conflictTitle: String {
        guard let pending = pendingUpload else { return "" }
        return pending.conflicts.count == 1
            ? "“\(pending.conflicts.first!)” already exists on your phone"
            : "\(pending.conflicts.count) items already exist on your phone"
    }

    /// Hooks for the File / View / Go menus.
    private var menuCommands: BrowserCommands {
        BrowserCommands(
            hasSelection: !selection.isEmpty,
            fullAccess: full,
            canGoBack: model.canGoBack,
            canGoForward: model.canGoForward,
            canGoUp: model.path != "/",
            showHidden: $model.showHidden,
            viewMode: $viewMode,
            newFolder: { newFolderName = ""; showNewFolder = true },
            upload: chooseFilesToUpload,
            download: { download(selectedFiles, to: Prefs.downloadFolder) },
            downloadTo: { chooseDownloadFolder(for: selectedFiles) },
            delete: { if !selection.isEmpty { deleteTargets = selectedFiles } },
            quickLook: { if let file = selectedFiles.first(where: { !$0.isDirectory }) { quickLook(file) } },
            refresh: { model.refresh() },
            sync: { showSync = true },
            screenshot: takeScreenshot,
            installAPK: chooseAPKs,
            back: { model.goBack() },
            forward: { model.goForward() },
            up: { model.goUp() },
            go: { path in
                search = ""
                searchScope = .folder
                model.navigate(to: path)
            })
    }

    // MARK: Actions

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                Log.error("\(error.localizedDescription) [in \(model.path)]", .files)
                opError = error.localizedDescription
            }
        }
    }

    private func updateSearch() {
        if isGlobalSearch {
            selection.removeAll()
            model.searchEverywhere(search)
        } else {
            model.clearSearch()
        }
    }

    private func reveal(_ file: RemoteFile) {
        search = ""
        searchScope = .folder
        pendingRevealID = file.id
        model.navigate(to: file.parentPath)
    }

    private func handleTransferCompleted() {
        guard let t = transfers.lastCompleted, t.direction == .push, t.serial == device.serial,
              RemotePath.isWithin(t.destination, model.path) else { return }
        // Big batches finish lots of files in a row; refresh at most every 2 seconds plus once at the end.
        let othersPending = transfers.items.contains { $0.state.isActive && $0.direction == .push && $0.serial == device.serial }
        if !othersPending || Date().timeIntervalSince(lastAutoRefresh) > 2 {
            lastAutoRefresh = Date()
            model.refresh()
            if !othersPending { dm.refreshInfo(device.serial) }
        }
    }

    private func upload(_ urls: [URL], to dir: String) {
        guard !urls.isEmpty else { return }
        if dir == model.path {
            confirmUpload(urls, to: dir, existing: model.files)
        } else {
            // Dropped onto a folder: look inside it first, so nothing in there is replaced without asking.
            Task {
                let existing = (try? await model.list(dir)) ?? []
                confirmUpload(urls, to: dir, existing: existing)
            }
        }
    }

    private func confirmUpload(_ urls: [URL], to dir: String, existing: [RemoteFile]) {
        let conflicts = FileBrowserModel.uploadConflicts(urls, existing: existing)
        if conflicts.isEmpty {
            transfers.push(urls, serial: device.serial, to: dir)
        } else {
            pendingUpload = PendingUpload(urls: urls, dir: dir, conflicts: conflicts)
        }
    }

    private func open(_ files: [RemoteFile]) {
        if files.count == 1, let file = files.first, file.isDirectory {
            if isGlobalSearch { search = ""; searchScope = .folder }
            model.navigate(to: file.path)
            return
        }
        for file in files where !file.isDirectory {
            busyMessage = "Opening \(file.name)…"
            run {
                defer { busyMessage = nil }
                let url = try await PhoneFiles.pullToTemp(serial: device.serial, file: file)
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func quickLook(_ file: RemoteFile) {
        busyMessage = "Loading preview…"
        run {
            defer { busyMessage = nil }
            quickLookURL = try await PhoneFiles.pullToTemp(serial: device.serial, file: file)
        }
    }

    private func download(_ files: [RemoteFile], to folder: URL) {
        guard !files.isEmpty else { return }
        Notifier.requestPermission()
        transfers.pull(files, serial: device.serial, to: folder)
    }

    private func chooseDownloadFolder(for files: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url { download(files, to: url) }
    }

    private func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send to Phone"
        if panel.runModal() == .OK {
            Notifier.requestPermission()
            upload(panel.urls, to: model.path)
        }
    }

    private func chooseAPKs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.prompt = "Install"
        panel.message = "Choose Android apps (.apk) to install on your phone"
        if panel.runModal() == .OK { transfers.install(panel.urls, serial: device.serial) }
    }

    private func takeScreenshot() {
        busyMessage = "Taking screenshot…"
        // Wi-Fi phones without a model name are called "192.168.1.5:5555"; keep the file name Finder-safe.
        let name = dm.displayName(for: device).replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
        run {
            defer { busyMessage = nil }
            let data = try await ADB.screenshot(serial: device.serial)
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: ".")
            let folder = Prefs.downloadFolder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(name) Screenshot \(stamp).png")
            try data.write(to: url)
            quickLookURL = url
        }
    }

    // MARK: Clipboard

    private func setPhoneClipboard(_ files: [RemoteFile], cut: Bool) {
        model.copy(files, cut: cut)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
        model.clipboardChangeCount = NSPasteboard.general.changeCount
    }

    /// ⌘C / ⌘X: remembers the items for pasting elsewhere on the phone, and puts their paths on the Mac clipboard.
    private func copySelection(cut: Bool) {
        guard full, !selection.isEmpty else { NSSound.beep(); return }
        setPhoneClipboard(selectedFiles, cut: cut)
    }

    /// ⌘V: pastes phone items copied in Cablehop, or uploads files copied in Finder.
    private func pasteFromMacClipboard() {
        let selected = selectedFiles
        let destination = selected.count == 1 && selected[0].isDirectory ? selected[0].path : model.path
        let board = NSPasteboard.general
        if full && model.clipboard != nil && board.changeCount == model.clipboardChangeCount {
            pasteFromPhoneClipboard(into: destination)
            return
        }
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { NSSound.beep(); return }
        upload(urls, to: destination)
    }

    private func pasteFromPhoneClipboard(into dir: String) {
        let count = model.clipboard?.items.count ?? 0
        busyMessage = "Pasting \(count) item\(count == 1 ? "" : "s")…"
        run {
            defer { busyMessage = nil }
            try await model.paste(into: dir)
        }
    }
}

struct PathBar: View {
    let path: String
    let navigate: (String) -> Void

    private var crumbs: [(name: String, path: String)] {
        if path == "/sdcard" || path.hasPrefix("/sdcard/") {
            var result = [(name: "Internal Storage", path: "/sdcard")]
            var current = "/sdcard"
            for part in path.dropFirst("/sdcard".count).split(separator: "/") {
                current += "/" + part
                result.append((String(part), current))
            }
            return result
        }
        var result = [(name: "Phone", path: "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button(crumb.name) { navigate(crumb.path) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(index == crumbs.count - 1 ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                        .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                        .help(crumb.path)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .font(.callout)
        .glassCapsule()
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Adds the "This Folder / Entire Phone" search scopes only when phone-wide search is possible.
private struct SearchScopes: ViewModifier {
    let enabled: Bool
    @Binding var scope: SearchScope

    func body(content: Content) -> some View {
        if enabled {
            content.searchScopes($scope) {
                Text("This Folder").tag(SearchScope.folder)
                Text("Entire Phone").tag(SearchScope.everywhere)
            }
        } else {
            content
        }
    }
}

/// Explains why some features are greyed out in file-transfer mode, and how to unlock them.
struct FileTransferModeBanner: View {
    static let needsDebugging = "Needs USB debugging. Your phone is connected in File transfer mode."
    @Binding var hidden: Bool
    @State private var showHow = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
            Text("File transfer mode: browse and copy files. Search, sync, screenshots and app installs need USB debugging.")
                .lineLimit(2)
            Button("How to turn it on") { showHow = true }
                .buttonStyle(.link)
                .popover(isPresented: $showHow, arrowEdge: .bottom) { UnlockFeaturesHelp().padding(16).frame(width: 340) }
            Spacer()
            Button { hidden = true } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide this message")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentCard(cornerRadius: 14)
    }
}

/// Shown each time a phone is connected by cable: unmount before unplugging, like ejecting a disk.
struct UnplugReminder: View {
    let unmount: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "eject.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
            Text("Before you unplug the cable, unmount the phone so nothing is cut off mid-copy.")
                .lineLimit(2)
            Spacer()
            Button("Unmount", action: unmount)
                .glassButton()
                .help("Safely disconnect the phone (⌘E)")
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide this until the next time the phone is connected")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentCard(cornerRadius: 14)
    }
}

struct UnlockFeaturesHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unlock every feature").font(.headline)
            Text("1. On the phone, open Settings › About phone and tap Build number 7 times.")
            Text("2. Go to Settings › System › Developer options and turn on USB debugging.")
            Text("3. Replug the cable and tap Allow on the phone.")
            Text("Cablehop switches over automatically. File transfer keeps working either way.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
