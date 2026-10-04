import SwiftUI

#if !os(tvOS)
import WebKit

enum ReaderExtensionOfflineNovelHTML {
    /// Reader Extension novel downloads are persisted as inert plain text.
    /// Encode that text once before placing it in the reader's HTML body so
    /// downloaded text can never be reparsed as source-provided markup.
    static func bodyContent(for downloadedText: String, route: MangaContentRoute) -> String {
        guard case .readerExtension = route else { return downloadedText }
        return downloadedText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct NovelReaderView: View {
    let kanzen: KanzenEngine
    let chapters: [Chapter]
    let initialChapter: Chapter
    let mangaId: Int
    let mangaTitle: String
    let mangaCoverURL: String
    let mangaRoute: MangaContentRoute?
    let mangaFormat: String?
    let totalChapters: Int?
    let latestChapterNumbers: [String]?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared
    @ObservedObject private var localBooks = ReaderLocalEPUBLibrary.shared
    @ObservedObject private var profiles = ProfileManager.shared

    @State private var progressOwnerProfileID: UUID
    @State private var progressAuthority: ProgressManager.ProfileMutationAuthority?
    @State private var readerAuthority: ReaderMutationAuthority
    @State private var readerInvalidated = false
    @State private var panel: NovelReaderPanel?
    @State private var chapterQuery = ""
    @State private var findQuery = ""
    @State private var searchRequest: NovelSearchRequest?
    @State private var searchCount = 0
    @State private var searchIndex = 0
    @State private var readingMode: ReaderNovelReadingMode
    @State private var locator: ReaderNovelLocator?
    @State private var bookmarks: [ReaderNovelBookmark] = []
    @State private var pageNumber = 0
    @State private var pageCount = 0

    private var ownerSettings: UserDefaults {
        ProfileSettingsStore.shared.store(for: progressOwnerProfileID)
    }

    @State private var currentChapter: Chapter
    @State private var htmlContent: String = ""
    @State private var isLoading: Bool = true
    @State private var loadError: String?
    @State private var loadGeneration = UUID()
    @State private var loadTask: Task<Void, Never>?

    @State private var isHeaderVisible: Bool = true
    @State private var isSettingsExpanded: Bool = false
    @State private var readingProgress: Double = 0.0
    @State private var autoMarkedReadChapters: Set<String> = []
    @State private var windowSafeAreaInsets: UIEdgeInsets = .zero
    @State private var headerChromeContentHeight: CGFloat = 54
    @State private var footerChromeContentHeight: CGFloat = 104
    @State private var scrollRequest: NovelScrollRequest?

    @State private var readerReadThreshold: Double

    @State private var fontSize: CGFloat
    @State private var selectedFont: String
    @State private var fontWeight: String
    @State private var selectedColorPreset: Int
    @State private var textAlignment: String
    @State private var lineSpacing: CGFloat
    @State private var margin: CGFloat

    @State private var isAutoScrolling: Bool = false
    @State private var autoScrollSpeed: Double = 1.0

    private let fontOptions: [(String, String)] = [
        ("-apple-system", "System"),
        ("Georgia", "Georgia"),
        ("Times New Roman", "Times"),
        ("Helvetica", "Helvetica"),
        ("Charter", "Charter"),
        ("New York", "New York"),
        ("ui-rounded", "Rounded"),
        ("Menlo", "Monospace"),
        ("serif", "Serif"),
        ("sans-serif", "Sans Serif")
    ]

    private let weightOptions: [(String, String)] = [
        ("300", "Light"),
        ("normal", "Regular"),
        ("500", "Medium"),
        ("600", "Semibold"),
        ("700", "Bold (700)"),
        ("bold", "Bold")
    ]

    private let alignmentOptions: [(String, String, String)] = [
        ("left", "Left", "text.alignleft"),
        ("center", "Center", "text.aligncenter"),
        ("right", "Right", "text.alignright"),
        ("justify", "Justify", "text.justify")
    ]

    private let colorPresets: [(name: String, background: String, text: String)] = [
        (name: "Pure", background: "#ffffff", text: "#000000"),
        (name: "Warm", background: "#f9f1e4", text: "#4f321c"),
        (name: "Slate", background: "#49494d", text: "#d7d7d8"),
        (name: "Off-Black", background: "#121212", text: "#EAEAEA"),
        (name: "Dark", background: "#000000", text: "#ffffff")
    ]

    private var currentBGColor: Color {
        Color(hex: colorPresets[selectedColorPreset].background)
    }

    private var currentTextColor: Color {
        Color(hex: colorPresets[selectedColorPreset].text)
    }

    private var usesIsolatedReaderExtensionDocument: Bool {
        if currentChapter.chapterData?.first?.params is ReaderLocalEPUBChapterPayload
            || currentChapter.chapterData?.first?.params is ReaderNovelDocument { return true }
        guard let mangaRoute else { return false }
        if case .readerExtension = mangaRoute { return true }
        return false
    }

    init(kanzen: KanzenEngine, chapters: [Chapter], initialChapter: Chapter, mangaId: Int, mangaTitle: String, mangaCoverURL: String, mangaRoute: MangaContentRoute? = nil, mangaFormat: String? = nil, totalChapters: Int? = nil, latestChapterNumbers: [String]? = nil) {
        self.kanzen = kanzen
        self.chapters = chapters
        self.initialChapter = initialChapter
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.mangaCoverURL = mangaCoverURL
        self.mangaRoute = mangaRoute
        self.mangaFormat = mangaFormat
        self.totalChapters = totalChapters
        self.latestChapterNumbers = latestChapterNumbers

        _currentChapter = State(initialValue: initialChapter)

        let owner = ProfileManager.shared.activeProfileID
        _progressOwnerProfileID = State(initialValue: owner)
        _progressAuthority = State(initialValue: ProgressManager.shared.profileMutationAuthority(requiredOwner: owner))
        _readerAuthority = State(initialValue: MangaReadingProgressManager.shared.captureMutationAuthority())

        let defaults = ProfileSettingsStore.shared.store(for: owner)
        let storedThreshold = defaults.object(forKey: "readerReadThresholdPercent") as? Double ?? 80
        let readThreshold = storedThreshold.isFinite ? min(max(storedThreshold, 50), 100) : 80
        let fontSize = defaults.novelCGFloat(forKey: "readerFontSize", default: 16, range: 12...32)
        let lineSpacing = defaults.novelCGFloat(forKey: "readerLineSpacing", default: 1.6, range: 1...3)
        let margin = defaults.novelCGFloat(forKey: "readerMargin", default: 4, range: 0...30)
        defaults.set(readThreshold, forKey: "readerReadThresholdPercent")
        defaults.setNovelCGFloat(fontSize, forKey: "readerFontSize")
        defaults.setNovelCGFloat(lineSpacing, forKey: "readerLineSpacing")
        defaults.setNovelCGFloat(margin, forKey: "readerMargin")
        _readerReadThreshold = State(initialValue: readThreshold / 100)
        _fontSize = State(initialValue: fontSize)
        _selectedFont = State(initialValue: ReaderNovelPreferences.font(defaults.string(forKey: "readerFontFamily") ?? "-apple-system"))
        _fontWeight = State(initialValue: ReaderNovelPreferences.weight(defaults.string(forKey: "readerFontWeight") ?? "normal"))
        _selectedColorPreset = State(initialValue: BackupData.sanitizedReaderColorPreset(defaults.integer(forKey: "readerColorPreset")))
        _textAlignment = State(initialValue: ReaderNovelPreferences.alignment(defaults.string(forKey: "readerTextAlignment") ?? "left"))
        _lineSpacing = State(initialValue: lineSpacing)
        _margin = State(initialValue: margin)
        _readingMode = State(initialValue: ReaderNovelReadingMode(rawValue: defaults.string(forKey: ReaderNovelPreferences.modeKey) ?? "") ?? .scroll)
    }

    private var chapterPositionKey: String { positionKey(for: currentChapter) }

    private var canMutate: Bool {
        guard !readerInvalidated, let progressAuthority else { return false }
        if let payload = currentChapter.chapterData?.first?.params as? ReaderLocalEPUBChapterPayload,
           profiles.isKidsModeActive || payload.profileID != progressOwnerProfileID
            || !localBooks.books.contains(where: { $0.id == payload.bookID }) { return false }
        return ProfileManager.shared.activeProfileID == progressOwnerProfileID
            && ProgressManager.shared.profileMutationAuthorityIsCurrent(progressAuthority)
            && progressManager.isCurrent(readerAuthority)
    }

    private func positionKey(for chapter: Chapter) -> String {
        ReaderNovelChapterIdentity.positionKey(for: chapter, titleIdentity: mangaRoute?.stableKey ?? "manga-\(mangaId)")
    }

    private var bookmarksKey: String {
        "novelBookmarks_v1_" + NovelReaderPositionKey.make(titleIdentity: mangaRoute?.stableKey ?? "manga-\(mangaId)", chapterIdentity: "bookmarks")
    }

    var body: some View {
        let displayedGeneration = loadGeneration
        ZStack(alignment: .bottom) {
            currentBGColor.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: currentTextColor))
            } else if let error = loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundColor(.orange)
                    Text("Error loading chapter")
                        .font(.headline)
                        .foregroundColor(currentTextColor)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(currentTextColor.opacity(0.7))
                }
            } else {
                ZStack {

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                isHeaderVisible.toggle()
                                if !isHeaderVisible { isSettingsExpanded = false }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    NovelHTMLView(
                        htmlContent: htmlContent,
                        fontSize: fontSize,
                        fontFamily: selectedFont,
                        fontWeight: fontWeight,
                        textAlignment: textAlignment,
                        lineSpacing: lineSpacing,
                        margin: margin,
                        isAutoScrolling: $isAutoScrolling,
                        autoScrollSpeed: autoScrollSpeed,
                        colorPreset: colorPresets[selectedColorPreset],
                        chapterKey: chapterPositionKey,
                        settingsStore: ownerSettings,
                        isolatesReaderExtensionHTML: usesIsolatedReaderExtensionDocument,
                        scrollRequest: scrollRequest,
                        onProgressChanged: { progress in
                            guard canMutate, loadGeneration == displayedGeneration, !isLoading else { return }
                            self.readingProgress = progress
                            if progress >= readerReadThreshold {
                                self.markCurrentChapterReadIfNeeded()
                            }
                        },
                        readingMode: readingMode,
                        searchRequest: searchRequest,
                        mutationIsCurrent: { canMutate },
                        onPositionChanged: { value, page, pages in
                            guard canMutate, loadGeneration == displayedGeneration else { return }
                            if progressManager.lastReadChapter(for: mangaId) != currentChapter.chapterNumber || pageNumber != page {
                                progressManager.savePagePosition(mangaId: mangaId, chapterNumber: currentChapter.chapterNumber,
                                    page: max(0, page - 1), pageCount: max(1, pages), mangaTitle: mangaTitle,
                                    coverURL: mangaCoverURL, format: mangaFormat, totalChapters: totalChapters,
                                    latestChapterNumbers: latestChapterNumbers, isNovel: true, route: mangaRoute,
                                    readThreshold: readerReadThreshold, readingCompletion: 0,
                                    forProfile: progressOwnerProfileID,
                                    preservesExactChapterTitles: ReaderNovelChapterIdentity.isBookChapter(currentChapter))
                            }
                            locator = value
                            pageNumber = page
                            pageCount = pages
                        },
                        onSearchChanged: { index, count in
                            guard canMutate, loadGeneration == displayedGeneration else { return }
                            searchIndex = index
                            searchCount = count
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal)
                    .padding(.top, headerChromeContentHeight + safeAreaTop)
                    .padding(.bottom, footerChromeContentHeight + safeAreaBottom)
                    .simultaneousGesture(TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            isHeaderVisible.toggle()
                            if !isHeaderVisible { isSettingsExpanded = false }
                        }
                    })
                }
            }

            headerView
                .opacity(isHeaderVisible ? 1 : 0)
                .offset(y: isHeaderVisible ? 0 : -100)
                .allowsHitTesting(isHeaderVisible)
                .animation(.easeInOut(duration: 0.4), value: isHeaderVisible)
                .zIndex(1)

            if isHeaderVisible {
                footerView
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
        }
        .navigationBarHidden(true)
        .navigationBarBackButtonHidden(true)
        .ignoresSafeArea()
        .onPreferenceChange(NovelReaderHeaderHeightPreferenceKey.self) { height in
            if height.isFinite, height > 0, headerChromeContentHeight != height {
                headerChromeContentHeight = height
            }
        }
        .onPreferenceChange(NovelReaderFooterHeightPreferenceKey.self) { height in
            if height.isFinite, height > 0, footerChromeContentHeight != height {
                footerChromeContentHeight = height
            }
        }
        .background {
            NovelReaderWindowMetricsReader { insets in
                if windowSafeAreaInsets != insets {
                    windowSafeAreaInsets = insets
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .onDisappear {
            loadGeneration = UUID()
            loadTask?.cancel()
            isAutoScrolling = false
        }
        .hidesAppHub()
        .sheet(item: $panel) { selected in
            NavigationView {
                Group {
                    switch selected {
                    case .contents: contentsPanel
                    case .bookmarks: bookmarksPanel
                    case .search: searchPanel
                    case .settings: settingsPanel
                    }
                }
                .navigationTitle(selected.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
                .eclipseSettingsStyle()
            }
            .preferredColorScheme(.dark)
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in invalidateReader() }
        .onReceive(NotificationCenter.default.publisher(for: .mediaStateWillChangeCurrentUser)) { _ in invalidateReader() }
        .onReceive(NotificationCenter.default.publisher(for: ServiceStoreScope.didChangeNotification)) { _ in invalidateReader() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderLocalEPUBLibrary.didRemoveBook)) { notification in
            if let payload = currentChapter.chapterData?.first?.params as? ReaderLocalEPUBChapterPayload,
               notification.userInfo?["bookID"] as? String == payload.bookID,
               notification.userInfo?["profileID"] as? UUID == progressOwnerProfileID { invalidateReader() }
        }
        .onChange(of: canMutate) { current in if !current && !readerInvalidated { invalidateReader() } }
        .onChange(of: scenePhase) { phase in if phase != .active { isAutoScrolling = false } }
        .onAppear {
            bookmarks = ReaderNovelBookmark.decode(ownerSettings.data(forKey: bookmarksKey))
            loadChapterContent()
        }
    }

    private func loadChapterContent() {
        loadTask?.cancel()
        scrollRequest = nil
        searchRequest = nil
        isAutoScrolling = false
        readingProgress = 0
        pageNumber = 0
        pageCount = 0
        let generation = UUID()
        loadGeneration = generation
        let chapterID = currentChapter.id
        let owner = progressOwnerProfileID
        guard canMutate, ProfileManager.shared.activeProfileID == owner else {
            loadError = "The profile changed. Reopen this chapter to continue."
            isLoading = false
            return
        }
        let stableKey = "novelScrollPos_\(chapterPositionKey)"
        let legacyKey = "novelScrollPos_\(currentChapter.id.uuidString)"
        if ownerSettings.object(forKey: stableKey) == nil,
           let legacy = ownerSettings.object(forKey: legacyKey) as? Double, legacy.isFinite {
            ownerSettings.set(min(max(legacy, 0), 1), forKey: stableKey)
            ownerSettings.removeObject(forKey: legacyKey)
        }
        isLoading = true
        loadError = nil
        htmlContent = ""

        ReaderLogger.shared.log("NovelReader: chapter load requested", type: "ReaderDebug")
        ReaderLogger.shared.log("NovelReader: chapterData count=\(currentChapter.chapterData?.count ?? 0)", type: "ReaderDebug")

        locator = nil
        searchCount = 0
        searchIndex = 0
        if let mangaRoute, let document = ReaderDownloadManager.shared.novelDocument(for: mangaRoute, chapterNumber: currentChapter.chapterNumber) {
            htmlContent = document.bodyHTML
            isLoading = false
            return
        }
        if let mangaRoute,
           let downloadedText = ReaderDownloadManager.shared.text(for: mangaRoute, chapterNumber: currentChapter.chapterNumber) {
            ReaderLogger.shared.log("NovelReader: loaded downloaded text", type: "ReaderDownload")
            htmlContent = ReaderExtensionOfflineNovelHTML.bodyContent(
                for: downloadedText,
                route: mangaRoute
            )
            isLoading = false
            return
        }

        guard let data = currentChapter.chapterData?.first else {
            ReaderLogger.shared.log("NovelReader: chapterData is nil or empty", type: "Error")
            loadError = "No chapter data available"
            isLoading = false
            return
        }

        ReaderLogger.shared.log("NovelReader: chapterData.params type=\(type(of: data.params as Any))", type: "ReaderDebug")
        ReaderLogger.shared.log("NovelReader: chapter metadata available", type: "ReaderDebug")

        guard let params = data.params else {
            ReaderLogger.shared.log("NovelReader: params is nil", type: "Error")
            loadError = "No chapter data available"
            isLoading = false
            return
        }

        if let document = params as? ReaderNovelDocument {
            htmlContent = document.bodyHTML
            isLoading = false
            return
        }

        if let payload = params as? ReaderLocalEPUBChapterPayload {
            loadTask = Task { @MainActor in
                do {
                    let document = try await ReaderLocalEPUBLibrary.shared.document(for: payload)
                    guard !Task.isCancelled, loadGeneration == generation, currentChapter.id == chapterID,
                          canMutate, ProfileManager.shared.isStillActive(owner) else { return }
                    htmlContent = document.bodyHTML
                    isLoading = false
                } catch {
                    guard !Task.isCancelled, loadGeneration == generation, currentChapter.id == chapterID, canMutate else { return }
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
            return
        }

        if params is ReaderDownloadedChapterPayload {
            ReaderLogger.shared.log("NovelReader: downloaded text files missing", type: "ReaderDownload")
            loadError = "Downloaded chapter files are missing."
            isLoading = false
            return
        }

        if let payload = params as? ReaderExtensionChapterPayload {
            loadTask = Task { @MainActor in
                do {
                    let provider = try ReaderExtensionManager.shared.provider(for: payload.sourceID)
                    let sanitizedHTML = try await provider.chapterHTML(
                        chapterKey: payload.chapter.key,
                        chapterTitle: payload.chapter.title
                    )
                    guard !Task.isCancelled, loadGeneration == generation, currentChapter.id == chapterID,
                          canMutate, ProfileManager.shared.isStillActive(owner) else { return }
                    htmlContent = sanitizedHTML
                    isLoading = false
                    ReaderLogger.shared.log(
                        "NovelReader: Reader Extension chapter loaded length=\(sanitizedHTML.count)",
                        type: "ReaderExtensions"
                    )
                } catch {
                    guard !Task.isCancelled, loadGeneration == generation, currentChapter.id == chapterID,
                          canMutate, ProfileManager.shared.isStillActive(owner) else { return }
                    if case ReaderExtensionError.domainConsentRequired(let host) = error {
                        loadError = "This source needs permission to contact \(host). Review its missing domain approvals in Reader Sources."
                    } else {
                        loadError = error.localizedDescription
                    }
                    isLoading = false
                    ReaderLogger.shared.log(
                        "NovelReader: Reader Extension chapter failed: \(error.localizedDescription)",
                        type: "ReaderExtensions"
                    )
                }
            }
            return
        }

        ReaderLogger.shared.log("NovelReader: calling extractText", type: "ReaderDebug")
        kanzen.extractText(params: params) { result in
            DispatchQueue.main.async {
                guard self.loadGeneration == generation, self.currentChapter.id == chapterID,
                      self.canMutate, ProfileManager.shared.isStillActive(owner) else { return }
                if let content = result, !content.isEmpty, content != "undefined", content.count > 20 {
                    ReaderLogger.shared.log("NovelReader: extractText success, length=\(content.count)", type: "ReaderDebug")
                    self.htmlContent = content
                    self.isLoading = false
                } else {
                    ReaderLogger.shared.log("NovelReader: extractText failed or returned empty", type: "Error")
                    self.loadError = "Failed to extract text content"
                    self.isLoading = false
                }
            }
        }
    }

    private func goToNextChapter() {
        guard canMutate, let idx = chapters.firstIndex(where: { $0.id == currentChapter.id }),
              idx + 1 < chapters.count else { return }
        markCurrentChapterRead()
        currentChapter = chapters[idx + 1]
        readingProgress = 0
        loadChapterContent()
    }

    private func goToPreviousChapter() {
        guard canMutate, let idx = chapters.firstIndex(where: { $0.id == currentChapter.id }),
              idx > 0 else { return }
        currentChapter = chapters[idx - 1]
        readingProgress = 0
        loadChapterContent()
    }

    private func markCurrentChapterRead() {
        guard canMutate else { return }
        progressManager.markChapterRead(
            mangaId: mangaId,
            chapterNumber: currentChapter.chapterNumber,
            mangaTitle: mangaTitle,
            coverURL: mangaCoverURL,
            format: mangaFormat,
            totalChapters: totalChapters,
            latestChapterNumbers: latestChapterNumbers,
            route: mangaRoute,
            forProfile: progressOwnerProfileID,
            preservesExactChapterTitles: ReaderNovelChapterIdentity.isBookChapter(currentChapter)
        )
    }

    private func markCurrentChapterReadIfNeeded() {
        guard !autoMarkedReadChapters.contains(currentChapter.chapterNumber) else { return }
        autoMarkedReadChapters.insert(currentChapter.chapterNumber)
        markCurrentChapterRead()
    }

    private var headerView: some View {
        VStack {
            HStack {
                Button {
                    if readingProgress >= readerReadThreshold { markCurrentChapterReadIfNeeded() }
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(currentTextColor)
                        .padding(12)
                        .background(currentBGColor.opacity(0.8))
                        .clipShape(Circle())
                        .frame(width: 44, height: 44)
                }
                .padding(.leading)
                .accessibilityLabel("Close Reader")
                .accessibilityIdentifier("novel.close")

                Button { isAutoScrolling = false; panel = .contents } label: {
                    Text(currentChapter.chapterNumber).font(.headline).lineLimit(1)
                }
                    .accessibilityLabel("Chapters")
                    .accessibilityIdentifier("novel.chapters")
                    .accessibilityValue(currentChapter.chapterNumber)
                    .font(.headline)
                    .foregroundColor(currentTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button { goToPreviousChapter() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(currentTextColor)
                        .padding(12)
                        .background(currentBGColor.opacity(0.8))
                        .clipShape(Circle())
                        .frame(width: 44, height: 44)
                }
                .disabled(chapters.firstIndex(where: { $0.id == currentChapter.id }) == 0)
                .accessibilityLabel("Previous Chapter")
                .accessibilityIdentifier("novel.previousChapter")

                Button { goToNextChapter() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(currentTextColor)
                        .padding(12)
                        .background(currentBGColor.opacity(0.8))
                        .clipShape(Circle())
                        .frame(width: 44, height: 44)
                }
                .disabled({
                    guard let idx = chapters.firstIndex(where: { $0.id == currentChapter.id }) else { return true }
                    return idx + 1 >= chapters.count
                }())
                .accessibilityLabel("Next Chapter")
                .accessibilityIdentifier("novel.nextChapter")

                Button {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        isAutoScrolling = false
                        panel = .settings
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(currentTextColor)
                        .padding(12)
                        .background(currentBGColor.opacity(0.8))
                        .clipShape(Circle())
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(isSettingsExpanded ? 90 : 0))
                }
                .padding(.trailing)
                .accessibilityLabel("Reader Settings")
                .accessibilityIdentifier("novel.settings")
            }
            .padding(.top, safeAreaTop)
            .padding(.bottom, 10)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: NovelReaderHeaderHeightPreferenceKey.self, value: geometry.size.height - safeAreaTop)
                }
            }
            .background(.ultraThinMaterial)


            Spacer()
        }
        .ignoresSafeArea()
    }

    private var footerView: some View {
        VStack {
            Spacer()

            VStack(spacing: 0) {

                HStack(spacing: 24) {
                    Button { isAutoScrolling = false; panel = .contents } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Chapters").accessibilityIdentifier("novel.contents")
                    Menu {
                        Button("Save Bookmark", action: saveBookmark)
                        Button("Show Bookmarks") { isAutoScrolling = false; panel = .bookmarks }
                    } label: { Image(systemName: "bookmark") }
                        .accessibilityLabel("Bookmarks").accessibilityIdentifier("novel.bookmarks")
                    Button { isAutoScrolling = false; panel = .search } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Find in Chapter").accessibilityIdentifier("novel.search")
                    Spacer()
                    if readingMode == .paged {
                        Button { scrollRequest = NovelScrollRequest(percentage: 0, pageDirection: -1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Previous Page").accessibilityIdentifier("novel.previousPage")
                        Text("\(pageNumber) / \(pageCount)").font(.caption).monospacedDigit()
                        Button { scrollRequest = NovelScrollRequest(percentage: 0, pageDirection: 1) } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel("Next Page").accessibilityIdentifier("novel.nextPage")
                    }
                    Button {
                        guard canMutate else { return }
                        isAutoScrolling.toggle()
                    } label: {
                        Image(systemName: isAutoScrolling ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(isAutoScrolling ? .red : currentTextColor)
                            .padding(12)
                            .background(currentBGColor.opacity(0.8))
                            .clipShape(Circle())
                    }
                }
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(currentTextColor)
                .disabled(!canMutate || isLoading)
                .padding(.horizontal, 20)
                .padding(.top, 12)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(currentTextColor.opacity(0.2))
                            .frame(height: 4)

                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: max(0, min(CGFloat(readingProgress) * geo.size.width, geo.size.width)), height: 4)

                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                            .offset(x: max(0, min(CGFloat(readingProgress) * geo.size.width, geo.size.width)) - 8)
                    }
                    .cornerRadius(2)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let pct = min(max(value.location.x / geo.size.width, 0), 1)
                                scrollToPosition(pct)
                            }
                    )
                }
                .frame(height: 24)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, safeAreaBottom + 16)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: NovelReaderFooterHeightPreferenceKey.self, value: geometry.size.height - safeAreaBottom)
                }
            }
            .background(.ultraThinMaterial)
            .opacity(isHeaderVisible ? 1 : 0)
            .offset(y: isHeaderVisible ? 0 : 100)
            .animation(.easeInOut(duration: 0.4), value: isHeaderVisible)
        }
        .ignoresSafeArea()
    }

    private var settingsPanel: some View {
        Form {
            Section("Reading") {
                Picker("Navigation", selection: Binding(get: { readingMode }, set: { value in
                    guard canMutate else { return }
                    readingMode = value
                    ownerSettings.set(value.rawValue, forKey: ReaderNovelPreferences.modeKey)
                })) { ForEach(ReaderNovelReadingMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                .accessibilityIdentifier("novel.navigation")
                Slider(value: $autoScrollSpeed, in: 0.5...5, step: 0.5) { Text("Auto-scroll Speed") }
                Text("Auto-scroll speed: \(String(format: "%.1f", autoScrollSpeed))").font(.caption)
            }
            Section("Typography") {
                Picker("Font", selection: setting($selectedFont, key: "readerFontFamily")) {
                    ForEach(fontOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .accessibilityIdentifier("novel.font")
                Text("Font Size: \(Int(fontSize))")
                Slider(value: numberSetting($fontSize, key: "readerFontSize"), in: 12...32, step: 1)
                    .accessibilityLabel("Font Size").accessibilityIdentifier("novel.fontSize")
                Picker("Weight", selection: setting($fontWeight, key: "readerFontWeight")) {
                    ForEach(weightOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Alignment", selection: setting($textAlignment, key: "readerTextAlignment")) {
                    ForEach(alignmentOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Text("Line Spacing: \(String(format: "%.1f", lineSpacing))")
                Slider(value: numberSetting($lineSpacing, key: "readerLineSpacing"), in: 1...3, step: 0.1)
                Text("Margin: \(Int(margin))")
                Slider(value: numberSetting($margin, key: "readerMargin"), in: 0...30, step: 1)
            }
            Section("Appearance") {
                Picker("Theme", selection: setting($selectedColorPreset, key: "readerColorPreset")) {
                    ForEach(colorPresets.indices, id: \.self) { Text(colorPresets[$0].name).tag($0) }
                }
            }
            Section("Progress") {
                Text("Mark chapter read at \(Int(readerReadThreshold * 100))%")
                Slider(value: Binding(get: { readerReadThreshold }, set: { value in
                    guard canMutate else { return }
                    readerReadThreshold = value
                    ownerSettings.set(value * 100, forKey: "readerReadThresholdPercent")
                }), in: 0.5...1, step: 0.05)
            }
        }
        .disabled(!canMutate)
        .eclipseExperimentalSettingsRows()
    }

    private func setting<T>(_ binding: Binding<T>, key: String) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { value in
            guard canMutate else { return }
            binding.wrappedValue = value
            ownerSettings.set(value, forKey: key)
        })
    }

    private func numberSetting(_ binding: Binding<CGFloat>, key: String) -> Binding<CGFloat> {
        Binding(get: { binding.wrappedValue }, set: { value in
            guard canMutate, value.isFinite else { return }
            binding.wrappedValue = value
            ownerSettings.setNovelCGFloat(value, forKey: key)
        })
    }

    private var contentsPanel: some View {
        List {
            TextField("Filter chapters", text: $chapterQuery)
            ForEach(chapters.filter { chapterQuery.isEmpty || $0.chapterNumber.localizedCaseInsensitiveContains(chapterQuery) }) { chapter in
                Button {
                    guard canMutate else { return }
                    currentChapter = chapter
                    panel = nil
                    isAutoScrolling = false
                    loadChapterContent()
                } label: {
                    HStack {
                        Text(chapter.chapterNumber)
                        Spacer()
                        if chapter.id == currentChapter.id { Image(systemName: "checkmark") }
                    }
                }.buttonStyle(.borderless)
            }
        }.accessibilityIdentifier("novel.chapterList")
    }

    private var bookmarksPanel: some View {
        List {
            Section { Button("Save Current Position", action: saveBookmark) }
            Section {
                ForEach(bookmarks) { bookmark in
                    Button {
                        guard canMutate, let chapter = chapters.first(where: { positionKey(for: $0) == bookmark.chapterKey }) else { return }
                        panel = nil
                        isAutoScrolling = false
                        let request = NovelScrollRequest(percentage: CGFloat(bookmark.locator.fraction), locator: bookmark.locator)
                        if chapter.id != currentChapter.id { currentChapter = chapter; loadChapterContent() }
                        scrollRequest = request
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bookmark.chapterTitle)
                            Text(bookmark.locator.quote.isEmpty ? "Saved position" : bookmark.locator.quote).font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }.buttonStyle(.borderless)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete") {
                            guard canMutate else { return }
                            bookmarks.removeAll { $0.id == bookmark.id }
                            persistBookmarks()
                        }.tint(.red)
                    }
                }
            } footer: {
                if bookmarks.isEmpty { Text("No bookmarks yet").foregroundColor(.secondary) }
            }
        }
    }

    private var searchPanel: some View {
        Form {
            TextField("Find text in this chapter", text: $findQuery)
                .autocapitalization(.none).disableAutocorrection(true)
                .accessibilityIdentifier("novel.findQuery")
                .onChange(of: findQuery) { value in
                    searchRequest = NovelSearchRequest(query: String(value.prefix(256)), direction: 1)
                }
            Text(findQuery.isEmpty ? "Enter a word or phrase." : searchCount == 0 ? "No matches" : "\(searchIndex) of \(searchCount) matches")
            HStack {
                Button("Previous") { searchRequest = NovelSearchRequest(query: String(findQuery.prefix(256)), direction: -1) }
                Spacer()
                Button("Next") { searchRequest = NovelSearchRequest(query: String(findQuery.prefix(256)), direction: 1) }
            }.disabled(searchCount == 0)
        }
    }

    private func saveBookmark() {
        guard canMutate, let locator, locator.isValid, bookmarks.count < ReaderNovelBookmark.maximumCount else { return }
        let value = ReaderNovelBookmark(id: UUID(), chapterKey: chapterPositionKey, chapterTitle: String(currentChapter.chapterNumber.prefix(256)), locator: locator)
        if bookmarks.contains(where: { $0.chapterKey == value.chapterKey && $0.locator.textIndex == locator.textIndex && $0.locator.offset == locator.offset }) { return }
        bookmarks.append(value)
        persistBookmarks()
    }

    private func persistBookmarks() {
        guard canMutate, let data = try? JSONEncoder().encode(bookmarks), data.count <= 512 * 1_024 else { return }
        ownerSettings.set(data, forKey: bookmarksKey)
    }

    private func invalidateReader() {
        readerInvalidated = true
        loadGeneration = UUID()
        loadTask?.cancel()
        isAutoScrolling = false
        panel = nil
        isLoading = false
        htmlContent = ""
        loadError = "The profile or Reader source changed. Reopen this chapter to continue."
    }

    private var fontMenuSymbolName: String {
        if #available(iOS 18.0, *) {
            return "textformat.characters"
        }
        return "textformat"
    }

    private var lineSpacingMenuSymbolName: String {
        if #available(iOS 16.0, *) {
            return "arrow.left.and.right.text.vertical"
        }
        return "arrow.up.and.down"
    }

    private func settingsIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(currentTextColor)
            .padding(10)
            .background(currentBGColor.opacity(0.8))
            .clipShape(Circle())
    }

    private func scrollToPosition(_ percentage: CGFloat) {
        guard canMutate, percentage.isFinite else { return }
        let clamped = min(max(percentage, 0), 1)
        readingProgress = Double(clamped)
        scrollRequest = NovelScrollRequest(percentage: clamped)
    }

    private var safeAreaTop: CGFloat {
        windowSafeAreaInsets.top
    }

    private var safeAreaBottom: CGFloat {
        windowSafeAreaInsets.bottom
    }
}

private struct NovelReaderHeaderHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct NovelReaderFooterHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum NovelReaderPanel: String, Identifiable {
    case contents, bookmarks, search, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .contents: return "Chapters"
        case .bookmarks: return "Bookmarks"
        case .search: return "Find in Chapter"
        case .settings: return "Reader Settings"
        }
    }
}

private struct NovelReaderWindowMetricsReader: UIViewRepresentable {
    let onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> NovelReaderWindowMetricsProbeView {
        NovelReaderWindowMetricsProbeView(onChange: onChange)
    }

    func updateUIView(_ uiView: NovelReaderWindowMetricsProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.reportInsetsIfNeeded()
    }
}

private final class NovelReaderWindowMetricsProbeView: UIView {
    var onChange: (UIEdgeInsets) -> Void
    private var lastReportedInsets: UIEdgeInsets?

    init(onChange: @escaping (UIEdgeInsets) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportInsetsIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportInsetsIfNeeded()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportInsetsIfNeeded()
    }

    func reportInsetsIfNeeded() {
        let insets = window?.safeAreaInsets ?? .zero
        guard insets != lastReportedInsets else { return }
        lastReportedInsets = insets
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastReportedInsets == insets else { return }
            self.onChange(insets)
        }
    }
}

struct NovelScrollRequest: Equatable {
    let id = UUID()
    let percentage: CGFloat
    var locator: ReaderNovelLocator? = nil
    var pageDirection: Int = 0
}

struct NovelSearchRequest: Equatable {
    let id = UUID()
    let query: String
    let direction: Int
}

struct NovelHTMLView: UIViewRepresentable {
    let htmlContent: String
    let fontSize: CGFloat
    let fontFamily: String
    let fontWeight: String
    let textAlignment: String
    let lineSpacing: CGFloat
    let margin: CGFloat
    @Binding var isAutoScrolling: Bool
    let autoScrollSpeed: Double
    let colorPreset: (name: String, background: String, text: String)
    let chapterKey: String

    let settingsStore: UserDefaults
    let isolatesReaderExtensionHTML: Bool
    let scrollRequest: NovelScrollRequest?
    var onProgressChanged: ((Double) -> Void)?
    var readingMode: ReaderNovelReadingMode = .scroll
    var searchRequest: NovelSearchRequest? = nil
    var mutationIsCurrent: (() -> Bool)? = nil
    var onPositionChanged: ((ReaderNovelLocator, Int, Int) -> Void)? = nil
    var onSearchChanged: ((Int, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private static let readerBridgeWorld = WKContentWorld.world(name: "app.eclipse.reader-extension-progress")
        var parent: NovelHTMLView
        var scrollTimer: Timer?
        var progressTimer: Timer?
        weak var webView: WKWebView?
        private(set) var isDismantled = false
        var documentGeneration = UUID()
        var layoutGeneration = UUID()
        var expectedNavigation: WKNavigation?
        var navigationGeneration: UUID?
        private(set) var isDocumentReady = false
        private var progressUsesIsolatedWorld: Bool?
        var scriptEvaluator: ((String, WKWebView, ((Any?, Error?) -> Void)?) -> Void)?

        var lastHTML: String = ""
        var lastFontSize: CGFloat = 0
        var lastFontFamily: String = ""
        var lastFontWeight: String = ""
        var lastAlignment: String = ""
        var lastLineSpacing: CGFloat = 0
        var lastMargin: CGFloat = 0
        var lastPreset: String = ""
        var lastChapterKey: String = ""
        var lastSettingsStore: UserDefaults?
        var lastIsolatesReaderExtensionHTML = false
        var lastScrollRequestID: UUID?
        var lastSearchRequestID: UUID?
        var lastReadingMode: ReaderNovelReadingMode = .scroll
        var lastAutoScrollSpeed: Double = 1
        var styleRequestPending = false
        var autoScrollRequestPending = false

        private var mayMutate: Bool { parent.mutationIsCurrent?() ?? true }
        private var locatorKey: String { "novelLocator_v1_" + parent.chapterKey }

        init(_ parent: NovelHTMLView) {
            self.parent = parent
        }

        func documentHasChanged(_ view: NovelHTMLView) -> Bool {
            lastHTML != view.htmlContent || lastChapterKey != view.chapterKey
                || lastSettingsStore !== view.settingsStore || lastIsolatesReaderExtensionHTML != view.isolatesReaderExtensionHTML
        }

        func settingsHaveChanged(_ view: NovelHTMLView) -> Bool {
            lastFontSize != view.fontSize || lastFontFamily != view.fontFamily || lastFontWeight != view.fontWeight
                || lastAlignment != view.textAlignment || lastLineSpacing != view.lineSpacing
                || lastMargin != view.margin || lastPreset != view.colorPreset.name || lastReadingMode != view.readingMode
        }

        func recordDocument(_ view: NovelHTMLView) {
            lastHTML = view.htmlContent
            lastFontSize = view.fontSize
            lastFontFamily = view.fontFamily
            lastFontWeight = view.fontWeight
            lastAlignment = view.textAlignment
            lastLineSpacing = view.lineSpacing
            lastMargin = view.margin
            lastPreset = view.colorPreset.name
            lastChapterKey = view.chapterKey
            lastSettingsStore = view.settingsStore
            lastIsolatesReaderExtensionHTML = view.isolatesReaderExtensionHTML
            lastReadingMode = view.readingMode
            lastAutoScrollSpeed = view.autoScrollSpeed
        }

        func applyScrollRequest(_ webView: WKWebView) {
            guard mayMutate, let request = parent.scrollRequest, request.id != lastScrollRequestID else { return }
            lastScrollRequestID = request.id
            let script: String
            if let locator = request.locator, locator.isValid {
                script = "window.__eclipseNovelReader?.restore(\(ReaderNovelScripts.literal(locator)));"
            } else if request.pageDirection != 0 {
                script = "window.__eclipseNovelReader?.page(\(request.pageDirection > 0 ? 1 : -1));"
            } else {
                script = "window.__eclipseNovelReader?.seek(\(ReaderNovelPreferences.fraction(Double(request.percentage))));"
            }
            evaluateReaderScript(script, in: webView)
            updateProgress(webView)
        }

        func applySearchRequest(_ webView: WKWebView) {
            guard mayMutate, let request = parent.searchRequest, request.id != lastSearchRequestID else { return }
            lastSearchRequestID = request.id
            let generation = documentGeneration
            evaluateReaderScript("window.__eclipseNovelReader?.find(\(ReaderNovelScripts.literal(String(request.query.prefix(256)))), \(request.direction < 0 ? -1 : 1));", in: webView) { [weak self] result, _ in
                guard let self, !self.isDismantled, self.mayMutate, self.documentGeneration == generation,
                      self.lastSearchRequestID == request.id, let result = result as? [String: Any] else { return }
                self.parent.onSearchChanged?(result["index"] as? Int ?? 0, result["count"] as? Int ?? 0)
            }
        }

        func restorePosition(_ webView: WKWebView) {
            if let locator = ReaderNovelLocator.decode(parent.settingsStore.data(forKey: locatorKey)) {
                evaluateReaderScript("window.__eclipseNovelReader?.restore(\(ReaderNovelScripts.literal(locator)));", in: webView)
            } else {
                let saved = ReaderNovelPreferences.fraction(parent.settingsStore.double(forKey: "novelScrollPos_\(parent.chapterKey)"))
                if saved > 0 {
                    let script = parent.readingMode == .paged ? "window.__eclipseNovelReader?.seek(\(saved));" : "window.scrollTo(0, document.documentElement.scrollHeight * \(saved));"
                    evaluateReaderScript(script, in: webView)
                }
            }
        }

        func applyStyle(_ webView: WKWebView, completion: (() -> Void)? = nil) {
            guard mayMutate, !styleRequestPending else { return }
            stopAutoScroll()
            autoScrollRequestPending = false
            styleRequestPending = true
            layoutGeneration = UUID()
            let generation = documentGeneration
            let script = """
            const r=window.__eclipseNovelReader,l=r?.locate(),revision=r?.version();
            document.getElementById('eclipse-reader-style').textContent=\(ReaderNovelScripts.literal(parent.documentCSS));
            document.documentElement.dataset.readerMode=\(ReaderNovelScripts.literal(parent.readingMode.rawValue));
            await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
            if(l&&r.version()===revision)r.restore(l);
            await new Promise(resolve=>requestAnimationFrame(resolve));
            """
            evaluateReaderAsyncScript(script, in: webView) { [weak self] _, _ in
                guard let self, !self.isDismantled, self.documentGeneration == generation else { return }
                self.styleRequestPending = false
                if self.settingsHaveChanged(self.parent) { self.applyStyle(webView, completion: completion) }
                else {
                    completion?()
                    self.updateProgress(webView)
                    if self.parent.isAutoScrolling { self.startAutoScroll(webView) }
                }
            }
            recordDocument(parent)
            webView.scrollView.isPagingEnabled = parent.readingMode == .paged
            webView.scrollView.isDirectionalLockEnabled = true
        }

        func beginDocumentReplacement() {
            documentGeneration = UUID()
            expectedNavigation = nil
            navigationGeneration = nil
            isDocumentReady = false
            stopAutoScroll()
            stopProgressTracking()
            styleRequestPending = false
            autoScrollRequestPending = false
            lastScrollRequestID = nil
            lastSearchRequestID = nil
            webView?.stopLoading()
        }

        func registerNavigation(_ navigation: WKNavigation?) {
            expectedNavigation = navigation
            navigationGeneration = documentGeneration
        }

        func evaluateReaderScript(
            _ script: String,
            in webView: WKWebView,
            completion: ((Any?, Error?) -> Void)? = nil
        ) {
            guard !isDismantled, self.webView === webView else { return }
            if let scriptEvaluator {
                scriptEvaluator(script, webView, completion)
                return
            }
            if parent.isolatesReaderExtensionHTML {
                webView.evaluateJavaScript(
                    script,
                    in: nil,
                    in: Self.readerBridgeWorld
                ) { result in
                    switch result {
                    case .success(let value): completion?(value, nil)
                    case .failure(let error): completion?(nil, error)
                    }
                }
            } else {
                webView.evaluateJavaScript(script, completionHandler: completion)
            }
        }

        func evaluateReaderAsyncScript(_ script: String, in webView: WKWebView, completion: @escaping (Any?, Error?) -> Void) {
            guard !isDismantled, self.webView === webView else { return }
            if let scriptEvaluator { scriptEvaluator(script, webView, completion); return }
            webView.callAsyncJavaScript(script, arguments: [:], in: nil,
                in: parent.isolatesReaderExtensionHTML ? Self.readerBridgeWorld : .page) { result in
                switch result {
                case .success(let value): completion(value, nil)
                case .failure(let error): completion(nil, error)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !isDismantled, self.webView === webView,
                  let navigation, navigation === expectedNavigation,
                  navigationGeneration == documentGeneration else { return }
            let generation = documentGeneration
            evaluateReaderScript(ReaderNovelScripts.install, in: webView) { [weak self] _, _ in
                guard let self, !self.isDismantled, self.documentGeneration == generation else { return }
                let finish = { [weak self] in
                    guard let self, !self.isDismantled, self.documentGeneration == generation else { return }
                    self.isDocumentReady = true
                    self.restorePosition(webView)
                    self.applyScrollRequest(webView)
                    self.applySearchRequest(webView)
                    self.startProgressTracking(webView: webView)
                    if self.parent.isAutoScrolling { self.startAutoScroll(webView) }
                }
                if self.settingsHaveChanged(self.parent) { self.applyStyle(webView, completion: finish) }
                else { finish() }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "novelScrollHandler", let wv = self.webView {
                updateProgress(wv)
            }
        }

        func startAutoScroll(_ webView: WKWebView) {
            guard !isDismantled, mayMutate, !styleRequestPending, self.webView === webView, scrollTimer == nil else { return }
            let paged = parent.readingMode == .paged
            let interval = paged ? max(0.4, 3 / parent.autoScrollSpeed) : 0.016
            scrollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self, weak webView] timer in
                guard let self, let webView, !self.isDismantled, self.mayMutate, self.webView === webView else { timer.invalidate(); return }
                guard !self.autoScrollRequestPending else { return }
                self.autoScrollRequestPending = true
                let generation = self.documentGeneration
                let layout = self.layoutGeneration
                let script = self.parent.readingMode == .paged ? "window.__eclipseNovelReader?.page(1);" : "window.scrollBy(0, \(self.parent.autoScrollSpeed * 0.5));"
                self.evaluateReaderScript(script, in: webView)
                self.evaluateReaderScript("window.__eclipseNovelReader?.report().progress >= 1;", in: webView) { [weak self] result, _ in
                    guard let self, !self.isDismantled, self.mayMutate, !self.styleRequestPending,
                          self.documentGeneration == generation, self.layoutGeneration == layout else { return }
                    self.autoScrollRequestPending = false
                    if result as? Bool == true { self.stopAutoScroll(); self.parent.isAutoScrolling = false }
                }
            }
        }

        func stopAutoScroll() {
            scrollTimer?.invalidate()
            scrollTimer = nil
        }

        func tearDown() {
            guard !isDismantled else { return }
            isDismantled = true
            beginDocumentReplacement()
            webView?.navigationDelegate = nil
            webView?.stopLoading()
            webView = nil
            scriptEvaluator = nil
        }

        func startProgressTracking(webView: WKWebView) {
            guard !isDismantled, mayMutate, self.webView === webView, progressTimer == nil else { return }
            evaluateReaderScript(ReaderNovelScripts.install, in: webView)
            updateProgress(webView)
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak webView] _ in
                guard let self, let webView, self.mayMutate, webView.window != nil else { self?.stopProgressTracking(); return }
                self.updateProgress(webView)
            }
        }

        func stopProgressTracking() {
            progressTimer?.invalidate()
            progressTimer = nil
            if let wv = webView {
                wv.configuration.userContentController.removeAllUserScripts()
                if progressUsesIsolatedWorld == true {
                    wv.configuration.userContentController.removeScriptMessageHandler(
                        forName: "novelScrollHandler",
                        contentWorld: Self.readerBridgeWorld
                    )
                } else if progressUsesIsolatedWorld == false {
                    wv.configuration.userContentController.removeScriptMessageHandler(forName: "novelScrollHandler")
                }
            }
            progressUsesIsolatedWorld = nil
        }

        func updateProgress(_ webView: WKWebView) {
            guard !isDismantled, mayMutate, !styleRequestPending, self.webView === webView, webView.window != nil else { return }
            let generation = documentGeneration
            let layout = layoutGeneration
            evaluateReaderScript("window.__eclipseNovelReader?.report();", in: webView) { [weak self] result, _ in
                guard let self, !self.isDismantled, self.mayMutate, !self.styleRequestPending,
                      self.documentGeneration == generation, self.layoutGeneration == layout,
                      let dict = result as? [String: Any], let progress = dict["progress"] as? Double, progress.isFinite else { return }
                if let raw = dict["locator"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: raw),
                   let locator = ReaderNovelLocator.decode(data), let encoded = try? JSONEncoder().encode(locator) {
                    if self.parent.settingsStore.data(forKey: self.locatorKey) != encoded { self.parent.settingsStore.set(encoded, forKey: self.locatorKey) }
                    self.parent.onPositionChanged?(locator, dict["page"] as? Int ?? 0, dict["pages"] as? Int ?? 0)
                }
                if let scrollPos = dict["scrollPos"] as? Double, scrollPos.isFinite {
                    self.parent.settingsStore.set(ReaderNovelPreferences.fraction(scrollPos), forKey: "novelScrollPos_\(self.parent.chapterKey)")
                }
                self.parent.onProgressChanged?(ReaderNovelPreferences.fraction(progress))
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard parent.isolatesReaderExtensionHTML else {
                decisionHandler(.allow)
                return
            }
            let url = navigationAction.request.url
            if navigationAction.navigationType == .linkActivated, let url, url.scheme == "about", let fragment = url.fragment, !fragment.isEmpty {
                evaluateReaderScript("window.__eclipseNovelReader?.fragment(\(ReaderNovelScripts.literal(fragment.removingPercentEncoding ?? fragment)));", in: webView)
                decisionHandler(.cancel)
                return
            }
            let isInitialDocument = navigationAction.navigationType == .other
                && (url == nil || url?.scheme?.lowercased() == "about")
            decisionHandler(isInitialDocument ? .allow : .cancel)
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let wv: WKWebView
        if isolatesReaderExtensionHTML {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            wv = WKWebView(frame: .zero, configuration: configuration)
        } else {
            wv = WKWebView()
        }
        wv.backgroundColor = .clear
        wv.isOpaque = false
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.showsHorizontalScrollIndicator = false
        wv.scrollView.bounces = false
        wv.scrollView.alwaysBounceHorizontal = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.navigationDelegate = context.coordinator
        context.coordinator.webView = wv
        return wv
    }

    var documentCSS: String {
        let family = ReaderNovelPreferences.font(fontFamily)
        let font = family == "-apple-system" || family == "ui-rounded" || family == "serif" || family == "sans-serif" ? family : "'\(family)'"
        let size = fontSize.isFinite ? min(max(fontSize, 12), 32) : 16
        let spacing = lineSpacing.isFinite ? min(max(lineSpacing, 1), 3) : 1.6
        let inset = margin.isFinite ? min(max(margin, 0), 30) : 4
        let layout = readingMode == .paged
            ? "html{overflow-y:hidden}body{margin:0;padding:0;width:100vw}#reader-content{height:calc(100vh - 100px);width:calc(100vw - \(2 * inset + 32)px);margin:50px \(inset + 16)px;column-width:calc(100vw - \(2 * inset + 32)px);column-gap:\(2 * inset + 32)px;column-fill:auto;overflow:visible}img,figure{break-inside:avoid;max-height:calc(100vh - 110px)}"
            : "html{overflow-x:hidden}body{margin:0;padding:0;width:100%}#reader-content{max-width:760px;margin:0 auto;padding:64px \(inset + 12)px 90px}"
        return """
        html,body{font-family:\(font),system-ui;font-size:\(size)px;font-weight:\(ReaderNovelPreferences.weight(fontWeight));line-height:\(spacing);text-align:\(ReaderNovelPreferences.alignment(textAlignment));color:\(colorPreset.text);background:\(colorPreset.background);-webkit-user-select:text;overflow-wrap:break-word}*{box-sizing:border-box}h1{font-size:1.7em}h2{font-size:1.4em}h3{font-size:1.2em}h1,h2,h3,h4,h5,h6{line-height:1.3;break-after:avoid}p{margin:0 0 .9em}img{max-width:100%;height:auto;object-fit:contain}figure{margin:1em 0}figcaption{font-size:.85em}a{color:inherit;text-decoration:underline}table{max-width:100%;border-collapse:collapse}pre{white-space:pre-wrap}\(layout)
        """
    }

    var documentHTML: String {
        let csp = isolatesReaderExtensionHTML ? "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; connect-src 'none'\">" : ""
        return """
        <!doctype html><html data-reader-mode="\(readingMode.rawValue)"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">\(csp)<style id="eclipse-reader-style">\(documentCSS)</style></head><body><main id="reader-content">\(htmlContent)</main></body></html>
        """
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let c = context.coordinator
        guard !c.isDismantled else { return }
        c.parent = self
        let changed = c.documentHasChanged(self)
        if changed { c.beginDocumentReplacement() }
        else if c.isDocumentReady {
            if c.settingsHaveChanged(self) { c.stopAutoScroll(); c.applyStyle(webView) }
            if c.lastAutoScrollSpeed != autoScrollSpeed { c.stopAutoScroll(); c.lastAutoScrollSpeed = autoScrollSpeed }
            c.applyScrollRequest(webView)
            c.applySearchRequest(webView)
            if isAutoScrolling { c.startAutoScroll(webView) } else { c.stopAutoScroll() }
            if webView.window != nil { c.startProgressTracking(webView: webView) } else { c.stopProgressTracking() }
        }
        guard changed, !htmlContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        webView.accessibilityIdentifier = "novel.document"
        webView.scrollView.isPagingEnabled = readingMode == .paged
        webView.scrollView.isDirectionalLockEnabled = true
        c.registerNavigation(webView.loadHTMLString(documentHTML, baseURL: nil))
        c.recordDocument(self)
    }

}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        case 8:
            r = Double((int >> 24) & 0xFF) / 255
            g = Double((int >> 16) & 0xFF) / 255
            b = Double((int >> 8) & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }
}

private extension UserDefaults {
    func novelCGFloat(
        forKey key: String,
        default defaultValue: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        guard let value = (object(forKey: key) as? NSNumber)?.doubleValue,
              value.isFinite else { return defaultValue }
        return min(max(CGFloat(value), range.lowerBound), range.upperBound)
    }

    func setNovelCGFloat(_ value: CGFloat, forKey key: String) {
        set(NSNumber(value: Double(value)), forKey: key)
    }
}

#endif
