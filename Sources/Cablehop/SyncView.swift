import SwiftUI

/// Works out which files a sync job still needs to copy. Sync only ever adds or updates files; it never deletes.
enum SyncPlanner {
    struct Plan {
        var copies: [SyncCopy]
        var upToDate: Int
        var bytes: Int64 { copies.reduce(0) { $0 + $1.size } }
    }

    static func plan(_ job: SyncJob, serial: String) async throws -> Plan {
        let localRoot = URL(fileURLWithPath: job.localPath, isDirectory: true)
        let remote = try await ADB.listFilesRecursive(serial: serial, root: job.remotePath)
            .filter { !$0.key.split(separator: "/").contains { $0.hasPrefix(".") } }
        let local = await Task.detached(priority: .userInitiated) { LocalFiles.filesRecursive(in: localRoot) }.value

        let (from, to) = job.direction == .phoneToMac ? (remote, local) : (local, remote)
        if from.isEmpty {
            throw ADBError.failed(job.direction == .phoneToMac
                ? "No files found in \(job.remotePath) on the phone."
                : "No files found in \(job.localPath).")
        }

        var copies: [SyncCopy] = []
        var upToDate = 0
        let rootPath = localRoot.standardizedFileURL.path + "/"
        for (relative, size) in from.sorted(by: { $0.key < $1.key }) {
            // Phone names are cleaned before they become Mac file names (see RemotePath.safeLocalName).
            let localRelative = job.direction == .phoneToMac
                ? relative.split(separator: "/").map { RemotePath.safeLocalName(String($0)) }.joined(separator: "/")
                : relative
            if to[job.direction == .phoneToMac ? localRelative : relative] == size { upToDate += 1; continue }
            // Never let a crafted name on the phone write outside the chosen folders.
            guard !relative.isEmpty, RemotePath.isSafe("/" + relative) else { continue }
            let remotePath = RemotePath.join(job.remotePath, relative)
            let localPath = localRoot.appendingPathComponent(localRelative).standardizedFileURL.path
            guard localPath.hasPrefix(rootPath), RemotePath.isWithin(remotePath, job.remotePath) else { continue }
            copies.append(SyncCopy(
                name: (relative as NSString).lastPathComponent,
                source: job.direction == .phoneToMac ? remotePath : localPath,
                destination: job.direction == .phoneToMac ? localPath : remotePath,
                size: size))
        }
        return Plan(copies: copies, upToDate: upToDate)
    }
}

struct SyncView: View {
    let device: Device
    let currentPath: String
    @Environment(TransferManager.self) private var transfers
    @Environment(\.dismiss) private var dismiss

    @State private var jobs: [SyncJob] = SyncView.loadJobs()
    @State private var draft = SyncJob(remotePath: "/sdcard/DCIM/Camera",
                                       localPath: Prefs.downloadFolder.appendingPathComponent("Phone Backup").path,
                                       direction: .phoneToMac)
    @State private var runningJob: UUID?
    @State private var status: (text: String, isError: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync Folders").font(.title2.bold())
            Text("Copies only files that are new or changed. Nothing is ever deleted on either side.")
                .foregroundStyle(.secondary)

            GroupBox("New sync") {
                Form {
                    Picker("Direction", selection: $draft.direction) {
                        ForEach(SyncDirection.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Phone folder") {
                        HStack {
                            TextField("", text: $draft.remotePath).textFieldStyle(.roundedBorder)
                            Button("Use Current") { draft.remotePath = currentPath }
                                .help(currentPath)
                        }
                    }
                    LabeledContent("Mac folder") {
                        HStack {
                            Text((draft.localPath as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Choose…") { chooseLocalFolder() }
                        }
                    }
                }
                .padding(6)
                HStack {
                    Spacer()
                    Button("Save") { save(draft) }
                    Button("Sync Now") {
                        let job = draft
                        save(job)
                        Task { await run(job) }
                    }
                    .prominentGlassButton()
                    .disabled(runningJob != nil || draft.remotePath.isEmpty)
                }
                .padding([.horizontal, .bottom], 6)
            }

            if !jobs.isEmpty {
                Text("Saved syncs").font(.headline)
                VStack(spacing: 6) {
                    ForEach(jobs) { job in
                        HStack(spacing: 10) {
                            Image(systemName: job.direction == .phoneToMac ? "arrow.down.circle" : "arrow.up.circle")
                                .font(.title3).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.title)
                                Text(job.lastRun.map { "Last synced \($0.formatted(.relative(presentation: .named)))" } ?? "Never synced")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .help("\(job.remotePath)  ⇄  \(job.localPath)")
                            Spacer()
                            if runningJob == job.id { ProgressView().controlSize(.small) }
                            Button("Sync") { Task { await run(job) } }
                                .disabled(runningJob != nil)
                            Button { delete(job) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Remove this saved sync")
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            HStack {
                if let status {
                    Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(status.isError ? .orange : .green)
                    Text(status.text).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { draft.localPath = url.path }
    }

    private func run(_ job: SyncJob) async {
        runningJob = job.id
        status = ("Comparing folders…", false)
        defer { runningJob = nil }
        do {
            let plan = try await SyncPlanner.plan(job, serial: device.serial)
            if plan.copies.isEmpty {
                status = ("Everything's already in sync (\(plan.upToDate) files).", false)
            } else {
                try? FileManager.default.createDirectory(atPath: job.localPath, withIntermediateDirectories: true)
                transfers.enqueue(plan.copies, direction: job.direction == .phoneToMac ? .pull : .push, serial: device.serial)
                Log.info("Sync \(job.direction.label): \(plan.copies.count) to copy, \(plan.upToDate) up to date", .sync)
                let size = ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)
                status = ("Copying \(plan.copies.count) files (\(size)). \(plan.upToDate) were already up to date.", false)
            }
            var updated = job
            updated.lastRun = Date()
            save(updated)
        } catch {
            status = (error.localizedDescription, true)
            Log.warning("Sync failed: \(error.localizedDescription)", .sync)
        }
    }

    private func save(_ job: SyncJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[i] = job
        } else if let i = jobs.firstIndex(where: {
            $0.remotePath == job.remotePath && $0.localPath == job.localPath && $0.direction == job.direction
        }) {
            jobs[i].lastRun = job.lastRun ?? jobs[i].lastRun
        } else {
            jobs.append(job)
        }
        SyncView.storeJobs(jobs)
    }

    private func delete(_ job: SyncJob) {
        jobs.removeAll { $0.id == job.id }
        SyncView.storeJobs(jobs)
    }

    private static func loadJobs() -> [SyncJob] {
        guard let data = UserDefaults.standard.data(forKey: "syncJobs") else { return [] }
        return (try? JSONDecoder().decode([SyncJob].self, from: data)) ?? []
    }

    private static func storeJobs(_ jobs: [SyncJob]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(jobs), forKey: "syncJobs")
    }
}
