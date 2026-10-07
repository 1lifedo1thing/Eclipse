import SwiftUI

struct PlayerLanguageSelectionView: View {
    let title: String
    @Binding var selectedLanguage: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var accentColorManager = AccentColorManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @State private var searchText = ""
    @State private var visibleLanguages = MediaLanguageCatalog.languages
    @State private var selectionOwner: LanguageSelectionOwner?

    private var canSelect: Bool {
        profileManager.rosterStoreIsReadable && selectionOwner?.isCurrent == true
    }

    private var savedVariant: MediaLanguageCatalog.Entry? {
        guard let language = MediaLanguageCatalog.language(for: selectedLanguage),
              !MediaLanguageCatalog.languages.contains(where: { $0.id == language.id }) else { return nil }
        return language
    }

    var body: some View {
        List {
            if !selectedLanguage.isEmpty, MediaLanguageCatalog.language(for: selectedLanguage) == nil {
                Section {
                    Text(selectedLanguage)
                    Text("Choose a language to replace this saved preference.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Needs Review")
                }
                .eclipseExperimentalSettingsRows()
            }

            if let language = savedVariant {
                Section {
                    Button {
                        guard canSelect else { return }
                        dismiss()
                    } label: {
                        LanguageCatalogRow(
                            language: language,
                            isSelected: true,
                            accent: accentColorManager.currentAccentColor
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSelect)
                    .accessibilityIdentifier("player-language-option-\(language.id)")
                } header: {
                    Text("Current Preference")
                }
                .eclipseExperimentalSettingsRows()
            }

            Section {
                ForEach(visibleLanguages) { language in
                    Button {
                        guard canSelect else { return }
                        selectedLanguage = language.id
                        guard canSelect else { return }
                        dismiss()
                    } label: {
                        LanguageCatalogRow(
                            language: language,
                            isSelected: MediaLanguageCatalog.canonicalID(for: selectedLanguage) == language.id,
                            accent: accentColorManager.currentAccentColor
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSelect)
                    .accessibilityIdentifier("player-language-option-\(language.id)")
                }
            } header: {
                Text("Languages")
            }
            .eclipseExperimentalSettingsRows()

            if visibleLanguages.isEmpty, savedVariant?.matches(query: searchText) != true {
                Text("No matching languages")
                    .foregroundColor(.secondary)
            }
        }
        .searchable(text: $searchText, prompt: "Search languages or codes")
        .onChangeComp(of: searchText) { _, query in
            visibleLanguages = MediaLanguageCatalog.search(query: query)
        }
        .onAppear {
            if selectionOwner == nil { selectionOwner = LanguageSelectionOwner.capture() }
        }
        .eclipsePageTitle(title)
        .eclipseSettingsStyle()
        .preferredColorScheme(.dark)
        .tint(accentColorManager.currentAccentColor)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

struct StreamLanguageSelectionView: View {
    let title: String
    @Binding var selectedLanguages: [String]
    var conflictingLanguages: [String] = []
    var isAdministrable = true
    @Environment(\.dismiss) private var dismiss
    @StateObject private var accentColorManager = AccentColorManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @State private var searchText = ""
    @State private var visibleLanguages = MediaLanguageCatalog.languages
    @State private var selectionOwner: LanguageSelectionOwner?

    private let maximumSelectionCount = 40
    private let audioTags = ["Dual Audio", "Multi Audio"]

    private var canSelect: Bool {
        isAdministrable
            && profileManager.rosterStoreIsReadable
            && profileManager.activeProfile?.isKidsProfile == false
            && selectionOwner?.isCurrent == true
    }

    private var selectedIDs: Set<String> {
        Set(selectedLanguages.compactMap(MediaLanguageCatalog.filterCanonicalID(for:)))
    }

    private var conflictingIDs: Set<String> {
        Set(conflictingLanguages.compactMap(MediaLanguageCatalog.filterCanonicalID(for:)))
    }

    private var savedVariants: [MediaLanguageCatalog.Entry] {
        let catalogIDs = Set(MediaLanguageCatalog.languages.map(\.id))
        var seen = Set<String>()
        return selectedLanguages.compactMap(MediaLanguageCatalog.filterLanguage(for:)).filter {
            !catalogIDs.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    private func hasConflict(with id: String) -> Bool {
        conflictingIDs.contains {
            MediaLanguageCatalog.matches(ruleID: $0, languageID: id)
                || MediaLanguageCatalog.matches(ruleID: id, languageID: $0)
        }
    }

    private var visibleAudioTags: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return audioTags.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    private var needsReview: [String] {
        var seen = Set<String>()
        return selectedLanguages.filter {
            MediaLanguageCatalog.filterCanonicalID(for: $0) == nil
                && audioTag(for: $0) == nil
                && seen.insert($0).inserted
        }
    }

    var body: some View {
        List {
            if !needsReview.isEmpty {
                Section {
                    ForEach(needsReview, id: \.self) { value in
                        Button {
                            guard canSelect else { return }
                            selectedLanguages.removeAll { $0 == value }
                        } label: {
                            HStack {
                                Text(value)
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSelect)
                        .accessibilityLabel("Remove saved language rule \(value)")
                    }
                } header: {
                    Text("Needs Review")
                } footer: {
                    Text("These saved rules are not recognized languages. They stay active until you remove them.")
                }
                .eclipseExperimentalSettingsRows()
            }

            if !savedVariants.isEmpty {
                Section {
                    ForEach(savedVariants) { language in
                        Button {
                            toggleLanguage(language)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                LanguageCatalogRow(
                                    language: language,
                                    isSelected: true,
                                    accent: accentColorManager.currentAccentColor
                                )
                                if hasConflict(with: language.id) {
                                    Text("Excluded languages take priority")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSelect)
                        .accessibilityIdentifier("stream-language-option-\(language.id)")
                    }
                } header: {
                    Text("Saved Language Variants")
                } footer: {
                    Text("Select a saved variant to remove it.")
                }
                .eclipseExperimentalSettingsRows()
            }

            Section {
                ForEach(visibleLanguages) { language in
                    let isSelected = selectedIDs.contains(language.id)
                    Button {
                        toggleLanguage(language)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            LanguageCatalogRow(
                                language: language,
                                isSelected: isSelected,
                                accent: accentColorManager.currentAccentColor
                            )
                            if hasConflict(with: language.id) {
                                Text("Excluded languages take priority")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSelect || (!isSelected && selectedLanguages.count >= maximumSelectionCount))
                    .accessibilityIdentifier("stream-language-option-\(language.id)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            } header: {
                Text("Languages")
            } footer: {
                Text("\(selectedLanguages.count) of \(maximumSelectionCount) rules selected. Changes save immediately.")
            }
            .eclipseExperimentalSettingsRows()

            if visibleLanguages.isEmpty,
               !savedVariants.contains(where: { $0.matches(query: searchText) }),
               visibleAudioTags.isEmpty {
                Text("No matching languages")
                    .foregroundColor(.secondary)
            }

            if !visibleAudioTags.isEmpty {
                Section {
                    ForEach(visibleAudioTags, id: \.self) { tag in
                        let isSelected = selectedLanguages.contains { audioTag(for: $0) == tag }
                        Button {
                            toggleAudioTag(tag)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(tag)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(accentColorManager.currentAccentColor)
                                    }
                                }
                                if conflictingLanguages.contains(where: { audioTag(for: $0) == tag }) {
                                    Text("Excluded audio tags take priority")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSelect || (!isSelected && selectedLanguages.count >= maximumSelectionCount))
                        .accessibilityIdentifier(tag == "Dual Audio" ? "stream-language-tag-dual" : "stream-language-tag-multi")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                } header: {
                    Text("Audio Tags")
                } footer: {
                    Text("Dual and Multi Audio describe multiple tracks without identifying their languages.")
                }
                .eclipseExperimentalSettingsRows()
            }
        }
        .searchable(text: $searchText, prompt: "Search languages or codes")
        .onChangeComp(of: searchText) { _, query in
            visibleLanguages = MediaLanguageCatalog.search(query: query)
        }
        .onAppear {
            if selectionOwner == nil { selectionOwner = LanguageSelectionOwner.capture() }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    guard canSelect else { return }
                    dismiss()
                }
                .disabled(!canSelect)
                .accessibilityIdentifier("stream-language-done")
            }
        }
        .eclipsePageTitle(title)
        .eclipseSettingsStyle()
        .preferredColorScheme(.dark)
        .tint(accentColorManager.currentAccentColor)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private func toggleLanguage(_ language: MediaLanguageCatalog.Entry) {
        guard canSelect else { return }
        if selectedIDs.contains(language.id) {
            selectedLanguages.removeAll { MediaLanguageCatalog.filterCanonicalID(for: $0) == language.id }
        } else if selectedLanguages.count < maximumSelectionCount {
            selectedLanguages.append(language.filterValue)
        }
    }

    private func toggleAudioTag(_ tag: String) {
        guard canSelect else { return }
        if selectedLanguages.contains(where: { audioTag(for: $0) == tag }) {
            selectedLanguages.removeAll { audioTag(for: $0) == tag }
        } else if selectedLanguages.count < maximumSelectionCount {
            selectedLanguages.append(tag)
        }
    }

    private func audioTag(for value: String) -> String? {
        switch AutoModeStreamSelection.normalizedStremioLanguageName(value) {
        case "Dual Audio": return "Dual Audio"
        case "Multi Audio": return "Multi Audio"
        default: return nil
        }
    }
}

private struct LanguageCatalogRow: View {
    let language: MediaLanguageCatalog.Entry
    let isSelected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(language.name)
                    .foregroundColor(.primary)
                Text(language.nativeName == language.name
                     ? language.id.uppercased()
                     : "\(language.nativeName) · \(language.id.uppercased())")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(accent)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LanguageSelectionOwner {
    let profileID: UUID
    let serviceGeneration: Int

    static func capture() -> Self {
        Self(
            profileID: ProfileManager.shared.activeProfileID,
            serviceGeneration: ServiceStoreScope.generation
        )
    }

    var isCurrent: Bool {
        ProfileManager.shared.activeProfileID == profileID
            && ServiceStoreScope.isCurrent(serviceGeneration)
    }
}

#Preview {
    NavigationView {
        PlayerLanguageSelectionView(
            title: "Default Subtitle Language",
            selectedLanguage: .constant("eng")
        )
    }
}
