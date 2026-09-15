import AppKit
import SwiftUI

@MainActor
struct MacExportPresentationAuthority {
    let progress: ProgressManager.ProfileMutationAuthority
    let servicesGeneration: Int
    let wasKidsProfile: Bool
    let windowGeneration: UInt64
    let window: NSWindow

    static func capture(window: NSWindow) -> MacExportPresentationAuthority? {
        let profiles = ProfileManager.shared
        guard profiles.rosterStoreIsReadable, let profile = profiles.activeProfile,
              window.isVisible, !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating,
              let progress = ProgressManager.shared.profileMutationAuthority(requiredOwner: profile.id) else { return nil }
        return MacExportPresentationAuthority(progress: progress, servicesGeneration: ServiceStoreScope.generation,
            wasKidsProfile: profile.isKidsProfile, windowGeneration: MacLaunchProfileAccess.windowGeneration, window: window)
    }

    var isCurrent: Bool {
        ProfileManager.shared.rosterStoreIsReadable
            && ProfileManager.shared.activeProfile?.isKidsProfile == wasKidsProfile
            && ProgressManager.shared.profileMutationAuthorityIsCurrent(progress)
            && ServiceStoreScope.generation == servicesGeneration
            && windowGeneration == MacLaunchProfileAccess.windowGeneration
            && window.isVisible && !MacLaunchProfileAccess.requiresUnlock && !MacLaunchProfileAccess.isTerminating
    }
}

@MainActor
struct ActivityView: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var activeSavePanel: NSSavePanel?
    @State private var generation = UUID()
    @State private var invalidated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Share or Export").font(.title2.bold())
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if let url = item as? URL {
                    Label(url.lastPathComponent, systemImage: "doc")
                } else if let text = item as? String {
                    Text(text).lineLimit(4).textSelection(.enabled)
                }
            }
            HStack {
                Button("Done") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let url = items.first as? URL, url.isFileURL {
                    Button("Save a Copy…") { save(url) }
                }
                Button("Share…") {
                    guard !invalidated, let window = NSApplication.shared.keyWindow,
                          let authority = MacExportPresentationAuthority.capture(window: window), authority.isCurrent,
                          let view = window.contentView else { return }
                    NSSharingServicePicker(items: items).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 420)
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in cancel(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in cancel(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: .mediaStateWillChangeCurrentUser)) { _ in cancel(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: ServiceStoreScope.didChangeNotification)) { _ in cancel(); dismiss() }
        .onDisappear { cancel() }
        .alert("Export Failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func cancel() {
        invalidated = true
        generation = UUID()
        let panel = activeSavePanel
        activeSavePanel = nil
        panel?.cancel(nil)
    }

    private func save(_ source: URL) {
        guard !invalidated, activeSavePanel == nil, let window = NSApplication.shared.keyWindow,
              let authority = MacExportPresentationAuthority.capture(window: window) else { return }
        let token = UUID()
        generation = token
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        activeSavePanel = panel
        panel.beginSheetModal(for: window) { response in
            guard activeSavePanel === panel else { return }
            activeSavePanel = nil
            guard response == .OK, let destination = panel.url, generation == token,
                  !invalidated, authority.isCurrent else { return }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            do {
                guard source.standardizedFileURL != destination.standardizedFileURL else { return }
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: source, to: temporary)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}
