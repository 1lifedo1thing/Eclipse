#if os(macOS)
import AppKit
import AuthenticationServices

final class MacAuthenticationPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: NSWindow

    init(window: NSWindow) {
        self.window = window
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
#endif
