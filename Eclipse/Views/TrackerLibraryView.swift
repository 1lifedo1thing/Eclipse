import SwiftUI
import Kingfisher

struct TrackerLibrarySourcePicker: View {
    @Binding var selection: TrackerLibrarySource

    var body: some View {
        Picker("Library Source", selection: $selection) {
            ForEach(TrackerLibrarySource.allCases) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("trackerLibrarySourcePicker")
        .padding(.horizontal)
    }
}

private struct TrackerLibraryLoadIdentity: Equatable {
    let session: TrackerLibrarySession?
    let kind: TrackerLibraryKind
    let status: TrackerLibraryStatus?
    let revision: Int
    let isActive: Bool
}

@MainActor
private final class TrackerLibraryViewModel: ObservableObject {
    @Published private(set) var entries: [TrackerLibraryEntry] = []
    @Published private(set) var session: TrackerLibrarySession?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var identity: TrackerLibraryLoadIdentity?

    func load(_ value: TrackerLibraryLoadIdentity) async {
        clear()
        identity = value
        guard value.isActive, let session = value.session else {
            error = TrackerLibraryError.unavailable.localizedDescription
            return
        }
        self.session = session
        isLoading = true
        do {
            let entries = try await TrackerManager.shared.fetchLibrary(session: session, kind: value.kind, status: value.status)
            guard !Task.isCancelled, identity == value, TrackerManager.shared.librarySessionIsCurrent(session) else { return }
            self.entries = entries
            isLoading = false
        } catch is CancellationError {
            if identity == value { isLoading = false }
        } catch {
            guard !Task.isCancelled, identity == value, TrackerManager.shared.librarySessionIsCurrent(session) else { return }
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func accept(_ entry: TrackerLibraryEntry, session: TrackerLibrarySession) {
        guard self.session == session, TrackerManager.shared.librarySessionIsCurrent(session) else { return }
        if let status = identity?.status, entry.status != status {
            entries.removeAll { $0.id == entry.id }
        } else if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        }
    }

    func clear() {
        identity = nil
        entries = []
        session = nil
        isLoading = false
        error = nil
    }
}

private struct TrackerLibraryEditingSelection: Identifiable {
    let entry: TrackerLibraryEntry
    let session: TrackerLibrarySession
    var id: String { entry.id }
}

struct TrackerLibraryView: View {
    let service: TrackerService
    var isActive: Bool = true
    @State private var kind: TrackerLibraryKind
    @State private var status: TrackerLibraryStatus? = .current
    @State private var query = ""
    @State private var genre: String?
    @State private var revision = 0
    @State private var editing: TrackerLibraryEditingSelection?
    @State private var openingID: String?
    @State private var openingTask: Task<Void, Never>?
    @State private var navigationResult: TMDBSearchResult?
    @State private var navigationActive = false
    @State private var navigationError: String?
    @StateObject private var model = TrackerLibraryViewModel()
    @ObservedObject private var tracker = TrackerManager.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @AppStorage(TrackerLibrarySettings.enabledKey) private var enabled = TrackerLibrarySettings.defaultEnabled
    @AppStorage(ImageDataSaverSettings.enabledKey, store: .standard) private var imageDataSaverEnabled = false

    init(service: TrackerService, initialKind: TrackerLibraryKind = .anime, isActive: Bool = true) {
        self.service = service
        self.isActive = isActive
        _kind = State(initialValue: initialKind)
    }

    private var loadIdentity: TrackerLibraryLoadIdentity {
        TrackerLibraryLoadIdentity(
            session: enabled ? tracker.captureLibrarySession(service: service) : nil,
            kind: kind, status: status, revision: revision, isActive: isActive
        )
    }

    private var availableGenres: [String] { Set(model.entries.flatMap(\.genres)).sorted() }
    private var filteredEntries: [TrackerLibraryEntry] { TrackerLibraryPolicy.filtered(model.entries, search: query, genre: genre) }
    private var authorized: Bool {
        enabled && isActive && !profiles.isKidsModeActive && model.session.map(tracker.librarySessionIsCurrent) == true
    }

    var body: some View {
        let identity = loadIdentity
        let displayedEntries = filteredEntries
        VStack(alignment: .leading, spacing: 16) {
            controls
            if model.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(service.displayName) \(kind.title.lowercased()) library…")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
            } else if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center).foregroundColor(.secondary)
                    Button("Retry") { revision += 1 }
                        .disabled(identity.session == nil)
                    if identity.session == nil {
                        NavigationLink("Tracker Settings", destination: TrackersSettingsView())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else if authorized {
                Text("\(displayedEntries.count) titles · \(tracker.trackerState.getAccount(for: service)?.username ?? service.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if displayedEntries.isEmpty {
                    Text(query.isEmpty && genre == nil ? "No titles in this list." : "No titles match these filters.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
                LazyVStack(spacing: 12) {
                    ForEach(displayedEntries) { entry in
                        entryRow(entry)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
        .background(navigationLink)
        .task(id: identity) {
            cancelOpening()
            navigationActive = false
            navigationResult = nil
            navigationError = nil
            editing = nil
            genre = nil
            await model.load(identity)
        }
        .onDisappear {
            cancelOpening()
            editing = nil
        }
        .sheet(item: $editing) { selection in
            TrackerLibraryEditView(entry: selection.entry, session: selection.session) { saved in
                model.accept(saved, session: selection.session)
            }
        }
        .alert("Open Title", isPresented: Binding(get: { navigationError != nil }, set: { if !$0 { navigationError = nil } })) {
            Button("OK", role: .cancel) { navigationError = nil }
        } message: { Text(navigationError ?? "") }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Media Type", selection: $kind) {
                ForEach(TrackerLibraryKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("trackerLibrary.mediaType")
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search library", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear Search") }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Picker("Status", selection: $status) {
                    Text("All Statuses").tag(TrackerLibraryStatus?.none)
                    ForEach(TrackerLibraryStatus.allCases) { status in Text(status.title(for: kind)).tag(Optional(status)) }
                }
                Picker("Genre", selection: $genre) {
                    Text("All Genres").tag(String?.none)
                    ForEach(availableGenres, id: \.self) { Text($0).tag(Optional($0)) }
                }
                Spacer(minLength: 0)
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh Tracker Library")
                    .disabled(model.isLoading)
            }
        }
    }

    private func entryRow(_ entry: TrackerLibraryEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            KFImage(entry.coverURL)
                .resizable()
                .placeholder { RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)) }
                .aspectRatio(contentMode: .fill)
                .frame(width: isTvOS ? 112 : 78, height: isTvOS ? 164 : 116)
                .clipped()
                .cornerRadius(8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.title).font(.headline).lineLimit(3)
                Text("\(entry.progress) / \(entry.total.flatMap { $0 > 0 ? String($0) : nil } ?? "?") \(entry.kind.unit)")
                    .font(.subheadline).foregroundColor(.secondary)
                HStack(spacing: 12) {
                    if let score = entry.averageScore { Label("\(Int(score.rounded()))%", systemImage: "chart.bar.fill").foregroundColor(.blue) }
                    if entry.score > 0 { Label(String(format: "%g / 10", entry.score / 10), systemImage: "star.fill").foregroundColor(.yellow) }
                }
                .font(.caption)
                if !entry.genres.isEmpty { Text(entry.genres.joined(separator: " · ")).font(.caption).foregroundColor(.secondary).lineLimit(2) }
                HStack(spacing: 16) {
                    if entry.kind == .anime {
                        Button(openingID == entry.id ? "Opening…" : "Open in Eclipse") { openAnime(entry) }
                            .disabled(openingID != nil)
                    }
#if !os(tvOS)
                    if let url = entry.websiteURL { Link("Tracker Page", destination: url) }
#endif
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
            Button {
                guard authorized, let session = model.session else { return }
                editing = TrackerLibraryEditingSelection(entry: entry, session: session)
            } label: { Image(systemName: "pencil.circle.fill").font(.title2) }
            .accessibilityLabel("Edit \(entry.title)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var navigationLink: some View {
        NavigationLink(isActive: $navigationActive) {
            if let navigationResult, authorized {
                MediaDetailView(searchResult: navigationResult)
            }
        } label: { EmptyView() }
        .hidden()
    }

    private func openAnime(_ entry: TrackerLibraryEntry) {
        guard authorized, let session = model.session else { return }
        cancelOpening()
        openingID = entry.id
        openingTask = Task { @MainActor in
            do {
                let result = try await tracker.resolveLibraryAnime(entry, session: session)
                guard !Task.isCancelled, openingID == entry.id, model.session == session,
                      tracker.librarySessionIsCurrent(session) else { return }
                navigationResult = result
                openingID = nil
                navigationActive = true
            } catch is CancellationError {
                if openingID == entry.id { openingID = nil }
            } catch {
                guard !Task.isCancelled, model.session == session, tracker.librarySessionIsCurrent(session) else { return }
                openingID = nil
                navigationError = error.localizedDescription
            }
        }
    }

    private func cancelOpening() {
        openingTask?.cancel()
        openingTask = nil
        openingID = nil
    }
}

private struct TrackerLibraryEditView: View {
    let entry: TrackerLibraryEntry
    let session: TrackerLibrarySession
    let didSave: (TrackerLibraryEntry) -> Void
    @State private var edit: TrackerLibraryEdit
    @State private var progressText: String
    @State private var saving = false
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = TrackerManager.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @AppStorage(TrackerLibrarySettings.enabledKey) private var enabled = TrackerLibrarySettings.defaultEnabled

    init(entry: TrackerLibraryEntry, session: TrackerLibrarySession, didSave: @escaping (TrackerLibraryEntry) -> Void) {
        self.entry = entry
        self.session = session
        self.didSave = didSave
        _edit = State(initialValue: TrackerLibraryEdit(entry: entry))
        _progressText = State(initialValue: String(entry.progress))
    }

    private var authorized: Bool {
        enabled && !profiles.isKidsModeActive && tracker.librarySessionIsCurrent(session)
    }

    private var changed: Bool { edit != TrackerLibraryEdit(entry: entry) || progressText != String(entry.progress) }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(entry.title).font(.headline)
                    Text("Save changes to \(entry.service.displayName).")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Section {
                    Picker("Status", selection: $edit.status) {
                        ForEach(TrackerLibraryStatus.allCases) { status in Text(status.title(for: entry.kind)).tag(status) }
                    }
                    HStack {
                        Text(entry.kind == .anime ? "Episodes Watched" : "Chapters Read")
                        Spacer(minLength: 12)
                        TextField(entry.kind == .anime ? "Episodes Watched" : "Chapters Read", text: $progressText)
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 60, maxWidth: 120)
                            .accessibilityLabel(entry.kind == .anime ? "Episodes Watched" : "Chapters Read")
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                    }
#if os(tvOS)
                    HStack {
                        Button { edit.score = max(0, edit.score - (entry.service == .myAnimeList ? 10 : 1)) } label: { Image(systemName: "minus") }
                            .accessibilityLabel("Decrease Rating")
                        Text(edit.score == 0 ? "Rating: Unrated" : String(format: "Rating: %g / 10", edit.score / 10))
                        Button { edit.score = min(100, edit.score + (entry.service == .myAnimeList ? 10 : 1)) } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Increase Rating")
                    }
#else
                    Stepper(value: $edit.score, in: 0...100, step: entry.service == .myAnimeList ? 10 : 1) {
                        Text(edit.score == 0 ? "Rating: Unrated" : String(format: "Rating: %g / 10", edit.score / 10))
                    }
#endif
                    if let total = entry.total, total > 0 {
                        Text("Total: \(total) \(entry.kind.unit)").font(.caption).foregroundColor(.secondary)
                    }
                }
                .disabled(saving || !authorized)
                if let error { Section { Text(error).foregroundColor(.red) } }
                if !authorized { Section { Text("This profile or tracker account changed. Close this editor and reload the library.").foregroundColor(.secondary) } }
            }
            .eclipseSettingsStyle()
            .navigationTitle("Edit Tracker Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { saveTask?.cancel(); dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }.disabled(saving || !authorized || !changed)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving)
        .onDisappear { saveTask?.cancel() }
    }

    private func save() {
        guard authorized, !saving else { return }
        guard let progress = Int(progressText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = TrackerLibraryError.invalidEdit.localizedDescription
            return
        }
        var candidate = edit
        candidate.progress = progress
        do { try candidate.validate(against: entry) } catch { self.error = error.localizedDescription; return }
        error = nil
        saving = true
        saveTask = Task { @MainActor in
            do {
                let saved = try await tracker.updateLibraryEntry(entry, edit: candidate, session: session)
                guard !Task.isCancelled, authorized else { saving = false; return }
                didSave(saved)
                saving = false
                dismiss()
            } catch {
                guard !Task.isCancelled else { saving = false; return }
                self.error = error is CancellationError ? "This edit is no longer authorized. Reload the library." : error.localizedDescription
                saving = false
            }
        }
    }
}
