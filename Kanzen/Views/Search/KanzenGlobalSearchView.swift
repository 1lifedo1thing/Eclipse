//
//  KanzenGlobalSearchView.swift
//  Kanzen
//
//  Created by Eclipse on 2025.
//

import SwiftUI
import Kingfisher

#if !os(tvOS)
struct KanzenGlobalSearchView: View {
    var initialQuery = ""
    var includeLegacyModules = false
    @EnvironmentObject private var moduleManager: ModuleManager
    @StateObject private var viewModel = MangaGlobalModuleSearchViewModel()
    @StateObject private var readerExtensionManager = ReaderExtensionManager.shared
    @StateObject private var contentFilter = ReaderContentFilter.shared
    @State private var searchText = ""
    @State private var recentSearches = MangaSearchRecentStore.load()
    @State private var liveSearchTask: Task<Void, Never>?
    @State private var appliedInitialQuery = false

    var body: some View {
        NavigationView {
            Group {
                if contentFilter.isKidsProfileActive {
                    kidsRestrictedView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            KanzenRootHeader("Search Everything")
                                .padding(.horizontal, -16)

                            KanzenModuleSearchBar(
                                text: $searchText,
                                placeholder: "Search",
                                onSearch: { performSearch(recordRecent: true) }
                            )
                            .padding(.top, 8)
                            .onChange(of: searchText) { newValue in
                                scheduleLiveSearch(newValue)
                            }

                            sourceCards
                            searchStateContent
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .background(GlobalGradientBackground().ignoresSafeArea())
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            syncSources()
            if !appliedInitialQuery {
                appliedInitialQuery = true
                searchText = initialQuery
                if !initialQuery.isEmpty { performSearch(recordRecent: true) }
            }
        }
        .onChange(of: moduleManager.modules) { _ in
            syncSources()
        }
        .onChange(of: readerExtensionManager.installedSources) { _ in
            syncSources()
        }
        .onChange(of: readerExtensionManager.showMatureSources) { _ in
            syncSources()
        }
        .onDisappear {
            liveSearchTask?.cancel()
            viewModel.cancelSearch(keepResults: true)
        }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            liveSearchTask?.cancel()
            liveSearchTask = nil
            searchText = ""
            recentSearches = MangaSearchRecentStore.load()
            if ProfileManager.shared.isKidsModeActive {
                viewModel.restrictForKidsProfile()
            } else {
                viewModel.resetSearch()
                syncSources()
            }
        }
        .onChange(of: contentFilter.isKidsProfileActive) { isKids in
            liveSearchTask?.cancel()
            liveSearchTask = nil
            searchText = ""
            if isKids {
                viewModel.restrictForKidsProfile()
            } else {
                syncSources()
            }
        }
    }

    private var kidsRestrictedView: some View {
        VStack(spacing: 0) {
            KanzenRootHeader("Search Everything")
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 42))
                    .foregroundColor(.secondary)
                Text("Reader Search Unavailable")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Reader sources and search cannot be viewed from a kids profile. Switch to a grown-up profile to continue.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sourceCards: some View {
        let extensionSources = viewModel.sources.filter(\.isReaderExtension)
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        if extensionSources.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 34))
                    .foregroundColor(experimental ? .white.opacity(0.62) : .secondary)
                Text("No searchable Reader Extensions installed")
                    .font(.headline)
                    .foregroundColor(experimental ? .white.opacity(0.78) : .secondary)
                NavigationLink(destination: ReaderExtensionsSettingsView()) {
                    Label("Reader Extensions", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: experimental ? ExperimentalMediaDesignMetrics.current.cardRadius : 12, style: .continuous)
                    .fill(experimental ? Color.white.opacity(0.10) : EclipseTheme.shared.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: experimental ? ExperimentalMediaDesignMetrics.current.cardRadius : 12, style: .continuous)
                    .stroke(Color.white.opacity(experimental ? 0.14 : 0), lineWidth: 1)
            )
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(extensionSources) { source in
                    NavigationLink(destination: MangaReaderExtensionAdvancedSearchView(source: source)) {
                        MangaSearchSourceCard(source: source)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var searchStateContent: some View {
        if viewModel.hasSearched, !viewModel.sections.isEmpty {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(viewModel.sections) { section in
                    MangaModuleSearchSectionView(section: section)
                        .equatable()
                }

                if viewModel.isSearching {
                    HStack(spacing: 10) {
                        EclipseLoadingIndicator()
                        Text("Searching more sources...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                if !viewModel.failedSourceNames.isEmpty {
                    Text("Skipped unavailable sources: \(viewModel.failedSourceNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 2)
                }
            }
        } else if viewModel.isSearching {
            HStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Searching sources...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else if viewModel.hasSearched {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No results found")
                    .font(.headline)
                    .foregroundColor(.secondary)
                if !viewModel.failedSourceNames.isEmpty {
                    Text("Some sources did not respond: \(viewModel.failedSourceNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
        } else {
            recentSearchesView
        }
    }

    @ViewBuilder
    private var recentSearchesView: some View {
        if !recentSearches.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Text("RECENT SEARCHES")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("CLEAR") {
                        MangaSearchRecentStore.clear()
                        recentSearches = []
                    }
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                ForEach(recentSearches, id: \.self) { query in
                    Button {
                        searchText = query
                        performSearch(recordRecent: true)
                    } label: {
                        HStack {
                            Text(query)
                                .font(.title3)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)

                    if query != recentSearches.last {
                        Divider()
                    }
                }
            }
            .background(EclipseTheme.shared.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func performSearch(recordRecent: Bool) {
        guard !ProfileManager.shared.isKidsModeActive else {
            viewModel.restrictForKidsProfile()
            return
        }
        liveSearchTask?.cancel()
        liveSearchTask = nil
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            viewModel.resetSearch()
            return
        }

        if recordRecent {
            recentSearches = MangaSearchRecentStore.add(query)
        }

        syncSources()
        viewModel.searchAll(query)
    }

    private func scheduleLiveSearch(_ value: String) {
        guard !ProfileManager.shared.isKidsModeActive else {
            viewModel.restrictForKidsProfile()
            return
        }
        liveSearchTask?.cancel()
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            viewModel.resetSearch()
            return
        }
        guard !viewModel.isShowingResults(for: query) else { return }

        liveSearchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                liveSearchTask = nil
                guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                guard !viewModel.isShowingResults(for: query) else { return }
                syncSources()
                viewModel.searchAll(query)
            }
        }
    }

    private func syncSources() {
        guard !ProfileManager.shared.isKidsModeActive else {
            viewModel.restrictForKidsProfile()
            return
        }
        viewModel.refreshSources(
            from: moduleManager.modules,
            readerExtensionManager: readerExtensionManager,
            includeLegacyModules: includeLegacyModules
        )
    }
}

private struct MangaModuleSearchSectionView: View, Equatable {
    let section: MangaModuleSearchSection
    private var designMetrics: ExperimentalMediaDesignMetrics { .current }
    private var posterWidth: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? designMetrics.posterCardSize(isIPad: isIPad).width : (isIPad ? 132 * iPadScaleSmall : 132)
    }

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        VStack(alignment: .leading, spacing: experimental ? 14 : 12) {
            Text(section.source.name)
                .font(experimental ? Font.system(size: 34, weight: .bold) : Font.largeTitle)
                .foregroundColor(experimental ? .white : .primary)
                .lineLimit(1)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: experimental ? 16 : 12) {
                    ForEach(section.items.prefix(MangaHomeViewModel.maxVisibleItemsPerSection)) { item in
                        NavigationLink(destination: MangaSearchItemDestination(source: section.source, item: item)) {
                            MangaSearchPosterCard(item: item, width: posterWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .modifier(KanzenScrollClipModifier())
        }
    }
}

private struct MangaSearchItemDestination: View {
    let source: MangaHomeSource
    let item: MangaHomeItem

    var body: some View {
        if let extensionItem = item.readerExtensionItem, let sourceID = source.sourceID {
            ReaderExtensionMangaDetailView(sourceID: sourceID, initialItem: extensionItem)
        } else if case .readerExtension(let sourceID, let itemKey, let legacyStableKey) = item.route {
            ReaderExtensionMangaRouteLoaderView(
                sourceID: sourceID,
                itemKey: itemKey,
                legacyStableKey: legacyStableKey,
                title: item.title,
                coverURL: item.imageURL
            )
        } else if let module = source.module {
            MangaModuleContentLoaderView(
                module: module,
                title: item.title,
                imageURL: item.imageURL,
                contentParams: item.params,
                isNovel: module.moduleData.novel == true
            )
        } else {
            MangaModuleUnavailableView(title: item.title, message: "This source is no longer available.")
        }
    }
}

private struct MangaSearchPosterCard: View {
    let item: MangaHomeItem
    let width: CGFloat
    private var designMetrics: ExperimentalMediaDesignMetrics { .current }

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        VStack(alignment: .leading, spacing: experimental ? 8 : 4) {
            ReaderScopedRemoteImage(
                url: URL(string: item.imageURL),
                readerExtensionSourceID: item.route?.readerExtensionSourceID,
                maximumPixelSize: isIPad ? 900 : 640
            ) {
                    Rectangle().fill(Color.gray.opacity(0.22))
            }
                .scaledToFill()
                .frame(width: width, height: width * 1.45)
                .clipped()
                .cornerRadius(experimental ? designMetrics.cardRadius : 10)

            Text(item.title)
                .font(experimental ? .title3.weight(.semibold) : .headline)
                .lineLimit(1)
                .foregroundColor(experimental ? .white : .primary)
                .frame(width: width, alignment: .leading)

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(experimental ? .white.opacity(0.62) : .secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
    }
}

private struct MangaSearchSourceCard: View {
    let source: MangaHomeSource
    private var designMetrics: ExperimentalMediaDesignMetrics { .current }

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        VStack(alignment: .leading, spacing: experimental ? 10 : 8) {
            ZStack {
                RoundedRectangle(cornerRadius: experimental ? designMetrics.cardRadius : 12, style: .continuous)
                    .fill(experimental ? Color.white.opacity(0.10) : EclipseTheme.shared.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: experimental ? designMetrics.cardRadius : 12, style: .continuous)
                            .stroke(Color.white.opacity(experimental ? 0.14 : 0), lineWidth: 1)
                    )

                ReaderScopedRemoteImage(
                    url: URL(string: source.iconURL),
                    readerExtensionSourceID: source.sourceID,
                    maximumPixelSize: 512
                ) {
                        Image(systemName: "shippingbox")
                            .font(.title3)
                            .foregroundColor(.secondary)
                }
                    .scaledToFit()
                    .padding(24)
            }
            .aspectRatio(1, contentMode: .fit)

            Text(source.name)
                .font(.headline)
                .fontWeight(.bold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundColor(experimental ? .white : .primary)
        }
    }
}

private struct MangaReaderExtensionAdvancedSearchView: View {
    let source: MangaHomeSource

    @StateObject private var viewModel = MangaReaderExtensionAdvancedSearchViewModel()
    @StateObject private var filterEditor = ReaderExtensionFilterEditorModel()
    @State private var searchText = ""
    @State private var hasPendingSearchChanges = false
    @State private var catalogDraft: KanzenCustomCatalog?
    @State private var savedCatalogTitle: String?
    @State private var catalogErrorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                KanzenModuleSearchBar(
                    text: $searchText,
                    placeholder: "Search \(source.name)",
                    onSearch: submitSearch
                )
                .onChange(of: searchText) { _ in markSearchPending() }

                Button(action: submitSearch) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text(searchButtonTitle)
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSearchBlocked)
                .opacity(isSearchBlocked ? 0.55 : 1)
                .accessibilityHint("Runs one search using the current title and every selected filter.")

                saveAsCatalogControls
                resultsContent
                filtersContent
            }
            .padding(16)
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .kanzenGradientBackground()
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: submitSearch) {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(isSearchBlocked)
                .tint(.white)
                .accessibilityLabel("Search with current filters")
            }
        }
        .task {
            loadFilters()
        }
        .onChange(of: filterEditor.successfulLoadRevision) { _ in
            if viewModel.hasSearched {
                markSearchPending()
            }
        }
        .onDisappear {
            viewModel.cancel()
            filterEditor.cancel()
        }
        .sheet(item: $catalogDraft) { draft in
            KanzenCustomCatalogEditorView(
                sourceName: source.name,
                draft: draft,
                isRenamingExistingCatalog: false,
                onSaved: { saved in
                    savedCatalogTitle = saved.displayTitle
                    catalogErrorMessage = nil
                }
            )
        }
    }

    @ViewBuilder
    private var saveAsCatalogControls: some View {
        if let draft = viewModel.appliedCatalogDraft, let sourceID = source.sourceID {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    presentCatalogEditor(sourceID: sourceID, draft: draft)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.badge.plus")
                        Text("Save as Catalog")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Saves these filters as a row on Discover for \(source.name).")

                if let savedCatalogTitle {
                    Label("Saved \u{201C}\(savedCatalogTitle)\u{201D} to Discover", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundColor(.green.opacity(0.9))
                }
                if let catalogErrorMessage {
                    Label(catalogErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange.opacity(0.9))
                }
            }
        }
    }

    private func presentCatalogEditor(
        sourceID: ReaderExtensionSourceID,
        draft: (query: String, filters: [ReaderExtensionFilter])
    ) {
        savedCatalogTitle = nil
        guard KanzenCustomCatalogManager.shared.canAddCatalog(for: sourceID) else {
            catalogErrorMessage = KanzenCustomCatalogError
                .sourceLimitReached(KanzenCustomCatalogManager.maximumCatalogsPerSource)
                .localizedDescription
            return
        }
        catalogErrorMessage = nil
        catalogDraft = KanzenCustomCatalog(
            title: "",
            sourceID: sourceID,
            query: draft.query,
            filters: draft.filters
        )
    }

    @ViewBuilder
    private var filtersContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Filters")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(filterEditor.displayRows.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.62))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                Spacer(minLength: 4)
                filterResetButton
                filterRefreshButton
            }

            if let filterErrorMessage = filterEditor.errorMessage {
                Label(filterErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if filterEditor.isLoading {
                HStack(spacing: 10) {
                    EclipseLoadingIndicator()
                    Text("Loading filters...")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.62))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else if filterEditor.filters.isEmpty {
                Text("This source does not expose advanced filters.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ReaderExtensionFilterEditorList(
                    filters: $filterEditor.filters,
                    onEdit: markSearchPending
                )
            }
        }
        .padding(14)
        .background(EclipseTheme.shared.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var resultsContent: some View {
        if viewModel.isSearching {
            HStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Searching...")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.62))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange.opacity(0.9))
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if viewModel.hasSearched, viewModel.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundColor(.white.opacity(0.62))
                Text(viewModel.hasNextPage ? "No visible results on this page" : "No results found")
                    .font(.headline)
                    .foregroundColor(.white)
                Text(viewModel.hasNextPage ? "Load another page or adjust the filters below." : "Try a different title or adjust the filters below.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                if viewModel.hasNextPage {
                    paginationControls
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if viewModel.hasSearched {
            VStack(spacing: 14) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(viewModel.items) { item in
                        NavigationLink(destination: MangaSearchItemDestination(source: source, item: item)) {
                            MangaSearchPosterCard(item: item, width: 116)
                        }
                        .buttonStyle(.plain)
                    }
                }

                paginationControls
            }
        }
    }

    private var filterResetButton: some View {
        Button {
            if filterEditor.reset() {
                markSearchPending()
            }
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!filterEditor.canReset)
        .opacity(filterEditor.canReset ? 1 : 0.42)
        .accessibilityHint("Restores the filter defaults loaded when this screen opened without searching.")
    }

    private var filterRefreshButton: some View {
        Button {
            refreshFilters()
        } label: {
            Label("Refresh Filters", systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isFilterRefreshBlocked)
        .opacity(isFilterRefreshBlocked ? 0.42 : 1)
        .accessibilityHint("Reloads this source's filter choices without searching.")
    }

    @ViewBuilder
    private var paginationControls: some View {
        if let paginationErrorMessage = viewModel.paginationErrorMessage {
            Label(paginationErrorMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.orange.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }

        if viewModel.isLoadingMore {
            HStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Loading page \(viewModel.currentPage + 1)...")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.62))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else if canLoadMoreResults {
            Button {
                viewModel.loadMore(source: source)
            } label: {
                Label("Load More", systemImage: "chevron.down")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Loads one more page using the filters from the last applied search.")
        } else if viewModel.didReachResultLimit {
            Text("Result limit reached. Refine the title or filters to continue.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }

        if viewModel.currentPage > 0 {
            Text("Page \(viewModel.currentPage) · \(viewModel.items.count) results")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white.opacity(0.50))
                .frame(maxWidth: .infinity)
        }
    }

    private var isSearchBlocked: Bool {
        filterEditor.isLoading || viewModel.isSearching
    }

    private var isFilterRefreshBlocked: Bool {
        filterEditor.isLoading || viewModel.isSearching || viewModel.isLoadingMore
    }

    private var canLoadMoreResults: Bool {
        viewModel.canLoadMore && !filterEditor.isLoading
    }

    private func loadFilters() {
        guard let sourceID = filterSourceID() else { return }
        filterEditor.load(sourceID: sourceID, label: source.id)
    }

    private func refreshFilters() {
        guard !viewModel.isSearching, !viewModel.isLoadingMore else { return }
        guard let sourceID = filterSourceID() else { return }
        filterEditor.reload(sourceID: sourceID, label: source.id)
    }

    private func filterSourceID() -> ReaderExtensionSourceID? {
        guard let sourceID = source.sourceID else {
            filterEditor.reportUnavailableSource()
            return nil
        }
        return sourceID
    }

    private func submitSearch() {
        guard !isSearchBlocked else { return }
        hasPendingSearchChanges = false
        viewModel.search(source: source, query: searchText, filters: filterEditor.filters)
    }

    private var searchButtonTitle: String {
        guard viewModel.hasSearched else { return "Apply & Search" }
        return hasPendingSearchChanges ? "Apply Changes & Search" : "Search Again"
    }

    private func markSearchPending() {
        hasPendingSearchChanges = true
    }
}

struct KanzenModuleSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let onSearch: () -> Void

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundColor(.white.opacity(0.72))

            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundColor(.white.opacity(0.42))
            )
                .font(.title2)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .foregroundColor(.white)
                .tint(.white)
                .onSubmit(onSearch)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.62))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: experimental ? ExperimentalMediaDesignMetrics.current.cardRadius : 12, style: .continuous)
                .fill(experimental ? Color.white.opacity(0.12) : EclipseTheme.shared.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: experimental ? ExperimentalMediaDesignMetrics.current.cardRadius : 12, style: .continuous)
                .stroke(Color.white.opacity(experimental ? 0.14 : 0), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

#endif
