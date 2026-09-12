#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MacDownloadMoveCoordinator: ObservableObject {
    static let shared = MacDownloadMoveCoordinator()
    @Published private(set) var isMoving = false
    private var task: Task<Void, Never>?
    private var admissionsStopped = false
    private let isAppTerminating: @MainActor () -> Bool

    init(isAppTerminating: @escaping @MainActor () -> Bool = { MacLaunchProfileAccess.isTerminating }) {
        self.isAppTerminating = isAppTerminating
    }

    @discardableResult
    func beginMove(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        guard task == nil, !admissionsStopped, !isAppTerminating() else { return false }
        isMoving = true
        task = Task { @MainActor in
            await operation()
            task = nil
            isMoving = false
        }
        return true
    }

    func prepareForMacTermination(timeout: Duration = .seconds(5)) async -> Bool {
        admissionsStopped = true
        task?.cancel()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while task != nil, clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return task == nil }
        }
        return task == nil
    }

    func resumeAfterCancelledMacTermination() {
        guard !isAppTerminating() else { return }
        admissionsStopped = false
    }
}

@MainActor
struct MacDownloadStorageView: View {
    @ObservedObject private var registry = DownloadStorageRegistry.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var video = DownloadManager.shared
    @ObservedObject private var reader = ReaderDownloadManager.shared
    @ObservedObject private var mover = MacDownloadMoveCoordinator.shared
    @State private var availability: [UUID: String] = [:]
    @State private var moveTarget: UUID?
    @State private var panelIsOpen = false
    @State private var activeFolderPanel: NSOpenPanel?
    @State private var progressMessage: String?
    @State private var errorMessage: String?
    @State private var refreshGeneration = UUID()

    private var moving: Bool { mover.isMoving }

    var body: some View {
        Form {
            if !registry.isReadable {
                Section {
                    Label("Download locations could not be read", systemImage: "externaldrive.badge.exclamationmark")
                    Text("The saved locations and files have been kept. Close and reopen Eclipse after checking storage access.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !profiles.rosterStoreIsReadable || profiles.isKidsModeActive {
                Section {
                    Label("Switch to a grown-up profile to manage download folders.", systemImage: "lock")
                }
            }
            Section("New Downloads") {
                Picker("Save new downloads in", selection: Binding(get: { registry.defaultRootID }, set: { setDefaultRoot($0) })) {
                    ForEach(registry.roots) { root in Text(root.displayName).tag(root.id) }
                }
                .disabled(!canManage || moving || panelIsOpen)
                Button("Choose Folder…") { presentFolderPanel(reconnecting: nil) }
                    .disabled(!canManage || moving || panelIsOpen)
                Text("Eclipse creates its own download folder inside your selection. Existing downloads keep their saved locations until you choose Move Downloads.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Registered Folders") {
                ForEach(registry.roots) { root in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: root.isInternal ? "internaldrive" : "externaldrive")
                            .font(.title3).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(root.displayName).fontWeight(.medium)
                            Text(folderDescription(root)).font(.caption).foregroundStyle(.secondary)
                            Text(availability[root.id] ?? "Checking folder…")
                                .font(.caption).foregroundStyle(availability[root.id] == "Available" ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        if !root.isInternal {
                            Button("Reconnect…") { presentFolderPanel(reconnecting: root) }
                                .disabled(!canManage || moving || panelIsOpen)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button("Check Folder Access") { refreshAvailability() }.disabled(moving)
            }
            Section("Move Existing Downloads") {
                Picker("Destination", selection: Binding(get: { moveTarget ?? registry.defaultRootID }, set: { moveTarget = $0 })) {
                    ForEach(registry.roots) { root in Text(root.displayName).tag(root.id) }
                }
                .disabled(!canManage || moving || panelIsOpen)
                Text("Video and Reader downloads pause while Eclipse copies and verifies the files. Close any downloaded video or chapter before moving its folder.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Move Downloads") { startMove() }
                    .disabled(!canManage || moving || panelIsOpen || !hasDownloadsToMove)
                if let progressMessage {
                    HStack {
                        if moving { ProgressView().controlSize(.small) }
                        Text(progressMessage).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Download Folders")
        .task { refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: DownloadStorageRegistry.didChangeNotification)) { _ in refreshAvailability() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshAvailability() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in cancelFolderPanel() }
        .onDisappear { cancelFolderPanel() }
        .alert("Download Storage", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var canManage: Bool {
        registry.isReadable && profiles.rosterStoreIsReadable && !profiles.isKidsModeActive
            && profiles.activeProfile?.isKidsProfile == false
    }

    private var hasDownloadsToMove: Bool {
        let target = moveTarget ?? registry.defaultRootID
        return video.storageLocations.contains { $0.rootID != target }
            || reader.referencedMacStorageLocations.contains { $0.rootID != target }
    }

    private func folderDescription(_ root: DownloadStorageRoot) -> String {
        let videos = video.downloads.filter { video.storageLocation(for: $0).rootID == root.id }.count
        let chapters = reader.downloads.filter { ($0.storageLocation?.rootID ?? DownloadStorageRegistry.internalRootID) == root.id }.count
        let videoCount = video.metadataLoadFailed ? "Video count unavailable" : "\(videos) videos"
        let readerCount = reader.macStorageIndexIsReadable ? "\(chapters) Reader chapters" : "Reader count unavailable"
        let counts = videoCount + " · " + readerCount
        return root.id == registry.defaultRootID ? counts + " · New downloads" : counts
    }

    private func setDefaultRoot(_ id: UUID) {
        guard let authority = MacDownloadStorageAuthority.capture(), authority.isCurrent(), !moving else { return }
        do { try registry.setDefaultRoot(id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func presentFolderPanel(reconnecting root: DownloadStorageRoot?) {
        guard let authority = MacDownloadStorageAuthority.capture(), authority.isCurrent(), !moving, !panelIsOpen else { return }
        guard let window = NSApplication.shared.keyWindow ?? MacWindowCoordinator.shared.mainWindow else {
            errorMessage = "Open the Eclipse window to choose a download folder."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = root == nil
        panel.prompt = root == nil ? "Choose Folder" : "Reconnect"
        panel.message = root.map { "Choose the folder containing \($0.ownedDirectoryName)." }
            ?? "Eclipse will create a dedicated download folder inside this folder."
        let windowGeneration = MacLaunchProfileAccess.windowGeneration
        activeFolderPanel = panel
        panelIsOpen = true
        panel.beginSheetModal(for: window) { response in
            guard activeFolderPanel === panel else { return }
            activeFolderPanel = nil
            panelIsOpen = false
            guard response == .OK, let url = panel.url else { return }
            guard windowGeneration == MacLaunchProfileAccess.windowGeneration,
                  window.isVisible, !MacLaunchProfileAccess.isTerminating else { return }
            guard authority.isCurrent() else {
                errorMessage = "The active profile changed. Choose the folder again from a grown-up profile."
                return
            }
            do {
                if let root { try registry.reconnect(root.id, selectedFolder: url) }
                else { _ = try registry.selectDefaultFolder(url) }
                refreshAvailability()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func cancelFolderPanel() {
        let panel = activeFolderPanel
        activeFolderPanel = nil
        panelIsOpen = false
        panel?.cancel(nil)
    }

    private func refreshAvailability() {
        let generation = UUID()
        refreshGeneration = generation
        let roots = registry.roots
        Task {
            let results = await Task.detached(priority: .utility) {
                var results: [UUID: String] = [:]
                for root in roots {
                    do {
                        let lease = try DownloadStorageRegistry.shared.acquire(DownloadStorageLocation(rootID: root.id, relativePath: "Video"))
                        lease.close()
                        results[root.id] = "Available"
                    } catch { results[root.id] = error.localizedDescription }
                }
                return results
            }.value
            guard refreshGeneration == generation else { return }
            availability = results
        }
    }

    private func startMove() {
        guard let authority = MacDownloadStorageAuthority.capture(), authority.isCurrent(), !moving else { return }
        let target = moveTarget ?? registry.defaultRootID
        progressMessage = "Saving download checkpoints…"
        mover.beginMove {
            defer {
                video.resumeAfterCancelledMacTermination()
                reader.resumeAfterCancelledMacTermination()
                refreshAvailability()
            }
            guard !Task.isCancelled else { return }
            guard await video.prepareForMacTermination(), await reader.prepareForMacTermination() else {
                errorMessage = "The download queues could not save their checkpoints. Existing files have been kept."
                progressMessage = nil
                return
            }
            guard !Task.isCancelled, authority.isCurrent() else {
                errorMessage = "The active profile changed. Start the move again from a grown-up profile."
                progressMessage = nil
                return
            }
            do {
                if video.storageLocations.contains(where: { $0.rootID != target }) {
                    progressMessage = "Copying and verifying video downloads…"
                    try await video.moveDownloads(toRootID: target, keepAdmissionsStopped: true)
                }
                guard !Task.isCancelled, authority.isCurrent() else { throw DownloadStorageError.invalidMove }
                let readerIDs = Set(reader.downloads.filter {
                    ($0.storageLocation?.rootID ?? DownloadStorageRegistry.internalRootID) != target
                }.map(\.id))
                if !readerIDs.isEmpty {
                    progressMessage = "Copying and verifying Reader downloads…"
                    try await reader.moveDownloads(ids: readerIDs, toRootID: target)
                }
                progressMessage = "Downloads have been moved. Resume paused downloads when you are ready."
            } catch {
                errorMessage = error.localizedDescription + " Completed moves keep their new locations; remaining downloads keep their saved locations."
                progressMessage = nil
            }
        }
    }
}
#endif
