#if !os(tvOS)
import SwiftUI

struct TrackerReaderDestinationView: View {
    let match: TrackerReaderMatch
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var sources = ReaderExtensionManager.shared
    @ObservedObject private var modules = ModuleManager.shared
    @State private var valid = true
    #if os(macOS)
    @ObservedObject private var readerSession = MacWindowCoordinator.shared.readerSession
    #endif

    var body: some View {
        Group {
            if valid && match.isCurrent {
                destination
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "arrow.clockwise.circle").font(.largeTitle)
                    Text("Reader source changed").font(.headline)
                    Text("Return to your library and choose this title again.")
                        .foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("Back") { dismiss() }
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: match.id) {
            while !Task.isCancelled && valid {
                guard match.isCurrent else { valid = false; return }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in
            valid = false
            readerSession.close()
        }
        .onChange(of: valid) { current in if !current { readerSession.close() } }
        .onChange(of: scenePhase) { phase in if phase != .active { readerSession.autoScroll = false } }
        .onDisappear { readerSession.close() }
        #endif
    }

    @ViewBuilder
    private var destination: some View {
        #if os(macOS)
        if readerSession.isReading {
            MacReaderView(session: readerSession)
        } else {
            MacReaderDetailView(item: match.item, seed: match.seed, session: readerSession, back: { dismiss() }, trackerReaderMatch: match)
        }
        #else
        if let sourceID = match.source.sourceID, let seed = match.seed {
            ReaderExtensionMangaDetailView(sourceID: sourceID, initialItem: seed,
                initialItemHasDetails: match.hasPreloadedDetails, trackerReaderMatch: match)
        } else if let module = match.source.module, let params = match.item.contentParams {
            MangaModuleContentLoaderView(module: module, title: match.item.title,
                imageURL: match.item.coverURL ?? "", contentParams: params,
                isNovel: match.item.isNovel ?? false, trackerReaderMatch: match)
                .environmentObject(Settings.shared)
                .environmentObject(FavouriteManager.shared)
        } else {
            MangaModuleUnavailableView(title: match.item.title, message: "This Reader source is unavailable.")
        }
        #endif
    }
}

struct TrackerReaderSearchDestinationView: View {
    let entry: TrackerLibraryEntry
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var profiles = ProfileManager.shared
    @State private var showingSources = false
    #if os(macOS)
    @ObservedObject private var readerSession = MacWindowCoordinator.shared.readerSession
    @State private var selectedItem: MangaLibraryItem?
    @State private var selectedSeed: ReaderExtensionItem?
    @State private var windowClosed = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reader Sources").font(.headline)
                Spacer()
                Button("Manage Sources") { showingSources = true }
                    .disabled(profiles.isKidsModeActive)
            }.padding()
            if profiles.isKidsModeActive {
                Text("Switch to a grown-up profile to search Reader sources.")
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                searchContent
            }
        }
        .id(profiles.activeProfileID)
        .sheet(isPresented: $showingSources) {
            #if os(macOS)
            MacReaderSourcesSettingsView().frame(minWidth: 700, minHeight: 550)
            #else
            NavigationView { ReaderExtensionsSettingsView() }
            #endif
        }
        #if os(macOS)
        .environment(\.macReaderIsActive, !windowClosed && scenePhase == .active)
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in
            windowClosed = true
            selectedItem = nil
            selectedSeed = nil
            readerSession.close()
        }
        .onChange(of: scenePhase) { phase in if phase != .active { readerSession.autoScroll = false } }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            selectedItem = nil
            selectedSeed = nil
            readerSession.close()
        }
        .onDisappear { readerSession.close() }
        #endif
    }

    @ViewBuilder
    private var searchContent: some View {
        #if os(macOS)
        if readerSession.isReading {
            MacReaderView(session: readerSession)
        } else if let selectedItem {
            MacReaderDetailView(item: selectedItem, seed: selectedSeed, session: readerSession) { self.selectedItem = nil }
        } else {
            MacReaderSearchView(open: open, initialQuery: entry.title, includeLegacyModules: true)
        }
        #else
        KanzenGlobalSearchView(initialQuery: entry.title, includeLegacyModules: true)
            .environmentObject(ModuleManager.shared)
            .environmentObject(Settings.shared)
            .environmentObject(FavouriteManager.shared)
        #endif
    }

    #if os(macOS)
    private func open(_ result: MangaHomeItem) {
        guard !profiles.isKidsModeActive, !result.isContainer, let route = result.route else { return }
        switch route {
        case .readerExtension(let source, let key, let legacy):
            selectedItem = .fromReaderExtension(sourceID: source, itemKey: key, legacyStableKey: legacy,
                title: result.title, coverURL: result.imageURL,
                sourceName: ReaderExtensionManager.shared.source(for: source)?.name,
                contentRating: result.readerExtensionItem.map { ReaderContentFilter.shared.derivedReaderExtensionRating(for: $0) })
        case .legacyModule(let module, let params, let novel):
            guard let identifier = UUID(uuidString: module) else { return }
            selectedItem = .fromModule(moduleId: identifier, contentId: params, title: result.title, coverURL: result.imageURL, isNovel: novel)
        case .aidoku: return
        }
        selectedSeed = result.readerExtensionItem
    }
    #endif
}
#endif
