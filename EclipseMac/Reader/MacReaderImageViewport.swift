#if os(macOS)
import AppKit
import SwiftUI
import Vision

struct MacReaderImageViewport: NSViewRepresentable {
    @ObservedObject var session: MacReaderSession
    let settings: MacReaderSettingsSnapshot
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> MacReaderScrollView {
        let scroll = MacReaderScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 5
        scroll.drawsBackground = true
        let document = MacReaderCanvas()
        document.wantsLayer = true
        document.coordinator = context.coordinator
        document.setAccessibilityElement(true)
        document.setAccessibilityRole(.group)
        document.setAccessibilityLabel("Reader pages")
        scroll.documentView = document
        scroll.readerCoordinator = context.coordinator
        context.coordinator.scroll = scroll
        context.coordinator.canvas = document
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in MainActor.assumeIsolated { coordinator?.viewportChanged() } }
        context.coordinator.update(settings: settings)
        return scroll
    }
    func updateNSView(_ scroll: MacReaderScrollView, context: Context) { context.coordinator.update(settings: settings) }
    static func dismantleNSView(_ scroll: MacReaderScrollView, coordinator: Coordinator) { coordinator.close() }

    struct DisplayPage {
        let source: Int
        let half: Int?
        var frame: CGRect
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var session: MacReaderSession?
        weak var scroll: MacReaderScrollView?
        weak var canvas: MacReaderCanvas?
        var observer: NSObjectProtocol?
        private(set) var settings: MacReaderSettingsSnapshot?
        private(set) var display: [DisplayPage] = []
        private(set) var images: [Int: CGImage] = [:]
        private(set) var errors: [Int: String] = [:]
        private var ratios: [Int: CGFloat] = [:]
        private var tasks: [Int: Task<Void, Never>] = [:]
        private var pages: [KanzenReaderPage] = []
        private var identity = ""
        private var generation = UUID()
        private var revision = UUID()
        private var pageCommandID: UUID?
        private var zoomCommandID: UUID?
        private var recognitionCommandID: UUID?
        private var retryCommandID: UUID?
        private var contentGeneration: UUID?
        private var windowGeneration = MacLaunchProfileAccess.windowGeneration
        private var closed = false
        private var currentDisplay = 0
        private var viewport = CGSize.zero
        private var reflowing = false
        private var timer: Timer?
        private var autoScroll = false
        private var popover: NSPopover?
        private var savePanel: NSSavePanel?
        private var positionTask: Task<Void, Never>?
        private var reportedPosition: (page: Int, completion: Double)?
        var isPaged: Bool { settings?.mode == .ltr || settings?.mode == .rtl }
        var background: NSColor {
            switch settings?.background {
            case "white": return .white
            case "gray": return .darkGray
            case "system": return .textBackgroundColor
            case "auto": return usesLightBackground ? .white : .black
            default: return NSColor(srgbRed: 0.055, green: 0.050, blue: 0.090, alpha: 1)
            }
        }
        var usesLightBackground: Bool {
            if settings?.background == "white" { return true }
            guard settings?.background == "system" || settings?.background == "auto" else { return false }
            return scroll?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
        }
        init(session: MacReaderSession) { self.session = session }

        func close() {
            closed = true
            generation = UUID()
            let panel = savePanel
            savePanel = nil
            panel?.cancel(nil)
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            positionTask?.cancel()
            positionTask = nil
            timer?.invalidate()
            timer = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            popover?.close()
            images.removeAll()
            canvas?.coordinator = nil
            scroll?.readerCoordinator = nil
        }

        func update(settings: MacReaderSettingsSnapshot) {
            guard !closed, let session, let scroll else { return }
            let newIdentity = "\(session.owner):\(session.reader?.selectedChapter.id.uuidString ?? ""):\(session.pages.first?.id ?? "")"
            let sameChapter = newIdentity == identity
            let changed = self.settings != settings
            self.settings = settings
            scroll.backgroundColor = background
            scroll.hasVerticalScroller = !isPaged
            if newIdentity != identity || changed {
                generation = UUID()
                tasks.values.forEach { $0.cancel() }
                tasks.removeAll()
                images.removeAll()
                errors.removeAll()
                reportedPosition = nil
                if newIdentity != identity { ratios.removeAll(); scroll.magnification = 1 }
                identity = newIdentity
                contentGeneration = session.contentGeneration
                windowGeneration = MacLaunchProfileAccess.windowGeneration
                pages = session.pages
                rebuild(keepingAnchor: sameChapter && !pages.isEmpty)
                scrollToSource(session.page)
            }
            if revision != session.revision {
                revision = session.revision
                scrollToSource(session.page)
            }
            if let command = session.pageCommand, command.id != pageCommandID {
                pageCommandID = command.id
                advance(command.delta)
            }
            if let command = session.zoomCommand, command.id != zoomCommandID {
                zoomCommandID = command.id
                zoom(command.action)
            }
            if let command = session.retryPageCommand, command.id != retryCommandID {
                retryCommandID = command.id
                retry(command)
            }
            if autoScroll != session.autoScroll {
                autoScroll = session.autoScroll
                timer?.invalidate()
                timer = nil
                if autoScroll {
                    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, let session = self.session, !self.isPaged else { return }
                            self.scrollBy(session.autoScrollSpeed * 2, permitsChapterChange: true)
                        }
                    }
                }
            }
            viewportChanged()
        }

        func resized() {
            guard let scroll, scroll.contentSize.width > 0, scroll.contentSize != viewport else { return }
            rebuild(keepingAnchor: true)
        }

        private var columns: Int {
            guard let settings, isPaged else { return 1 }
            return settings.layout == "double" || (settings.layout == "auto" && viewport.width > viewport.height * 1.1) ? 2 : 1
        }

        private func rebuild(keepingAnchor: Bool) {
            guard let scroll, let canvas, let settings, !reflowing else { return }
            reflowing = true
            defer { reflowing = false }
            let visibleY = scroll.contentView.bounds.minY
            let anchor = display.first(where: { $0.frame.maxY > visibleY })
            let selectedAnchor = display.indices.contains(currentDisplay) ? display[currentDisplay] : nil
            let fraction = anchor.map { (visibleY - $0.frame.minY) / max(1, $0.frame.height) } ?? 0
            viewport = scroll.contentSize
            let hasMargins = settings.pillarboxOrientation == "both" || (settings.pillarboxOrientation == "portrait" && viewport.height > viewport.width) || (settings.pillarboxOrientation == "landscape" && viewport.width >= viewport.height)
            let width = max(viewport.width * (1 - (hasMargins ? settings.pillarbox : 0) / 100), 100)
            var next: [DisplayPage] = []
            for index in pages.indices {
                let split = settings.split && (ratios[index] ?? 0.7) > 1
                let halves: [Int?] = split ? (settings.reverseSplit ? [1, 0] : [0, 1]) : [nil]
                for half in halves { next.append(DisplayPage(source: index, half: half, frame: .zero)) }
            }
            display = next
            currentDisplay = min(currentDisplay, max(0, display.count - 1))
            if keepingAnchor, let selectedAnchor, let replacement = display.firstIndex(where: { $0.source == selectedAnchor.source && ($0.half == selectedAnchor.half || selectedAnchor.half == nil) }) { currentDisplay = replacement }
            if isPaged {
                let group = MacReaderLayoutPolicy.group(containing: currentDisplay, count: display.count, columns: columns, offsetFirstPage: settings.offset)
                let visibleColumns = max(1, group.count)
                let perPageWidth = width / CGFloat(visibleColumns)
                let groupStart = group.lowerBound
                for index in display.indices {
                    let position = index - groupStart
                    guard group.contains(index) else { continue }
                    let page = display[index]
                    let ratio = (ratios[page.source] ?? 0.7) / (page.half == nil ? 1 : 2)
                    let fittedWidth = min(perPageWidth, max(viewport.height, 100) * ratio)
                    let fittedHeight = fittedWidth / max(ratio, 0.01)
                    let column = settings.mode == .rtl ? visibleColumns - 1 - position : position
                    display[index].frame = CGRect(x: (viewport.width - width) / 2 + CGFloat(column) * perPageWidth + (perPageWidth - fittedWidth) / 2, y: max(0, (viewport.height - fittedHeight) / 2), width: fittedWidth, height: fittedHeight)
                }
                canvas.frame = CGRect(origin: .zero, size: CGSize(width: max(viewport.width, 1), height: max(viewport.height, 1)))
            } else {
                var y: CGFloat = 0
                for index in display.indices {
                    let page = display[index]
                    let ratio = (ratios[page.source] ?? 0.7) / (page.half == nil ? 1 : 2)
                    let height = settings.mode == .vertical ? min(width / max(ratio, 0.01), max(viewport.height, 100)) : width / max(ratio, 0.01)
                    let pageWidth = min(width, height * ratio)
                    display[index].frame = CGRect(x: (viewport.width - pageWidth) / 2, y: y, width: pageWidth, height: height)
                    y += height + (settings.mode == .vertical ? 12 : 0)
                }
                canvas.frame = CGRect(x: 0, y: 0, width: max(viewport.width, 1), height: max(viewport.height, y + 40))
                if keepingAnchor, let anchor, let replacement = display.first(where: { $0.source == anchor.source && $0.half == anchor.half }) {
                    scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: max(0, replacement.frame.minY + replacement.frame.height * fraction)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            canvas.needsDisplay = true
        }

        func viewportChanged() {
            guard !closed, !reflowing, let scroll, let settings, !pages.isEmpty else { return }
            let visible = scroll.contentView.bounds
            let indices: [Int]
            if isPaged { indices = display.indices.filter { !display[$0].frame.isEmpty } }
            else { indices = display.indices.filter { display[$0].frame.intersects(visible) } }
            guard let first = indices.first else { return }
            if !isPaged { currentDisplay = first }
            let source = display[first].source
            let completion = Double((indices.last ?? first) + 1) / Double(max(display.count, 1))
            let magnification = Double(scroll.magnification)
            if reportedPosition?.page != source || reportedPosition?.completion != completion || session?.magnification != magnification {
                positionTask?.cancel()
                let token = generation
                positionTask = Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled, token == self.generation else { return }
                    self.reportedPosition = (source, completion)
                    self.session?.magnification = magnification
                    self.session?.positionChanged(page: source, completion: completion)
                    self.positionTask = nil
                }
            }
            canvas?.setAccessibilityValue("Page \(source + 1) of \(pages.count). \(settings.mode.title).")
            let lower = max(0, first - settings.preload)
            let upper = min(display.count - 1, (indices.last ?? first) + settings.preload)
            let desired = Set(display[lower...upper].prefix(32).map(\.source))
            for index in Array(tasks.keys) where !desired.contains(index) { tasks[index]?.cancel(); tasks[index] = nil }
            for index in Array(images.keys) where !desired.contains(index) { images[index] = nil }
            for index in desired where images[index] == nil && tasks[index] == nil && errors[index] == nil { load(index) }
            if let command = session?.textRecognitionCommand, command.id != recognitionCommandID,
               command.contentGeneration == contentGeneration, images[command.page] != nil, settings.liveText {
                recognitionCommandID = command.id
                recognizeText(at: command.page)
            }
            canvas?.needsDisplay = true
        }

        private func load(_ index: Int) {
            guard pages.indices.contains(index), let settings, let session else { return }
            let page = pages[index].pageData
            let scope = session.owner
            let storageLocation = session.offlineLease?.location
            let generation = self.generation
            let width = max(900, viewport.width * (scroll?.window?.backingScaleFactor ?? 2))
            let request: ReaderPinnedImageRequest?
            do { request = page.urlString == nil ? nil : try ReaderPageImageOptions.request(for: page, targetSize: CGSize(width: width, height: width * 2), scaleFactor: 1) }
            catch { errors[index] = error.localizedDescription; return }
            tasks[index] = Task { [weak self] in
                do {
                    let image = try await MacReaderImagePipeline.shared.image(page: page, request: request, settings: settings, width: width, scope: scope, storageLocation: storageLocation)
                    try Task.checkCancellation()
                    guard let self, self.generation == generation else { return }
                    self.tasks[index] = nil
                    self.images[index] = image
                    let ratio = CGFloat(image.width) / CGFloat(max(image.height, 1))
                    if self.ratios[index] != ratio { self.ratios[index] = ratio; self.rebuild(keepingAnchor: true) }
                    self.viewportChanged()
                } catch {
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    self.tasks[index] = nil
                    self.errors[index] = "Page \(index + 1) could not load. Use Retry Page."
                    self.canvas?.needsDisplay = true
                }
            }
        }

        func scrollToSource(_ source: Int) {
            guard let index = display.firstIndex(where: { $0.source == source }) else { return }
            currentDisplay = index
            if isPaged { rebuild(keepingAnchor: false) }
            else if let scroll { scroll.contentView.scroll(to: CGPoint(x: 0, y: display[index].frame.minY)); scroll.reflectScrolledClipView(scroll.contentView) }
            viewportChanged()
        }

        func advance(_ delta: Int) {
            let candidate = isPaged ? MacReaderLayoutPolicy.adjacentIndex(from: currentDisplay, direction: delta, count: display.count, columns: columns, offsetFirstPage: settings?.offset == true) : currentDisplay + delta
            guard let destination = candidate, display.indices.contains(destination) else { if delta > 0 { session?.nextChapter() } else { session?.previousChapter() }; return }
            currentDisplay = destination
            if isPaged {
                rebuild(keepingAnchor: false)
                viewportChanged()
                if settings?.animatePageTurns == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let animation = CATransition()
                    animation.type = .fade
                    animation.duration = 0.18
                    canvas?.layer?.add(animation, forKey: "readerPageTurn")
                }
            }
            else if let scroll { scroll.contentView.scroll(to: CGPoint(x: 0, y: display[destination].frame.minY)); scroll.reflectScrolledClipView(scroll.contentView); viewportChanged() }
        }

        func scrollBy(_ delta: CGFloat, permitsChapterChange: Bool) {
            guard let scroll, let canvas else { return }
            let maxY = max(0, canvas.frame.height - scroll.contentView.bounds.height)
            let old = scroll.contentView.bounds.minY
            if permitsChapterChange, settings?.infiniteScroll == true, delta > 0, old >= maxY - 1 { session?.nextChapter(); return }
            scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: min(max(old + delta, 0), maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
            viewportChanged()
        }

        func key(_ event: NSEvent) -> Bool {
            guard hasCurrentInputSession, let responder = scroll?.window?.firstResponder,
                  responder === scroll || responder === canvas,
                  event.modifierFlags.intersection([.option, .control]).isEmpty else { return false }
            let command = event.modifierFlags.contains(.command)
            if command {
                switch event.charactersIgnoringModifiers {
                case "+", "=": zoom(.increase); return true
                case "-": zoom(.decrease); return true
                case "0": zoom(.reset); return true
                default: break
                }
            }
            switch event.keyCode {
            case 123: if command { session?.previousChapter() } else { advance(settings?.mode == .rtl ? 1 : -1) }
            case 124: if command { session?.nextChapter() } else { advance(settings?.mode == .rtl ? -1 : 1) }
            case 125, 121: if isPaged { advance(1) } else { scrollBy(viewport.height * 0.9, permitsChapterChange: true) }
            case 126, 116: if isPaged { advance(-1) } else { scrollBy(-viewport.height * 0.9, permitsChapterChange: false) }
            case 49: let delta: CGFloat = event.modifierFlags.contains(.shift) ? -1 : 1; if isPaged { advance(Int(delta)) } else { scrollBy(delta * viewport.height * 0.9, permitsChapterChange: true) }
            case 53: if scroll?.magnification ?? 1 > 1 { scroll?.magnification = 1 } else { session?.close() }
            default: return false
            }
            return true
        }

        private var hasCurrentInputSession: Bool {
            guard !closed, let session, !session.isLoading, session.reader != nil, !pages.isEmpty,
                  session.contentGeneration == contentGeneration, session.owner == ProfileManager.shared.activeProfileID,
                  windowGeneration == MacLaunchProfileAccess.windowGeneration, scroll?.window != nil,
                  !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating,
                  ProfileManager.shared.rosterStoreIsReadable else { return false }
            return true
        }

        func handleWheel(_ event: NSEvent) -> Bool {
            guard hasCurrentInputSession, let session, let scroll, let canvas else { return false }
            let atEnd = scroll.contentView.bounds.maxY >= canvas.frame.maxY - 1
            let magnified = scroll.magnification > 1.01
            let modified = !event.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty
            let step = session.wheelNavigation.consume(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas, began: event.phase.contains(.began), momentum: !event.momentumPhase.isEmpty, timestamp: event.timestamp, paged: isPaged, rightToLeft: settings?.mode == .rtl, atEnd: atEnd, continuationEnabled: settings?.infiniteScroll == true, magnified: magnified, modified: modified)
            if let step, hasCurrentInputSession {
                if isPaged { advance(step) }
                else if atEnd, settings?.infiniteScroll == true, session.reader?.canMoveNextChapter == true { session.nextChapter() }
            }
            return isPaged && !magnified && !modified
        }

        private func zoom(_ action: MacReaderZoomCommand.Action) {
            guard hasCurrentInputSession, let scroll else { return }
            let target: CGFloat
            switch action {
            case .increase: target = min(scroll.maxMagnification, scroll.magnification * 1.25)
            case .decrease: target = max(scroll.minMagnification, scroll.magnification / 1.25)
            case .reset: target = 1
            }
            let visible = scroll.contentView.bounds
            scroll.setMagnification(target, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
            viewportChanged()
        }

        func userScrolled() {
            if settings?.hideControlsOnScroll == true, session?.showsControls == true { session?.showsControls = false }
        }

        func doubleClick(at point: NSPoint) {
            guard settings?.doubleClickZoom == true, let scroll else { return }
            scroll.setMagnification(scroll.magnification > 1 ? 1 : 2, centeredAt: point)
            viewportChanged()
        }

        func menu(at point: NSPoint) -> NSMenu? {
            guard settings?.quickActions == true, let index = display.firstIndex(where: { $0.frame.contains(point) }) else { return nil }
            let source = display[index].source
            let menu = NSMenu()
            for (title, action) in [("Copy Image", #selector(copyImage(_:))), ("Save Image…", #selector(saveImage(_:))), ("Retry Page", #selector(retryPage(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.tag = source
                if action == #selector(retryPage(_:)), let session { item.representedObject = MacReaderRetryPageCommand(page: source, contentGeneration: session.contentGeneration) }
                item.isEnabled = action == #selector(retryPage(_:)) || images[source] != nil
                menu.addItem(item)
            }
            if settings?.liveText == true {
                let item = NSMenuItem(title: "Recognize Text…", action: #selector(recognizeText(_:)), keyEquivalent: "")
                item.target = self; item.tag = source; item.isEnabled = images[source] != nil; menu.addItem(item)
            }
            return menu
        }
        @objc private func retryPage(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? MacReaderRetryPageCommand else { return }
            retry(command)
        }
        private func retry(_ command: MacReaderRetryPageCommand) {
            guard hasCurrentInputSession, command.contentGeneration == session?.contentGeneration, pages.indices.contains(command.page) else { return }
            tasks[command.page]?.cancel()
            tasks[command.page] = nil
            errors[command.page] = nil
            images[command.page] = nil
            viewportChanged()
        }
        @objc private func copyImage(_ sender: NSMenuItem) {
            guard let image = images[sender.tag] else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
        }
        @objc private func saveImage(_ sender: NSMenuItem) {
            guard savePanel == nil, let image = images[sender.tag], let session,
                  let authority = MacDownloadStorageAuthority.capture(), authority.profileID == session.owner,
                  NSApp.isActive, let window = scroll?.window, window.isVisible, !window.isMiniaturized else { return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "page-\(sender.tag + 1).png"; panel.allowedContentTypes = [.png]
            let token = generation
            let contentGeneration = session.contentGeneration
            let windowGeneration = MacLaunchProfileAccess.windowGeneration
            savePanel = panel
            panel.beginSheetModal(for: window) { [weak self, weak window] response in
                guard let self, self.savePanel === panel else { return }
                self.savePanel = nil
                guard response == .OK, token == self.generation, self.session === session,
                      contentGeneration == session.contentGeneration, windowGeneration == MacLaunchProfileAccess.windowGeneration,
                      authority.isCurrent(), authority.profileID == session.owner, NSApp.isActive,
                      let window, window.isVisible, !window.isMiniaturized, self.scroll?.window === window, let url = panel.url else { return }
                do { guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }; try data.write(to: url, options: .atomic) }
                catch { session.error = error.localizedDescription }
            }
        }
        @objc private func recognizeText(_ sender: NSMenuItem) {
            recognizeText(at: sender.tag)
        }
        private func recognizeText(at page: Int) {
            guard hasCurrentInputSession, let image = images[page], let session,
                  let authority = ProgressManager.shared.profileMutationAuthority(requiredOwner: session.owner),
                  let window = canvas?.window, window.isVisible, !window.isMiniaturized, NSApp.isActive else { return }
            let token = generation
            let contentGeneration = session.contentGeneration
            let windowGeneration = MacLaunchProfileAccess.windowGeneration
            Task { [weak self] in
                do {
                    let text = try await Task.detached(priority: .userInitiated) {
                        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                        try VNImageRequestHandler(cgImage: image).perform([request])
                        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                    }.value
                    guard let self, self.generation == token, self.session === session,
                          session.contentGeneration == contentGeneration, self.hasCurrentInputSession,
                          windowGeneration == MacLaunchProfileAccess.windowGeneration,
                          ProgressManager.shared.profileMutationAuthorityIsCurrent(authority),
                          let canvas = self.canvas, canvas.window === window, window.isVisible, !window.isMiniaturized, NSApp.isActive else { return }
                    let popover = NSPopover(); popover.behavior = .transient
                    popover.contentViewController = NSHostingController(rootView: ScrollView { Text(text.isEmpty ? "No text recognized." : text).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading) }.frame(width: 400, height: 350))
                    self.popover = popover
                    popover.show(relativeTo: canvas.visibleRect, of: canvas, preferredEdge: .maxX)
                } catch {
                    if let self, self.generation == token, self.hasCurrentInputSession,
                       session.contentGeneration == contentGeneration, ProgressManager.shared.profileMutationAuthorityIsCurrent(authority) {
                        self.session?.error = error.localizedDescription
                    }
                }
            }
        }
    }
}

final class MacReaderScrollView: NSScrollView {
    weak var readerCoordinator: MacReaderImageViewport.Coordinator?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if readerCoordinator?.key(event) != true { super.keyDown(with: event) } }
    override func scrollWheel(with event: NSEvent) {
        readerCoordinator?.userScrolled()
        if readerCoordinator?.handleWheel(event) != true { super.scrollWheel(with: event) }
    }
    override func layout() { super.layout(); readerCoordinator?.resized() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let readerCoordinator { backgroundColor = readerCoordinator.background; documentView?.needsDisplay = true; needsDisplay = true }
    }
}

final class MacReaderCanvas: NSView {
    weak var coordinator: MacReaderImageViewport.Coordinator?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if coordinator?.key(event) != true { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { coordinator?.doubleClick(at: convert(event.locationInWindow, from: nil)) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { coordinator?.menu(at: convert(event.locationInWindow, from: nil)) }
    override func draw(_ dirtyRect: NSRect) {
        guard let coordinator else { return }
        coordinator.background.setFill(); dirtyRect.fill()
        for page in coordinator.display where !page.frame.isEmpty && page.frame.intersects(dirtyRect) {
            if let image = coordinator.images[page.source] {
                let source: CGRect
                if let half = page.half { source = CGRect(x: CGFloat(half) * CGFloat(image.width) / 2, y: 0, width: CGFloat(image.width) / 2, height: CGFloat(image.height)) }
                else { source = CGRect(x: 0, y: 0, width: image.width, height: image.height) }
                NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)).draw(in: page.frame, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            } else {
                let text = coordinator.errors[page.source] ?? "Loading page \(page.source + 1)…"
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: coordinator.usesLightBackground ? NSColor.darkGray : NSColor.lightGray]
                (text as NSString).draw(in: CGRect(x: page.frame.minX + 20, y: page.frame.minY + min(page.frame.height / 2, 200), width: page.frame.width - 40, height: 80), withAttributes: attributes)
            }
        }
    }
}
#endif
