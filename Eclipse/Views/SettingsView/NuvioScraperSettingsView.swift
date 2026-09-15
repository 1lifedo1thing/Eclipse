import SwiftUI

#if (os(iOS) && !targetEnvironment(macCatalyst)) || os(tvOS) || os(macOS)
struct NuvioScraperSettingsView: View {
    let scraper: NuvioPluginScraper
    @ObservedObject var manager: NuvioPluginManager
    @StateObject private var accentColorManager = AccentColorManager.shared
    @StateObject private var profileManager = ProfileManager.shared

    @State private var fields: [NuvioSettingsField] = []
    @State private var isLoading = true
    @State private var loadError: String?

    private var accent: Color { accentColorManager.currentAccentColor }
    private var canAdminister: Bool { profileManager.rosterStoreIsReadable && profileManager.activeProfile?.isKidsProfile == false }

    var body: some View {
        Group {
#if os(tvOS)
            tvContent
#else
            ScrollView {
                VStack(spacing: 22) {
                    if isLoading {
                        loadingSection
                    } else if let loadError {
                        messageSection(
                            icon: "exclamationmark.triangle.fill",
                            color: .orange,
                            title: "Couldn't Load Settings",
                            message: loadError
                        )
                    } else if fields.isEmpty {
                        messageSection(
                            icon: "slider.horizontal.3",
                            color: .secondary,
                            title: "No Settings Available",
                            message: "This provider does not expose any configurable options."
                        )
                    } else {
                        fieldSections
                            .disabled(!canAdminister)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
                .background(EclipseScrollTracker())
            }
#endif
        }
        .eclipsePageTitle(scraper.name)
#if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .task(id: profileManager.activeProfileID) { await loadFields() }
    }

#if os(tvOS)
    private var tvContent: some View {
        Form {
            Section("Provider") {
                Toggle("Enabled", isOn: Binding(
                    get: { manager.scraper(withID: scraper.id)?.isRunnable ?? false },
                    set: {
                        guard canAdminister else { return }
                        manager.setScraperEnabled(scraper.id, enabled: $0)
                    }
                ))
                .disabled(!canAdminister || manager.scraper(withID: scraper.id)?.manifestEnabled != true)
            }
            .eclipseExperimentalSettingsRows()
            if isLoading {
                Section { ProgressView("Reading provider settings…") }
            } else if let loadError {
                Section("Couldn't Load Settings") {
                    Text(loadError)
                    Button("Retry") { Task { await loadFields() } }
                        .disabled(!canAdminister)
                }
            } else if fields.isEmpty {
                Section { Text("This provider does not expose any configurable options.") }
            } else {
                ForEach(Array(groupedFields.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.fields) { field in tvField(field) }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                    .eclipseExperimentalSettingsRows()
                    .disabled(!canAdminister)
                }
            }
        }
        .eclipseSettingsStyle()
        .accessibilityIdentifier("tv.nuvio.providerSettings")
    }

    @ViewBuilder
    private func tvField(_ field: NuvioSettingsField) -> some View {
        switch field.kind {
        case .header:
            EmptyView()
        case .toggle:
            Toggle(field.label, isOn: Binding(
                get: { boolValue(for: field) },
                set: {
                    guard canAdminister else { return }
                    manager.setSettingsValue(.bool($0), forKey: field.key, scraperID: scraper.id)
                }
            ))
        case .select:
            Picker(field.label, selection: Binding(
                get: { stringValue(for: field) },
                set: {
                    guard canAdminister else { return }
                    manager.setSettingsValue(.string($0), forKey: field.key, scraperID: scraper.id)
                }
            )) {
                ForEach(field.options) { option in
                    Text(option.label).tag(option.value)
                }
            }
        case .text:
            TextField(field.label, text: Binding(
                get: { stringValue(for: field) },
                set: {
                    guard canAdminister else { return }
                    manager.setSettingsValue(.string($0), forKey: field.key, scraperID: scraper.id)
                }
            ))
            .providerUncapitalizedInput()
            .autocorrectionDisabled()
            .privacySensitive()
        }
    }
#endif

    private var loadingSection: some View {
        GlassSection {
            HStack(spacing: 12) {
                ProgressView().progressViewStyle(.circular).tint(accent)
                Text("Reading provider settings…")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
            }
            .padding(16)
        }
    }

    private func messageSection(icon: String, color: Color, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            GlassSection {
                VStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 28))
                        .foregroundColor(color)
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var fieldSections: some View {
        ForEach(Array(groupedFields.enumerated()), id: \.offset) { _, group in
            GlassSection(header: group.title) {
                VStack(spacing: 0) {
                    ForEach(Array(group.fields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 { GlassDivider(leadingInset: 16) }
                        row(for: field)
                    }
                }
            }
        }
    }

    private struct FieldGroup {
        let title: String?
        let fields: [NuvioSettingsField]
    }

    private var groupedFields: [FieldGroup] {
        var groups: [FieldGroup] = []
        var currentTitle: String?
        var current: [NuvioSettingsField] = []

        for field in fields {
            if field.kind == .header {
                if !current.isEmpty {
                    groups.append(FieldGroup(title: currentTitle, fields: current))
                    current = []
                }
                currentTitle = field.label
            } else {
                current.append(field)
            }
        }
        if !current.isEmpty {
            groups.append(FieldGroup(title: currentTitle, fields: current))
        }
        return groups
    }

    @ViewBuilder
    private func row(for field: NuvioSettingsField) -> some View {
        switch field.kind {
        case .header:
            EmptyView()
        case .toggle:
            GlassDetailRow(icon: "switch.2", iconColor: .mint, title: field.label) {
                Toggle("", isOn: Binding(
                    get: { boolValue(for: field) },
                    set: { manager.setSettingsValue(.bool($0), forKey: field.key, scraperID: scraper.id) }
                ))
                .labelsHidden()
                .tint(accent)
            }
        case .select:
            GlassDetailRow(icon: "list.bullet", iconColor: .purple, title: field.label) {
                Menu {
                    ForEach(field.options) { option in
                        Button {
                            manager.setSettingsValue(.string(option.value), forKey: field.key, scraperID: scraper.id)
                        } label: {
                            if stringValue(for: field) == option.value {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    Text(selectedOptionLabel(for: field))
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        case .text:
            GlassDetailRow(icon: "textformat", iconColor: .cyan, title: field.label) {
                TextField("", text: Binding(
                    get: { stringValue(for: field) },
                    set: { manager.setSettingsValue(.string($0), forKey: field.key, scraperID: scraper.id) }
                ))
                .multilineTextAlignment(.trailing)
                .providerUncapitalizedInput()
                .autocorrectionDisabled()
                .foregroundColor(.white)
                .tint(accent)
                .frame(maxWidth: 180)
            }
        }
    }

    private func boolValue(for field: NuvioSettingsField) -> Bool {
        if let stored = manager.settingsValues(scraperID: scraper.id)[field.key] {
            return stored.boolValue
        }
        return field.defaultValue?.boolValue ?? false
    }

    private func stringValue(for field: NuvioSettingsField) -> String {
        if let stored = manager.settingsValues(scraperID: scraper.id)[field.key] {
            return stored.stringValue
        }
        return field.defaultValue?.stringValue ?? ""
    }

    private func selectedOptionLabel(for field: NuvioSettingsField) -> String {
        let value = stringValue(for: field)
        if let match = field.options.first(where: { $0.value == value }) {
            return match.label
        }
        return value.isEmpty ? "Not Set" : value
    }

    private func loadFields() async {
        let generation = ServiceStoreScope.generation
        isLoading = true
        loadError = nil
        fields = []
        guard canAdminister else {
            loadError = "Switch to a grown-up profile to configure this provider."
            isLoading = false
            return
        }
        do {
            let loaded = try await manager.settingsFields(scraperID: scraper.id)
            guard !Task.isCancelled, ServiceStoreScope.isCurrent(generation), canAdminister else { return }
            fields = loaded
        } catch {
            guard !Task.isCancelled, ServiceStoreScope.isCurrent(generation), canAdminister else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
#endif
