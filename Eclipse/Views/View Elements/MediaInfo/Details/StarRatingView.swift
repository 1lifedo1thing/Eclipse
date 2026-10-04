import Foundation
import SwiftUI

struct StarRatingView: View {
    let mediaId: Int
    let isMovie: Bool
    let isAnime: Bool
    let usesIPadAtmosphereStyle: Bool
    let seasonNumber: Int?
    let seasonTitle: String?
    let knownAniListID: Int?
    let knownMALID: Int?
    let ratingManager: UserRatingManager
    let allowsTrackerSync: Bool
    let allowsTMDBSeasonScope: Bool

    @AppStorage("ratingsFollowSeasonSelection") private var locksToSeason = true
    @ObservedObject private var profileManager = ProfileManager.shared

    @StateObject private var trackerManager = TrackerManager.shared
    @State private var isExpanded = false
    @State private var currentRating: Double = 0
    @State private var noteText = ""
    @State private var syncMessage: String?
    @State private var showingWholeShow = false
    @State private var loadedScopeKey = ""
    @State private var syncRequestID = UUID()
    @State private var scopeAuthority: ProviderPlaybackScopeAuthority?
    @State private var legacyReview: UserRatingManager.Entry?


    init(mediaId: Int, isMovie: Bool, isAnime: Bool = false, usesIPadAtmosphereStyle: Bool = false, seasonNumber: Int? = nil, seasonTitle: String? = nil, knownAniListID: Int? = nil, knownMALID: Int? = nil, manager: UserRatingManager = .shared, allowsTrackerSync: Bool = true, allowsTMDBSeasonScope: Bool = false) {
        self.mediaId = mediaId
        self.isMovie = isMovie
        self.isAnime = isAnime
        self.usesIPadAtmosphereStyle = usesIPadAtmosphereStyle
        self.seasonNumber = seasonNumber
        self.seasonTitle = seasonTitle
        self.knownAniListID = knownAniListID
        self.knownMALID = knownMALID
        self.ratingManager = manager
        self.allowsTrackerSync = allowsTrackerSync
        self.allowsTMDBSeasonScope = allowsTMDBSeasonScope
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: currentRating > 0 ? "star.fill" : "star")
                        .foregroundColor(currentRating > 0 ? .yellow : .white.opacity(0.65))

                    Text("Rating & Notes")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white.opacity(0.85))

                    if currentRating > 0 {
                        Text("\(ratingDisplayText)/10")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    if !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.55))
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(ratingControlBackground)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ratings.expand")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if ratingManager.hasUnreadableStore {
                        Text("Saved ratings could not be loaded. Restore a readable backup before editing ratings or notes. The previous file has been kept.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        scopeControls
                        if canEditScope {
                            ratingStars
                            legacyRatingMigration
                            notesEditor
                            trackerButtons
                        } else {
                            Text(seasonNumber == nil ? "Choose a season to add its rating and notes, or select Whole Show." : "The selected anime entry is still being matched. Ratings and notes will be available when its exact identity is ready.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let syncMessage {
                        Text(syncMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(expandedRatingBackground)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .onAppear { loadScope() }
        .onChangeComp(of: scopeKey) { _, _ in loadScope() }
        .onChangeComp(of: seasonNumber) { _, _ in
            showingWholeShow = false
            loadScope()
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange).receive(on: DispatchQueue.main)) { _ in
            showingWholeShow = false
            loadScope()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userRatingDataDidChange).receive(on: DispatchQueue.main)) { notification in
            guard UserRatingManager.notificationBelongsToActiveProfile(notification) else { return }
            loadScope()
        }
    }

    private var effectiveSeasonNumber: Int? {
        !isMovie && locksToSeason && !showingWholeShow ? seasonNumber : nil
    }

    private var storageAniListID: Int? {
        effectiveSeasonNumber != nil ? knownAniListID.flatMap { $0 > 0 ? $0 : nil } : nil
    }

    private var storageMALID: Int? {
        effectiveSeasonNumber != nil ? knownMALID.flatMap { $0 > 0 ? $0 : nil } : nil
    }

    private var scopeKey: String {
        let key = UserRatingManager.storageKey(tmdbID: mediaId, isMovie: isMovie,
            seasonNumber: effectiveSeasonNumber, aniListID: storageAniListID, malID: storageMALID)
        return "\(profileManager.activeProfileID):\(key)"
    }

    private var canEditScope: Bool {
        if !isMovie, locksToSeason, !showingWholeShow, seasonNumber == nil { return false }
        return !isAnime || isMovie || effectiveSeasonNumber == nil || storageAniListID != nil || storageMALID != nil || allowsTMDBSeasonScope
    }

    private var canSyncTrackerScope: Bool {
        allowsTrackerSync && (!isAnime || isMovie || effectiveSeasonNumber == nil || storageAniListID != nil || storageMALID != nil)
    }

    private var canMutate: Bool {
        canEditScope && loadedScopeKey == scopeKey && scopeAuthority?.isCurrent == true
            && !ratingManager.hasUnreadableStore
    }

    @ViewBuilder
    private var scopeControls: some View {
        if !isMovie {
            HStack {
                Text(effectiveSeasonNumber != nil ? (seasonTitle ?? "Season \(seasonNumber ?? 1)") : (locksToSeason && !showingWholeShow ? "Choose a Season" : "Whole Show"))
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("ratings.scope")
                Spacer()
                if locksToSeason {
                    Button(showingWholeShow ? "Use Selected Season" : "Whole Show") {
                        showingWholeShow.toggle()
                        loadScope()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ratings.change-scope")
                }
            }
            if effectiveSeasonNumber != nil,
               ratingManager.rating(for: mediaId, isMovie: false) != nil ||
                !ratingManager.note(for: mediaId, isMovie: false).isEmpty {
                Text("A whole-show rating or note is also saved. Select Whole Show to view it.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var noteBinding: Binding<String> {
        let renderedKey = scopeKey
        let authority = scopeAuthority
        return Binding(get: { noteText }, set: { value in
            guard renderedKey == scopeKey, loadedScopeKey == renderedKey,
                  authority?.isCurrent == true, canMutate else { return }
            noteText = value
            ratingManager.setNote(value, for: mediaId, isMovie: isMovie,
                seasonNumber: effectiveSeasonNumber, aniListID: storageAniListID, malID: storageMALID)
        })
    }

    private func loadScope() {
        let authority = ProviderPlaybackScopeAuthority.capture()
        if canEditScope, effectiveSeasonNumber != nil {
            ratingManager.reconcileAnimeIdentity(tmdbID: mediaId, aniListID: storageAniListID, malID: storageMALID)
        }
        let rating = canEditScope ? ratingManager.rating(for: mediaId, isMovie: isMovie,
            seasonNumber: effectiveSeasonNumber, aniListID: storageAniListID, malID: storageMALID) ?? 0 : 0
        let note = canEditScope ? ratingManager.note(for: mediaId, isMovie: isMovie,
            seasonNumber: effectiveSeasonNumber, aniListID: storageAniListID, malID: storageMALID) : ""
        let legacyEntry = ratingManager.legacyEntry(for: mediaId)
        let didChange = scopeAuthority != authority || loadedScopeKey != scopeKey || currentRating != rating || noteText != note || legacyReview != legacyEntry
        scopeAuthority = authority
        loadedScopeKey = scopeKey
        currentRating = rating
        noteText = note
        legacyReview = legacyEntry
        if didChange {
            syncMessage = nil
            syncRequestID = UUID()
        }
    }

    @ViewBuilder
    private var legacyRatingMigration: some View {
        if !profileManager.isKidsModeActive,
           let entry = legacyReview {
            VStack(alignment: .leading, spacing: 6) {
                Text("A previous rating or note shares this number, but its title identity was not saved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let legacyRating = entry.rating {
                    Text("Previous rating: \(legacyRating, specifier: "%.1f")/10")
                        .font(.caption)
                }
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption).lineLimit(4)
                }
                let authority = scopeAuthority
                let renderedKey = scopeKey
                Button(effectiveSeasonNumber != nil ? "Use for This Season" : (isMovie ? "Use for This Movie" : "Use for Whole Show")) {
                    guard !profileManager.isKidsModeActive, canMutate,
                          renderedKey == scopeKey, authority?.isCurrent == true,
                          let authority else { return }
                    if ratingManager.attachLegacyEntry(
                        entry, isMovie: isMovie, seasonNumber: effectiveSeasonNumber,
                        aniListID: storageAniListID, malID: storageMALID,
                        expectedProfileID: authority.profileID
                    ) {
                        loadScope()
                    } else {
                        syncMessage = "Could not attach the previous review. Existing ratings and notes have been kept."
                    }
                }
                .accessibilityIdentifier("ratings.attach-legacy")
            }
        }
    }

    @ViewBuilder
    private var ratingControlBackground: some View {
        if usesIPadAtmosphereStyle {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.18))
        }
    }

    @ViewBuilder
    private var expandedRatingBackground: some View {
        if usesIPadAtmosphereStyle {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.14))
        }
    }

    @ViewBuilder
    private var ratingStars: some View {
        HStack(spacing: 4) {
            ForEach(1...10, id: \.self) { star in
#if os(tvOS)
                Button {
                    updateRating(Double(star))
                } label: {
                    Image(systemName: starSymbol(for: star))
                        .font(.body)
                        .foregroundColor(starTint(for: star))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(star) out of 10")
                .accessibilityIdentifier("ratings.star.\(star)")
#else
                let starImage = Image(systemName: starSymbol(for: star))
                    .font(.body)
                    .foregroundColor(starTint(for: star))

                GeometryReader { proxy in
                    starImage
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let isLeftHalf = value.location.x < proxy.size.width / 2
                                    updateRating(Double(star) - (isLeftHalf ? 0.5 : 0))
                                }
                        )
                }
                .frame(width: 20, height: 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(star) out of 10")
                .accessibilityIdentifier("ratings.star.\(star)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { updateRating(Double(star)) }
                .animation(.easeInOut(duration: 0.15), value: currentRating)
#endif
            }

            Spacer(minLength: 8)

            Text(currentRating > 0 ? "\(ratingDisplayText)/10" : "No rating")
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
                .accessibilityIdentifier("ratings.value")
        }
    }

    @ViewBuilder
    private var notesEditor: some View {
#if os(tvOS)
        TextField("Private notes", text: noteBinding)
            .accessibilityIdentifier("ratings.notes")
            .textFieldStyle(.plain)
            .padding(12)
            .foregroundColor(.white)
            .background(Color.black.opacity(0.2))
            .cornerRadius(8)
#else
        TextEditor(text: noteBinding)
            .accessibilityIdentifier("ratings.notes")
            .frame(minHeight: 82)
            .padding(8)
            .foregroundColor(.white)
            .background(Color.black.opacity(0.2))
            .cornerRadius(8)
            .eclipseHideScrollBackground()
#endif
    }

    @ViewBuilder
    private var trackerButtons: some View {
        let canWrite = isAnime && trackerManager.trackerState.syncEnabled && canMutate
        let hasAniList = trackerManager.hasConnectedAccount(.anilist)
        let hasMAL = trackerManager.hasConnectedAccount(.myAnimeList)

        if isAnime && canSyncTrackerScope && (hasAniList || hasMAL) {
            HStack(spacing: 10) {
                if hasAniList {
                    Button {
                        syncRatingAndNote(to: .anilist)
                    } label: {
                        Label("AniList", systemImage: "arrow.up.circle")
                    }
                    .disabled(!canWrite)
                }

                if hasMAL {
                    Button {
                        syncRatingAndNote(to: .myAnimeList)
                    } label: {
                        Label("MAL", systemImage: "arrow.up.circle")
                    }
                    .disabled(!canWrite)
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(.blue)
        }
    }

    private func updateRating(_ value: Double) {
        guard canMutate else { return }
        let rating = Self.normalizedRating(value)
        withAnimation(.easeInOut(duration: 0.15)) {
            if Self.ratingsAreEqual(currentRating, rating) {
                currentRating = 0
                ratingManager.removeRating(for: mediaId, isMovie: isMovie, seasonNumber: effectiveSeasonNumber, aniListID: storageAniListID, malID: storageMALID)
                if canSyncTrackerScope {
                    trackerManager.cancelUserRatingSync(tmdbId: mediaId, isMovie: isMovie,
                        seasonNumber: effectiveSeasonNumber, knownAniListID: isMovie ? knownAniListID : storageAniListID,
                        knownMALID: isMovie ? knownMALID : storageMALID)
                }
            } else {
                currentRating = rating
                ratingManager.setRating(rating, for: mediaId, isMovie: isMovie, seasonNumber: effectiveSeasonNumber, aniListID: storageAniListID, malID: storageMALID)
                if canSyncTrackerScope {
                    trackerManager.syncUserRating(tmdbId: mediaId, ratingOutOf10: rating, isAnime: isAnime,
                        seasonNumber: effectiveSeasonNumber, knownAniListID: isMovie ? knownAniListID : storageAniListID,
                        knownMALID: isMovie ? knownMALID : storageMALID, isMovie: isMovie)
                }
            }
        }
    }

    private func syncRatingAndNote(to service: TrackerService) {
        guard canMutate, canSyncTrackerScope else { return }
        let renderedKey = scopeKey
        let authority = scopeAuthority
        let requestID = UUID()
        syncRequestID = requestID
        let admitted = trackerManager.syncRatingAndNote(
            tmdbId: mediaId,
            ratingOutOf10: currentRating > 0 ? currentRating : nil,
            note: noteText,
            service: service,
            isAnime: isAnime,
            seasonNumber: effectiveSeasonNumber,
            knownAniListID: isMovie ? knownAniListID : storageAniListID,
            knownMALID: isMovie ? knownMALID : storageMALID,
            isMovie: isMovie
        ) { succeeded in
            guard authority?.isCurrent == true, loadedScopeKey == renderedKey, syncRequestID == requestID else { return }
            syncMessage = succeeded ? "Saved to \(service.displayName)." : "Could not save to \(service.displayName). Check the connection and try again."
        }
        syncMessage = admitted ? "Syncing to \(service.displayName)..." : "The exact tracker entry is unavailable, or rating sync is disabled."
    }

    private var ratingDisplayText: String {
        Self.ratingDisplayString(currentRating)
    }

    private func starSymbol(for star: Int) -> String {
        let fullValue = Double(star)
        if currentRating >= fullValue {
            return "star.fill"
        }
        if currentRating >= fullValue - 0.5 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }

    private func starTint(for star: Int) -> Color {
        currentRating >= Double(star) - 0.5 ? .yellow : .white.opacity(0.3)
    }

    private static func normalizedRating(_ value: Double) -> Double {
        let finiteValue = value.isFinite ? value : 0.5
        let halfStepValue = (finiteValue * 2).rounded() / 2
        return max(0.5, min(10, halfStepValue))
    }

    private static func ratingsAreEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    private static func ratingDisplayString(_ rating: Double) -> String {
        let normalized = normalizedRating(rating)
        if normalized.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(normalized))
        }
        return String(format: "%.1f", normalized)
    }
}

#if !os(tvOS)
struct ReaderRatingNotesView: View {
    let itemId: Int
    let title: String
    let progressItemId: Int?
    let routeKey: String?
    let knownAniListId: Int?
    let knownMALId: Int?
    let totalChapters: Int?
    let format: String?

    @StateObject private var trackerManager = TrackerManager.shared
    @State private var isExpanded = false
    @State private var currentRating: Double = 0
    @State private var noteText = ""
    @State private var syncMessage: String?

    init(
        itemId: Int,
        title: String,
        progressItemId: Int? = nil,
        routeKey: String? = nil,
        knownAniListId: Int? = nil,
        knownMALId: Int? = nil,
        totalChapters: Int? = nil,
        format: String? = nil
    ) {
        self.itemId = itemId
        self.title = title
        self.progressItemId = progressItemId
        self.routeKey = routeKey
        self.knownAniListId = knownAniListId
        self.knownMALId = knownMALId
        self.totalChapters = totalChapters
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: currentRating > 0 ? "star.fill" : "star")
                        .foregroundColor(currentRating > 0 ? .yellow : .secondary)

                    Text("Rating & Notes")
                        .font(.headline)
                        .foregroundColor(.primary)

                    if currentRating > 0 {
                        Text("\(ratingDisplayText)/10")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                    }

                    if !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ratingStars
                    notesEditor
                    trackerButtons

                    if let syncMessage {
                        Text(syncMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            currentRating = UserRatingManager.shared.rating(for: itemId) ?? 0
            noteText = UserRatingManager.shared.note(for: itemId)
        }
        .onChange(of: noteText) { value in
            UserRatingManager.shared.setNote(value, for: itemId)
        }
    }

    @ViewBuilder
    private var ratingStars: some View {
        HStack(spacing: 4) {
            ForEach(1...10, id: \.self) { star in
                let starImage = Image(systemName: starSymbol(for: star))
                    .font(.body)
                    .foregroundColor(starTint(for: star))

                GeometryReader { proxy in
                    starImage
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let isLeftHalf = value.location.x < proxy.size.width / 2
                                    updateRating(Double(star) - (isLeftHalf ? 0.5 : 0))
                                }
                        )
                }
                .frame(width: 20, height: 22)
                .animation(.easeInOut(duration: 0.15), value: currentRating)
            }

            Spacer(minLength: 8)

            Text(currentRating > 0 ? "\(ratingDisplayText)/10" : "No rating")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var notesEditor: some View {
        TextEditor(text: $noteText)
            .frame(minHeight: 82)
            .padding(8)
            .foregroundColor(.primary)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(8)
            .eclipseHideScrollBackground()
            .overlay(alignment: .topLeading) {
                if noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Private notes for \(title)")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var trackerButtons: some View {
        let hasAniList = trackerManager.hasConnectedAccount(.anilist)
        let hasMAL = trackerManager.hasConnectedAccount(.myAnimeList)
        let canWrite = trackerManager.trackerState.readerSyncEnabled && currentRating > 0

        if hasAniList || hasMAL {
            HStack(spacing: 10) {
                if hasAniList {
                    Button {
                        syncRatingAndNote(to: .anilist)
                    } label: {
                        Label("AniList", systemImage: "arrow.up.circle")
                    }
                    .disabled(!canWrite)
                }

                if hasMAL {
                    Button {
                        syncRatingAndNote(to: .myAnimeList)
                    } label: {
                        Label("MAL", systemImage: "arrow.up.circle")
                    }
                    .disabled(!canWrite)
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(.blue)
        }
    }

    private func updateRating(_ value: Double) {
        let rating = Self.normalizedRating(value)
        withAnimation(.easeInOut(duration: 0.15)) {
            if Self.ratingsAreEqual(currentRating, rating) {
                currentRating = 0
                UserRatingManager.shared.removeRating(for: itemId)
            } else {
                currentRating = rating
                UserRatingManager.shared.setRating(rating, for: itemId)
                TrackerManager.shared.syncReaderMangaRating(
                    localMangaId: progressLookupId,
                    title: title,
                    ratingOutOf10: rating,
                    note: nil,
                    totalChapters: totalChapters,
                    format: format,
                    routeKey: routeKey,
                    knownAniListId: resolvedKnownAniListId,
                    knownMALId: resolvedKnownMALId,
                    isAutomatic: true
                )
            }
        }
    }

    private func syncRatingAndNote(to service: TrackerService) {
        UserRatingManager.shared.setNote(noteText, for: itemId)
        let trimmedNote = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        TrackerManager.shared.syncReaderMangaRating(
            localMangaId: progressLookupId,
            title: title,
            ratingOutOf10: currentRating,
            note: trimmedNote.isEmpty ? nil : noteText,
            service: service,
            totalChapters: totalChapters,
            format: format,
            routeKey: routeKey,
            knownAniListId: resolvedKnownAniListId,
            knownMALId: resolvedKnownMALId,
            isAutomatic: false
        )
        syncMessage = "Syncing to \(service.displayName)..."
    }

    private var resolvedKnownAniListId: Int? {
        knownAniListId ?? MangaReadingProgressManager.shared.progress(for: progressLookupId)?.trackerAniListId
    }

    private var resolvedKnownMALId: Int? {
        knownMALId ?? MangaReadingProgressManager.shared.progress(for: progressLookupId)?.trackerMALId
    }

    private var progressLookupId: Int {
        progressItemId ?? itemId
    }

    private var ratingDisplayText: String {
        Self.ratingDisplayString(currentRating)
    }

    private func starSymbol(for star: Int) -> String {
        let fullValue = Double(star)
        if currentRating >= fullValue {
            return "star.fill"
        }
        if currentRating >= fullValue - 0.5 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }

    private func starTint(for star: Int) -> Color {
        currentRating >= Double(star) - 0.5 ? .yellow : .secondary.opacity(0.45)
    }

    private static func normalizedRating(_ value: Double) -> Double {
        let finiteValue = value.isFinite ? value : 0.5
        let halfStepValue = (finiteValue * 2).rounded() / 2
        return max(0.5, min(10, halfStepValue))
    }

    private static func ratingsAreEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    private static func ratingDisplayString(_ rating: Double) -> String {
        let normalized = normalizedRating(rating)
        if normalized.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(normalized))
        }
        return String(format: "%.1f", normalized)
    }
}
#endif
