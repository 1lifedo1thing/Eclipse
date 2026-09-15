#if os(macOS)
import SwiftUI

struct MacReaderView: View {
    @ObservedObject var session: MacReaderSession
    private var novel: Bool { !session.pages.isEmpty && session.pages.allSatisfy(\.isText) }
    var body: some View {
        VStack(spacing: 0) {
            if session.showsControls {
            HStack(spacing: 14) {
                Button { session.close() } label: { Label("Close Reader", systemImage: "chevron.left") }
                Text(session.reader?.mangaTitle ?? "Reader").font(.headline).lineLimit(1)
                Spacer()
                if let reader = session.reader {
                    Picker("Chapter", selection: Binding(get: { reader.selectedChapter.chapterNumber }, set: { value in if let chapter = reader.chapters.first(where: { $0.chapterNumber == value }) { session.select(chapter) } })) {
                        ForEach(reader.chapters) { Text($0.chapterNumber).tag($0.chapterNumber) }
                    }.frame(maxWidth: 280)
                }
                if !novel, !session.pages.isEmpty {
                    ControlGroup {
                        Button { session.requestZoom(.decrease) } label: { Image(systemName: "minus.magnifyingglass") }.disabled(session.magnification <= 1).accessibilityLabel("Zoom Out").help("Zoom Out (⌘−)")
                        Button { session.requestZoom(.reset) } label: { Text("\(Int((session.magnification * 100).rounded()))%").monospacedDigit() }.accessibilityLabel("Reset Zoom").help("Reset Zoom (⌘0)")
                        Button { session.requestZoom(.increase) } label: { Image(systemName: "plus.magnifyingglass") }.disabled(session.magnification >= 5).accessibilityLabel("Zoom In").help("Zoom In (⌘+)")
                    }.controlSize(.small)
                    if session.settingsStore.bool(forKey: "Reader.liveText") {
                        Button { session.requestTextRecognition() } label: { Image(systemName: "text.viewfinder") }.accessibilityLabel("Recognize Text").help("Recognize Text on Current Page")
                    }
                }
                Button { session.settingsPresented = true } label: { Image(systemName: "slider.horizontal.3") }.help("Reader settings")
            }.padding(12).background(.ultraThinMaterial)
            }
            ZStack {
                if session.isLoading { ProgressView("Loading chapter…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error = session.error { ContentUnavailableView { Label("Could Not Load Chapter", systemImage: "book.closed") } description: { Text(error) } actions: {
                    Button("Retry") { session.load() }
                    if session.reader?.mangaRoute?.readerExtensionSourceID != nil, !ProfileManager.shared.isKidsModeActive { Button("Sign In to Source") { session.signInToSource() } }
                } }
                else if novel { MacReaderNovelView(session: session, settings: MacReaderSettingsSnapshot(session: session)) }
                else { MacReaderImageViewport(session: session, settings: MacReaderSettingsSnapshot(session: session)) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.showsControls {
            HStack {
                Button { session.previousChapter() } label: { Image(systemName: "backward.end") }.disabled(session.reader?.canMovePreviousChapter != true).help("Previous chapter")
                if novel {
                    Slider(value: Binding(get: { session.novelReadingProgress }, set: { session.requestNovelPosition($0) }), in: 0...1).frame(maxWidth: 380).accessibilityLabel("Reading progress")
                    Text("\(Int((session.novelReadingProgress * 100).rounded()))%").monospacedDigit().frame(minWidth: 38)
                } else {
                    Button { session.requestPageStep(-1) } label: { Image(systemName: "chevron.left") }.help("Previous page")
                    Slider(value: Binding(get: { Double(session.page) }, set: { session.page = Int($0); session.revision = UUID() }), in: 0...Double(max(1, session.pages.count - 1)), step: 1).frame(maxWidth: 380).disabled(session.pages.count < 2).accessibilityLabel("Page").accessibilityValue("\(session.page + 1) of \(session.pages.count)")
                    Text("\(session.pages.isEmpty ? 0 : session.page + 1) / \(session.pages.count)").monospacedDigit()
                    Button { session.requestPageStep(1) } label: { Image(systemName: "chevron.right") }.help("Next page")
                    Button("Retry Page") { session.requestPageRetry() }.disabled(session.isLoading || session.pages.isEmpty).help("Reload the current image page")
                }
                Button { session.nextChapter() } label: { Image(systemName: "forward.end") }.disabled(session.reader?.canMoveNextChapter != true).help("Next chapter")
                Spacer()
                Toggle("Auto Scroll", isOn: $session.autoScroll).toggleStyle(.switch).controlSize(.small).disabled(!novel && (session.reader?.mode == .ltr || session.reader?.mode == .rtl))
                if session.autoScroll { Slider(value: $session.autoScrollSpeed, in: 0.25...4).frame(width: 100).help("Auto scroll speed") }
            }.padding(12).background(.ultraThinMaterial)
            }
        }.overlay(alignment: .topTrailing) {
            if !session.showsControls { Button { session.showsControls = true } label: { Label("Show Controls", systemImage: "eye") }.padding(10).background(.regularMaterial, in: Capsule()).padding() }
        }
        .sheet(item: $session.signInPresentation) { presentation in ReaderExtensionSignInView(session: presentation.session).frame(minWidth: 720, minHeight: 600) }
        .sheet(isPresented: $session.settingsPresented) { MacReaderSettingsView(session: session).frame(width: 620, height: 720) }
    }
}
#endif
