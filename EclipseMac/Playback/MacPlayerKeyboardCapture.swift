#if os(macOS)
import AppKit
import SwiftUI

enum MacPlayerKeyAction: Equatable {
    case togglePlayback
    case seekBackward
    case seekForward
    case volumeUp
    case volumeDown
    case escape
}

enum MacPlayerKeyboardPolicy {
    static func action(keyCode: UInt16, isRepeat: Bool, hasShortcutModifiers: Bool,
                       inlinePlayerIsCurrent: Bool, playerHasFocus: Bool, eventTargetsKeyWindow: Bool,
                       hasChildSheet: Bool, isEditingText: Bool, sliderIsFocused: Bool) -> MacPlayerKeyAction? {
        guard inlinePlayerIsCurrent, playerHasFocus, eventTargetsKeyWindow, !hasChildSheet,
              !isEditingText, !hasShortcutModifiers else { return nil }
        switch keyCode {
        case 49: return isRepeat ? nil : .togglePlayback
        case 53: return isRepeat ? nil : .escape
        case 123: return sliderIsFocused ? nil : .seekBackward
        case 124: return sliderIsFocused ? nil : .seekForward
        case 125: return sliderIsFocused ? nil : .volumeDown
        case 126: return sliderIsFocused ? nil : .volumeUp
        default: return nil
        }
    }
}

struct MacPlayerKeyboardCapture: NSViewRepresentable {
    let isEnabled: () -> Bool
    let focusRequest: UInt64
    let sliderIsFocused: () -> Bool
    let onAction: (MacPlayerKeyAction) -> Void

    func makeNSView(context: Context) -> MacPlayerKeyboardCaptureView {
        let view = MacPlayerKeyboardCaptureView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MacPlayerKeyboardCaptureView, context: Context) {
        view.isEnabled = isEnabled
        view.sliderIsFocused = sliderIsFocused
        view.onAction = onAction
        view.updateFocusRequest(focusRequest)
    }

    static func dismantleNSView(_ view: MacPlayerKeyboardCaptureView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class MacPlayerKeyboardCaptureView: NSView {
    var isEnabled: (() -> Bool)?
    var sliderIsFocused: (() -> Bool)?
    var onAction: ((MacPlayerKeyAction) -> Void)?
    private var monitor: Any?
    private var focusWindowObservers: [NSObjectProtocol] = []
    private var focusRequest: UInt64?
    private var hasPendingFocusRequest = false
    private var focusTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Video playback")
        setAccessibilityHelp("Space plays or pauses. Left and Right seek. Up and Down adjust volume.")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled?() == true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { isEnabled?() == true }

    override func isAccessibilityEnabled() -> Bool { isEnabled?() == true }

    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }

    override func setAccessibilityFocused(_ focused: Bool) {
        if focused, isEnabled?() == true { window?.makeFirstResponder(self) }
        else if !focused, window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder else { return false }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        let shortcuts = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 48, shortcuts.isEmpty {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard window?.firstResponder === self, window?.isKeyWindow == true, isEnabled?() == true else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 7, yRadius: 7)
        outline.lineWidth = 3
        outline.stroke()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
        focusWindowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.needsDisplay = true
                    self?.scheduleFocusRequest()
                }
            }
        }
        scheduleFocusRequest()
    }

    func stop() {
        hasPendingFocusRequest = false
        focusTask?.cancel()
        focusTask = nil
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        removeObservers()
    }

    private func removeObservers() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        focusWindowObservers.forEach(NotificationCenter.default.removeObserver)
        focusWindowObservers.removeAll()
    }

    func updateFocusRequest(_ request: UInt64) {
        needsDisplay = true
        guard isEnabled?() == true else {
            focusRequest = request
            hasPendingFocusRequest = false
            focusTask?.cancel()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            return
        }
        guard focusRequest != request else { return }
        focusRequest = request
        hasPendingFocusRequest = true
        scheduleFocusRequest()
    }

    private func scheduleFocusRequest() {
        guard hasPendingFocusRequest, let window else { return }
        focusTask?.cancel()
        let request = focusRequest
        focusTask = Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard !Task.isCancelled, let self, let window, self.window === window,
                  self.focusRequest == request, self.hasPendingFocusRequest,
                  self.isEnabled?() == true, window.isKeyWindow, window.isVisible,
                  window.attachedSheet == nil else { return }
            self.hasPendingFocusRequest = false
            window.makeFirstResponder(self)
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard [49, 53, 123, 124, 125, 126].contains(event.keyCode) else { return false }
        let window = window
        let responder = window?.firstResponder
        let editing = responder is NSTextView || responder is NSTextField
        let nativeSlider = (responder as? NSView)?.accessibilityRole() == .slider
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let tracking = RunLoop.current.currentMode == .eventTracking
        let enabled = isEnabled?() == true
        let focused = responder === self || sliderIsFocused?() == true
        let targetsKeyWindow = window != nil && event.window === window
            && window?.isKeyWindow == true && window?.isVisible == true && NSApp.isActive
        let hasSheet = window?.attachedSheet != nil
        let sliderFocused = sliderIsFocused?() == true || nativeSlider
        let action = tracking ? nil : MacPlayerKeyboardPolicy.action(keyCode: event.keyCode, isRepeat: event.isARepeat,
            hasShortcutModifiers: !modifiers.isEmpty,
            inlinePlayerIsCurrent: enabled, playerHasFocus: focused,
            eventTargetsKeyWindow: targetsKeyWindow, hasChildSheet: hasSheet, isEditingText: editing,
            sliderIsFocused: sliderFocused)
#if DEBUG
        let responderType = responder.map { String(describing: type(of: $0)) } ?? "none"
        Logger.shared.log("MacPlayerKey key=\(event.keyCode) repeat=\(event.isARepeat) eventWindow=\(event.windowNumber) playerWindow=\(window?.windowNumber ?? 0) keyWindow=\(window?.isKeyWindow == true) visible=\(window?.isVisible == true) active=\(NSApp.isActive) runLoop=\(RunLoop.current.currentMode?.rawValue ?? "none") text=\(editing) playerFocus=\(focused) slider=\(sliderFocused) enabled=\(enabled) sheet=\(hasSheet) tracking=\(tracking) modified=\(!modifiers.isEmpty) responder=\(responderType) accepted=\(action != nil)", type: "PlaybackTrace")
#endif
        guard let action else { return false }
        onAction?(action)
        return true
    }
}
#endif
