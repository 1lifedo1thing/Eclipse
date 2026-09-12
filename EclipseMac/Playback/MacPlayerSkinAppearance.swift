#if os(macOS)
import AppKit
import SwiftUI

struct MacPlayerSkinAppearance {
    let skin: MPVPlayerSkin
    let primary: Color
    let secondary: Color
    let controlsOnly: Bool
    let animationsEnabled: Bool
    let animationStyle: MPVPlayerSkinAnimationStyle

    init(engine: PlaybackEngine, defaults: UserDefaults = ProfileSettingsStore.active) {
        skin = engine == .mpv ? MPVPlayerSkinSettings.selected(defaults: defaults) : .defaultSkin
        controlsOnly = MPVPlayerSkinSettings.tintControlsOnly(defaults: defaults)
        animationsEnabled = MPVPlayerSkinSettings.animationsEnabled(defaults: defaults)
        animationStyle = MPVPlayerSkinSettings.animationStyle(for: skin, defaults: defaults)
        switch skin {
        case .defaultSkin:
            primary = .white
            secondary = .white
        case .blackAndGold:
            primary = Color(red: 0.92, green: 0.73, blue: 0.27)
            secondary = Color(red: 1, green: 0.91, blue: 0.61)
        case .prismatic:
            primary = Color(red: 0.48, green: 0.94, blue: 1)
            secondary = Color(red: 0.98, green: 0.39, blue: 0.84)
        case .cyberpunk:
            primary = Color(red: 0.10, green: 0.95, blue: 1)
            secondary = Color(red: 1, green: 0.18, blue: 0.72)
        case .custom:
            primary = Self.color(for: MPVPlayerSkinSettings.customPrimaryColorKey, defaults: defaults,
                fallback: Color(red: 0.20, green: 0.86, blue: 1))
            secondary = Self.color(for: MPVPlayerSkinSettings.customSecondaryColorKey, defaults: defaults,
                fallback: Color(red: 0.72, green: 0.31, blue: 1))
        }
    }

    private static func color(for key: String, defaults: UserDefaults, fallback: Color) -> Color {
        guard let data = defaults.data(forKey: key),
              let value = try? PortableColorArchive.color(from: data) else { return fallback }
        return Color(nsColor: value)
    }
}

struct MacPlayerSkinBackground: View {
    let appearance: MacPlayerSkinAppearance
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animated = isActive && appearance.animationsEnabled && !reduceMotion
            && appearance.skin != .defaultSkin && !appearance.controlsOnly
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !animated)) { context in
            let phase = animated ? context.date.timeIntervalSinceReferenceDate / 6 : 0
            let drift = (sin(phase) + 1) / 2
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                if appearance.skin != .defaultSkin, !appearance.controlsOnly {
                    appearance.secondary.opacity(0.15)
                    switch appearance.animationStyle {
                    case .glow:
                        appearance.primary.opacity(0.04 + drift * 0.08)
                    case .spectrum:
                        AngularGradient(colors: [appearance.primary, .purple, appearance.secondary, .cyan,
                            appearance.primary], center: .center)
                            .opacity(0.12).hueRotation(.degrees(drift * 55))
                    case .sweep:
                        GeometryReader { geometry in
                            LinearGradient(colors: [.clear, appearance.primary.opacity(0.2), .clear],
                                startPoint: .leading, endPoint: .trailing)
                                .frame(width: geometry.size.width * 0.4)
                                .offset(x: geometry.size.width * (drift * 1.4 - 0.4))
                        }
                    case .aurora:
                        LinearGradient(colors: [appearance.primary.opacity(0.18), .clear,
                            appearance.secondary.opacity(0.18)],
                            startPoint: UnitPoint(x: drift, y: 0), endPoint: UnitPoint(x: 1 - drift, y: 1))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .allowsHitTesting(false)
    }
}
#endif
