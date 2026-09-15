import SwiftUI

struct ProviderNavigationContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
#if os(macOS)
        NavigationStack { content() }
#else
        NavigationView { content() }
#endif
    }
}

extension View {
    @ViewBuilder func providerNavigationStyle() -> some View {
#if os(macOS)
        self
#else
        navigationViewStyle(StackNavigationViewStyle())
#endif
    }

    @ViewBuilder func providerDecimalInput() -> some View {
#if os(macOS) || os(tvOS)
        self
#else
        keyboardType(.decimalPad)
#endif
    }

    @ViewBuilder func providerURLInput() -> some View {
#if os(macOS) || os(tvOS)
        self
#else
        keyboardType(.URL)
#endif
    }

    @ViewBuilder func providerUncapitalizedInput() -> some View {
#if os(macOS)
        self
#else
        textInputAutocapitalization(.never)
#endif
    }
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum ProviderExternalApplication {
    static func canOpen(_ url: URL) -> Bool {
#if os(macOS)
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
#else
        UIApplication.shared.canOpenURL(url)
#endif
    }

    static func open(_ url: URL) {
#if os(macOS)
        NSWorkspace.shared.open(url)
#else
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
#endif
    }

    static func copy(_ string: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
#elseif !os(tvOS)
        UIPasteboard.general.string = string
#endif
    }
}
