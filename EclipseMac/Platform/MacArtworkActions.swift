import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MacArtworkActions: View {
    let urlString: String
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var failure: String?
    @State private var activeSavePanel: NSSavePanel?
    @State private var generation = UUID()

    var body: some View {
        Menu {
            Button("Save Image…", systemImage: "square.and.arrow.down") { perform(share: false) }
            Button("Share Image…", systemImage: "square.and.arrow.up") { perform(share: true) }
        } label: {
            Image(systemName: busy ? "hourglass" : "ellipsis.circle.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(busy)
        .help("Save or share image")
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .mediaStateWillChangeCurrentUser)) { _ in cancel() }
        .onReceive(NotificationCenter.default.publisher(for: ServiceStoreScope.didChangeNotification)) { _ in cancel() }
        .onDisappear { cancel() }
        .alert("Image Could Not Be Saved", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func cancel() {
        generation = UUID()
        let panel = activeSavePanel
        activeSavePanel = nil
        panel?.cancel(nil)
        task?.cancel()
        task = nil
        busy = false
    }

    private func perform(share: Bool) {
        guard !busy, !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating,
              let window = MacWindowCoordinator.shared.mainWindow, window.isVisible,
              let authority = MacExportPresentationAuthority.capture(window: window),
              let url = URL(string: urlString), url.scheme == "https", url.host == "image.tmdb.org" else { return }
        busy = true
        let token = UUID()
        generation = token
        task = Task { @MainActor in
            defer {
                if generation == token {
                    task = nil
                    if activeSavePanel == nil { busy = false }
                }
            }
            do {
                let data = try await Self.loadImage(url)
                guard !Task.isCancelled, generation == token, authority.isCurrent else { return }
                if share {
                    guard let image = NSImage(data: data), let view = window.contentView else { return }
                    NSSharingServicePicker(items: [image]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
                } else {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.jpeg]
                    panel.nameFieldStringValue = "Eclipse Artwork.jpg"
                    activeSavePanel = panel
                    panel.beginSheetModal(for: window) { response in
                        guard activeSavePanel === panel else { return }
                        activeSavePanel = nil
                        defer { if generation == token { busy = false } }
                        guard response == .OK, let destination = panel.url, generation == token,
                              authority.isCurrent else { return }
                        let scoped = destination.startAccessingSecurityScopedResource()
                        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                        do {
                            guard let image = NSImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.95) else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            try jpeg.write(to: destination, options: .atomic)
                        } catch { failure = error.localizedDescription }
                    }
                }
            } catch {
                guard !Task.isCancelled, generation == token, authority.isCurrent else { return }
                failure = error.localizedDescription
            }
        }
    }

    private nonisolated static func loadImage(_ url: URL) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 30))
        let limit = 24 * 1024 * 1024
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= limit else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data()
        for try await byte in bytes {
            if data.count % 65536 == 0 { try Task.checkCancellation() }
            guard data.count < limit else { throw CocoaError(.fileReadTooLarge) }
            data.append(byte)
        }
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}
