//
//  LibraryView.swift
//  Kanzen
//
//  Created by Dawud Osman on 22/05/2025.
//
import SwiftUI
import CoreData
import Kingfisher
import UniformTypeIdentifiers

#if !os(tvOS)
struct KanzenLibraryView: View {
    @State private var trackerLibrarySource: TrackerLibrarySource = .local
    @AppStorage(TrackerLibrarySettings.enabledKey) private var deepLibraryEnabled = TrackerLibrarySettings.defaultEnabled
    @ObservedObject private var libraryManager = MangaLibraryManager.shared
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared
    @ObservedObject private var downloadManager = ReaderDownloadManager.shared
    @ObservedObject private var localBooks = ReaderLocalEPUBLibrary.shared
    @State private var showingBookImporter = false
    @State private var importingBook = false
    @State private var bookImportError: String?
    @State private var importOwner: UUID?
    @State private var importAuthority: ReaderMutationAuthority?
    @State private var importMediaAuthority: ProgressManager.ProfileMutationAuthority?
    @State private var bookImportGeneration = UUID()

    @ObservedObject private var contentFilter = ReaderContentFilter.shared
    @EnvironmentObject var moduleManager: ModuleManager
    @State private var showCreateCollection = false
    @State private var scrollOffset: CGFloat = 0
    @State private var isRefreshingSources = false
    @State private var refreshStatus: String?
    @State private var showingRenameCollection = false
    @State private var renameText = ""
    @State private var collectionToRename: MangaLibraryCollection?
    private var designMetrics: ExperimentalMediaDesignMetrics { .current }

    private var bookmarksCollection: MangaLibraryCollection? {
        libraryManager.collections.first { $0.name == "Bookmarks" }
    }

    private var userCollections: [MangaLibraryCollection] {
        libraryManager.collections.filter { $0.name != "Bookmarks" }
    }

    private func visibleItems(in collection: MangaLibraryCollection) -> [MangaLibraryItem] {
        collection.items.filter { contentFilter.allows(libraryItem: $0) }
    }

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: experimental ? designMetrics.sectionSpacing : 24) {
                    KanzenRootHeader("Library") {
                        if !ProfileManager.shared.isKidsModeActive {
                            Button {
                                bookImportGeneration = UUID()
                                importOwner = ProfileManager.shared.activeProfileID
                                importAuthority = progressManager.captureMutationAuthority()
                                importMediaAuthority = ProgressManager.shared.profileMutationAuthority(requiredOwner: importOwner)
                                showingBookImporter = true
                            } label: {
                                if importingBook { EclipseLoadingIndicator() }
                                else { Image(systemName: "square.and.arrow.down") }
                            }
                            .disabled(importingBook)
                            .accessibilityLabel("Import EPUB")
                            .accessibilityIdentifier("reader.importEPUB")
                        }
                        Button {
                            refreshLibrarySources()
                        } label: {
                            if isRefreshingSources {
                                EclipseLoadingIndicator()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(isRefreshingSources)
                        .accessibilityLabel("Refresh Sources")
                    }

                    if deepLibraryEnabled && !ProfileManager.shared.isKidsModeActive {
                        TrackerLibrarySourcePicker(selection: $trackerLibrarySource)
                    }
                    if deepLibraryEnabled && !ProfileManager.shared.isKidsModeActive, let service = trackerLibrarySource.service {
                        TrackerLibraryView(service: service, initialKind: .manga)
                            .id(service.rawValue)
                    } else {
                    if !ProfileManager.shared.isKidsModeActive, !localBooks.books.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Books").font(.title2.bold())
                            ForEach(localBooks.books) { book in
                                NavigationLink(destination: ReaderLocalEPUBBookView(book: book)) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "book.closed.fill").font(.title2).foregroundColor(.accentColor)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(book.title).font(.headline).lineLimit(2)
                                            if let author = book.author { Text(author).font(.caption).foregroundColor(.secondary) }
                                            Text("\(book.chapterTitles.count) sections").font(.caption).foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                                    }
                                    .padding(12)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        do { try localBooks.remove(book) }
                                        catch { bookImportError = error.localizedDescription }
                                    } label: { Label("Remove Book", systemImage: "trash") }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    if let refreshStatus {
                        Text(refreshStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }

                    if let bookmarks = bookmarksCollection, !visibleItems(in: bookmarks).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bookmarks")
                                .font(experimental ? .largeTitle : .title2)
                                .fontWeight(.bold)
                                .foregroundColor(experimental ? .white : .primary)
                                .padding(.horizontal, 16)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: experimental ? 16 : 12) {
                                    ForEach(visibleItems(in: bookmarks)
                                        .sorted(by: { $0.dateAdded < $1.dateAdded })) { item in
                                        NavigationLink(destination: mangaDestination(for: item)) {
                                            bookmarkCard(item)
                                        }
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                libraryManager.removeItem(from: bookmarks.id, item: item)
                                            } label: {
                                                Label("Remove", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Collections")
                                .font(experimental ? .largeTitle : .title2)
                                .fontWeight(.bold)
                                .foregroundColor(experimental ? .white : .primary)
                            Spacer()
                            Button {
                                showCreateCollection = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                            }
                        }
                        .padding(.horizontal, 16)

                        if userCollections.isEmpty {
                            EclipseEmptyState(
                                icon: "folder",
                                title: "No collections yet",
                                message: "Create a collection to organize your manga."
                            )
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: experimental ? 16 : 14) {
                                    ForEach(userCollections) { collection in
                                        NavigationLink(destination: MangaCollectionDetailView(collection: collection, libraryManager: libraryManager)) {
                                            collectionCard(collection)
                                        }
                                        .contextMenu {
                                            Button {
                                                renameText = collection.name
                                                collectionToRename = collection
                                                showingRenameCollection = true
                                            } label: {
                                                Label("Rename", systemImage: "pencil")
                                            }

                                            Button(role: .destructive) {
                                                libraryManager.deleteCollection(collection)
                                            } label: {
                                                Label("Delete Collection", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    if (bookmarksCollection.map { visibleItems(in: $0).isEmpty } ?? true) && userCollections.isEmpty && localBooks.books.isEmpty {
                        EclipseEmptyState(
                            icon: "books.vertical",
                            title: "Your library is empty",
                            message: "Bookmark manga from the Home or Search tabs to see them here."
                        )
                    }
                    }
                }
                .padding(.vertical, 8)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: -geo.frame(in: .named("kanzenLibScroll")).origin.y
                        )
                    }
                )
            }
            .coordinateSpace(name: "kanzenLibScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
            .background(GlobalGradientBackground(scrollOffset: scrollOffset).ignoresSafeArea())
            .sheet(isPresented: $showCreateCollection) {
                MangaCreateCollectionView()
                    .environmentObject(libraryManager)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .fileImporter(isPresented: $showingBookImporter, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .archive]) { result in
            guard let importOwner, let importAuthority, let importMediaAuthority,
                  ProfileManager.shared.isStillActive(importOwner), !ProfileManager.shared.isKidsModeActive,
                  progressManager.isCurrent(importAuthority),
                  ProgressManager.shared.profileMutationAuthorityIsCurrent(importMediaAuthority) else { return }
            switch result {
            case .success(let url):
                let generation = bookImportGeneration
                importingBook = true
                Task { @MainActor in
                    defer {
                        if bookImportGeneration == generation,
                           ProfileManager.shared.isStillActive(importOwner), progressManager.isCurrent(importAuthority),
                           ProgressManager.shared.profileMutationAuthorityIsCurrent(importMediaAuthority) { importingBook = false }
                    }
                    do { _ = try await localBooks.importBook(from: url) }
                    catch {
                        guard bookImportGeneration == generation,
                              ProfileManager.shared.isStillActive(importOwner), !ProfileManager.shared.isKidsModeActive,
                              progressManager.isCurrent(importAuthority),
                              ProgressManager.shared.profileMutationAuthorityIsCurrent(importMediaAuthority) else { return }
                        bookImportError = error.localizedDescription
                    }
                }
            case .failure(let error): bookImportError = error.localizedDescription
            }
        }
        .alert("EPUB Import", isPresented: Binding(get: { bookImportError != nil }, set: { if !$0 { bookImportError = nil } })) {
            Button("OK", role: .cancel) { bookImportError = nil }
        } message: { Text(bookImportError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            trackerLibrarySource = .local
            invalidateBookImport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaStateWillChangeCurrentUser)) { _ in invalidateBookImport() }
        .onChangeComp(of: progressManager.captureMutationAuthority()) { _, _ in invalidateBookImport() }
        .onChangeComp(of: deepLibraryEnabled) { _, enabled in if !enabled { trackerLibrarySource = .local } }
        .alert("Rename Collection", isPresented: $showingRenameCollection) {
            TextField("Collection Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if let collection = collectionToRename {
                    libraryManager.renameCollection(collection, name: renameText)
                }
            }
        } message: {
            Text("Enter a new name for this collection.")
        }
    }

    private func invalidateBookImport() {
        bookImportGeneration = UUID()
        importingBook = false
        showingBookImporter = false
        bookImportError = nil
        importOwner = nil
        importAuthority = nil
        importMediaAuthority = nil
    }

    @ViewBuilder
    private func bookmarkCard(_ item: MangaLibraryItem) -> some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        let tunedPosterSize = designMetrics.posterCardSize(isIPad: isIPad)
        let cardWidth = experimental ? tunedPosterSize.width : 120
        let cardHeight = experimental ? tunedPosterSize.height : 180

        VStack(alignment: .leading, spacing: experimental ? 8 : 4) {
            ReaderScopedRemoteImage(
                url: URL(string: item.coverURL ?? ""),
                readerExtensionSourceID: item.route?.readerExtensionSourceID
            ) {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
                .scaledToFill()
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
                .cornerRadius(experimental ? designMetrics.cardRadius : 16)
                .overlay(alignment: .topLeading) {
                    unreadBadge(for: item)
                }
                .overlay(alignment: .topTrailing) {
                    downloadedBadge(for: item)
                }
                .overlay(alignment: .bottomLeading) {
                    legacySourceBadge(for: item)
                }

            Text(item.title)
                .font(experimental ? .headline : .caption)
                .lineLimit(2)
                .foregroundColor(experimental ? .white : .primary)
        }
        .frame(width: cardWidth)
    }

    @ViewBuilder
    private func mangaGridCard(_ item: MangaLibraryItem) -> some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        VStack(alignment: .leading, spacing: 4) {
            ReaderScopedRemoteImage(
                url: URL(string: item.coverURL ?? ""),
                readerExtensionSourceID: item.route?.readerExtensionSourceID
            ) {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
                .scaledToFill()
                .frame(height: 180)
                .clipped()
                .cornerRadius(experimental ? designMetrics.cardRadius : 16)
                .overlay(alignment: .topLeading) {
                    unreadBadge(for: item)
                }
                .overlay(alignment: .bottomLeading) {
                    legacySourceBadge(for: item)
                }

            Text(item.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundColor(experimental ? .white : .primary)
        }
    }

    @ViewBuilder
    private func collectionCard(_ collection: MangaLibraryCollection) -> some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        let visible = visibleItems(in: collection)
        VStack(alignment: .leading, spacing: experimental ? 8 : 6) {

            let previews = Array(visible.prefix(4))
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(experimental ? Color.white.opacity(0.10) : EclipseTheme.shared.cardBackground)
                    .frame(width: 140, height: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(experimental ? 0.14 : 0), lineWidth: 1)
                    )

                if previews.isEmpty {
                    Image(systemName: "folder")
                        .font(.title)
                        .foregroundColor(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.fixed(62)), GridItem(.fixed(62))], spacing: 4) {
                        ForEach(previews) { item in
                            ReaderScopedRemoteImage(
                                url: URL(string: item.coverURL ?? ""),
                                readerExtensionSourceID: item.route?.readerExtensionSourceID
                            ) {
                                Rectangle().fill(Color.gray.opacity(0.2))
                            }
                                .scaledToFill()
                                .frame(width: 62, height: 62)
                                .clipped()
                                .cornerRadius(4)
                        }
                    }
                    .padding(4)
                }
            }
            .frame(width: 140, height: 140)

            Text(collection.name)
                .font(experimental ? .headline : .caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundColor(experimental ? .white : .primary)

            Text("\(visible.count) items")
                .font(.caption2)
                .foregroundColor(experimental ? .white.opacity(0.62) : .secondary)
        }
        .frame(width: 140)
    }

    @ViewBuilder
    private func unreadBadge(for item: MangaLibraryItem) -> some View {
        let unread = item.unreadCount(readChapters: progressManager.readChapters(for: item.aniListId), progress: progressManager.progress(for: item.aniListId))
        if unread > 0 {
            Text("\(unread)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.red)
                .clipShape(Capsule())
                .padding(4)
        }
    }

    @ViewBuilder
    private func legacySourceBadge(for item: MangaLibraryItem) -> some View {
        if KanzenAidokuLibraryStatus.usesLegacySource(item) {
            KanzenAidokuUnavailableBadge()
        }
    }

    @ViewBuilder
    private func downloadedBadge(for item: MangaLibraryItem) -> some View {
        if downloadManager.isDownloaded(route: item.route) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundColor(.white)
                .padding(5)
                .background(Color.black.opacity(0.65))
                .clipShape(Circle())
                .padding(4)
        }
    }

    private func refreshLibrarySources() {
        guard !isRefreshingSources else { return }
        isRefreshingSources = true
        refreshStatus = "Refreshing saved sources..."
        Task { @MainActor in
            let summary = await libraryManager.refreshAllSources()
            refreshStatus = summary.statusText
            isRefreshingSources = false
        }
    }

    @ViewBuilder
    private func mangaDestination(for item: MangaLibraryItem) -> some View {
        MangaLibraryDestinationView(item: item)
    }
}

struct MangaLibraryDestinationView: View {
    let item: MangaLibraryItem
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared
    @ObservedObject private var localBooks = ReaderLocalEPUBLibrary.shared

    var body: some View {
        if let book = localBooks.books.first(where: { $0.mangaID == item.aniListId }), !ProfileManager.shared.isKidsModeActive {
            ReaderLocalEPUBBookView(book: book)
        } else if let route = contentRoute {
            routeDestination(route)
        } else if item.aniListId < 0 {
            MangaModuleUnavailableView(
                title: item.title,
                message: "This saved item is missing its source route. Open it again from its source to repair the bookmark."
            )
        } else {
            let manga = AniListManga(
                id: item.aniListId,
                title: AniListManga.AniListMangaTitle(romaji: item.title, english: nil, native: nil),
                chapters: item.totalChapters,
                volumes: nil,
                status: nil,
                coverImage: item.coverURL.map { AniListManga.AniListMangaCover(large: $0, medium: nil) },
                format: item.format,
                description: nil,
                genres: nil,
                averageScore: nil,
                countryOfOrigin: nil,
                startDate: nil
            )
            MangaDetailView(manga: manga)
        }
    }

    @ViewBuilder
    private func routeDestination(_ route: MangaContentRoute) -> some View {
        switch route {
        case .legacyModule(let moduleUUIDString, let contentParams, let isNovel):
            if let moduleUUID = UUID(uuidString: moduleUUIDString),
               let module = ModuleManager.shared.getModule(moduleUUID) {
                MangaModuleContentLoaderView(
                    module: module,
                    title: item.title,
                    imageURL: item.coverURL ?? "",
                    contentParams: contentParams,
                    isNovel: isNovel
                )
            } else {
                if let downloaded = ReaderDownloadManager.shared.downloadedTitle(for: route) {
                    downloadedDestination(downloaded)
                } else {
                    MangaModuleUnavailableView(
                        title: item.title,
                        message: "The legacy source module may have been removed."
                    )
                }
            }

        case .readerExtension(let sourceID, let itemKey, let legacyStableKey):
            let source = ReaderExtensionManager.shared.installedSources.first(where: { $0.id == sourceID })
            if (source == nil || source?.enabled == false),
               let downloaded = ReaderDownloadManager.shared.downloadedTitle(for: route) {
                downloadedDestination(downloaded)
            } else {
                ReaderExtensionMangaRouteLoaderView(
                    sourceID: sourceID,
                    itemKey: itemKey,
                    legacyStableKey: legacyStableKey,
                    title: item.title,
                    coverURL: item.coverURL,
                    mangaID: item.id > 0 ? item.id : nil
                )
            }

        case .aidoku(_, _):
            if let downloaded = ReaderDownloadManager.shared.downloadedTitle(for: route) {
                downloadedDestination(downloaded)
            } else {
                KanzenAidokuLibraryUnavailableView(
                    title: item.title
                )
            }
        }
    }

    @ViewBuilder
    private func downloadedDestination(_ downloaded: ReaderDownloadedTitle) -> some View {
        if ReaderContentFilter.shared.allows(downloadedTitle: downloaded) {
            ReaderDownloadedTitleDetailView(title: downloaded)
        } else {
            MangaModuleUnavailableView(
                title: item.title,
                message: "This title is restricted for the profile you're using."
            )
        }
    }

    private var contentRoute: MangaContentRoute? {
        if let route = item.route {
            return route
        }

        if let progress = progressManager.progress(for: item.aniListId),
           let route = progress.route {
            return route
        }

        if let moduleUUIDString = item.moduleUUID,
           let contentParams = item.contentParams {
            return .legacyModule(moduleUUID: moduleUUIDString, contentParams: contentParams, isNovel: item.isNovel ?? false)
        }

        if let progress = progressManager.progress(for: item.aniListId),
           let moduleUUIDString = progress.moduleUUID,
           let contentParams = progress.contentParams {
            return .legacyModule(moduleUUID: moduleUUIDString, contentParams: contentParams, isNovel: progress.isNovel ?? false)
        }

        return nil
    }
}
#endif

#if !os(tvOS)
struct ReaderLocalEPUBBookView: View {
    let book: ReaderLocalEPUBItem
    var initialChapterTitle: String? = nil
    var opensReaderOnAppear = false
    @ObservedObject private var library = ReaderLocalEPUBLibrary.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var progress = MangaReadingProgressManager.shared
    @State private var owner = ProfileManager.shared.activeProfileID
    @State private var authority = MangaReadingProgressManager.shared.captureMutationAuthority()
    @State private var chapters: [Chapter] = []
    @State private var selectedChapter: Chapter?
    @State private var didOpenReader = false

    private var continuation: Chapter? {
        let title = initialChapterTitle ?? progress.lastReadChapter(for: book.mangaID)
        return chapters.first(where: { $0.chapterNumber == title }) ?? chapters.first
    }

    var body: some View {
        List {
            if profiles.activeProfileID == owner, !profiles.isKidsModeActive,
               MangaReadingProgressManager.shared.isCurrent(authority),
               library.books.contains(where: { $0.id == book.id }) {
                Section {
                    Text(book.title).font(.title2.bold())
                    if let author = book.author { Text(author).foregroundColor(.secondary) }
                    Button { selectedChapter = continuation } label: {
                        Label("Continue Reading", systemImage: "book.fill")
                    }
                    .disabled(chapters.isEmpty)
                }
                Section("Contents") {
                    ForEach(chapters) { chapter in
                        Button { selectedChapter = chapter } label: {
                            Text(chapter.chapterNumber).foregroundColor(.primary)
                        }
                    }
                }
            } else {
                Text("This book is unavailable in the current profile.")
            }
        }
        .navigationTitle("Book")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if chapters.isEmpty { chapters = book.chapters(profileID: owner) }
            if opensReaderOnAppear, !didOpenReader, profiles.activeProfileID == owner,
               !profiles.isKidsModeActive, MangaReadingProgressManager.shared.isCurrent(authority),
               library.books.contains(where: { $0.id == book.id }) {
                didOpenReader = true
                selectedChapter = continuation
            }
        }
        .fullScreenCover(item: $selectedChapter) { chapter in
            NovelReaderView(kanzen: KanzenEngine(), chapters: chapters, initialChapter: chapter,
                mangaId: book.mangaID, mangaTitle: book.title, mangaCoverURL: "", mangaFormat: "NOVEL",
                totalChapters: chapters.count, latestChapterNumbers: book.chapterTitles)
        }
    }
}
#endif
