import AVFoundation
#if os(macOS)
import AppKit
typealias PlaybackPlatformColor = NSColor
typealias PlaybackPlatformFont = NSFont
#else
import UIKit
typealias PlaybackPlatformColor = UIColor
typealias PlaybackPlatformFont = UIFont
#endif

enum PlayerSubtitleTiming {
    static let range: ClosedRange<Double> = -60...60
    static let step = 0.25

    static func sanitized(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(range.upperBound, max(range.lowerBound, seconds))
    }

    static func cueTime(playbackTime: Double, delay: Double) -> Double {
        playbackTime - sanitized(delay)
    }

    static func label(_ seconds: Double) -> String {
        let value = sanitized(seconds)
        return abs(value) < 0.005 ? "0.00 s" : String(format: "%+.2f s", value)
    }
}

struct PlayerSubtitleAppearance {
    let foregroundColor: PlaybackPlatformColor
    let strokeColor: PlaybackPlatformColor
    let strokeWidth: CGFloat
    let fontSize: CGFloat
    let verticalOffset: CGFloat
    let captionBackground: Bool

    init(defaults: UserDefaults = ProfileSettingsStore.active) {
        foregroundColor = Self.color(defaults: defaults, key: "subtitles_foregroundColor", fallback: .white)
        strokeColor = Self.color(defaults: defaults, key: "subtitles_strokeColor", fallback: .black)
        strokeWidth = Self.bounded(defaults.object(forKey: "subtitles_strokeWidth") as? Double, fallback: 1, range: 0...2)
        let savedFontSize = defaults.double(forKey: "subtitles_fontSize")
        fontSize = Self.bounded(savedFontSize > 0 ? savedFontSize : nil, fallback: 30, range: 10...72)
        verticalOffset = Self.bounded(
            defaults.object(forKey: "playerSubtitleOverlayBottomConstant") as? Double
                ?? defaults.object(forKey: "vlcSubtitleOverlayBottomConstant") as? Double,
            fallback: -6,
            range: -24...24
        )
        captionBackground = defaults.bool(forKey: "subtitles_closedCaptionBackground")
    }

    var overridesASSStyles: Bool {
        Self.overridesASSStyles(
            foregroundColor: foregroundColor,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            fontSize: fontSize,
            verticalOffset: verticalOffset,
            captionBackground: captionBackground
        )
    }

    static func overridesASSStyles(
        foregroundColor: PlaybackPlatformColor,
        strokeColor: PlaybackPlatformColor,
        strokeWidth: CGFloat,
        fontSize: CGFloat,
        verticalOffset: CGFloat = -6,
        captionBackground: Bool
    ) -> Bool {
        !foregroundColor.isEqual(PlaybackPlatformColor.white)
            || !strokeColor.isEqual(PlaybackPlatformColor.black)
            || abs(strokeWidth - 1) > 0.001
            || abs(fontSize - 30) > 0.001
            || abs(verticalOffset + 6) > 0.001
            || captionBackground
    }

    static func mpvPosition(for offset: CGFloat) -> CGFloat {
        let offset = offset.isFinite ? max(-24, min(offset, 24)) : -6
        return min(100, 100 + offset + 6)
    }

    static func mpvMargin(for offset: CGFloat) -> CGFloat {
        let offset = offset.isFinite ? max(-24, min(offset, 24)) : -6
        return offset <= -6 ? 34 : 34 * (24 - offset) / 30
    }

    static func mpvASSMarginOverride(for offset: CGFloat) -> String {
        let margin = mpvMargin(for: offset)
        return margin < 34 ? "MarginV=\(Int(margin.rounded()))" : ""
    }

    static func attributedStrokeWidth(_ width: CGFloat, fontSize: CGFloat) -> CGFloat {
        guard width.isFinite, fontSize.isFinite, fontSize > 0 else { return 0 }
        return -100 * max(0, min(width, 2)) / fontSize
    }

    static func mpvColor(_ color: PlaybackPlatformColor) -> String {
        let components = argb(color)
        return "#" + components.map {
            String(format: "%02X", Int(max(0, min($0, 1)) * 255))
        }.joined()
    }

    var overlayBottomConstant: CGFloat {
        -92 + (verticalOffset + 6) * 2.5
    }

    func attributedText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: PlaybackPlatformFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: foregroundColor,
            .strokeColor: strokeColor,
            .strokeWidth: Self.attributedStrokeWidth(strokeWidth, fontSize: fontSize)
        ])
    }

    var avTextStyleRules: [AVTextStyleRule] {
        let edge = strokeWidth > 0 && strokeColor.cgColor.alpha > 0
            ? kCMTextMarkupCharacterEdgeStyle_Uniform
            : kCMTextMarkupCharacterEdgeStyle_None
        let attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: Self.argb(foregroundColor),
            kCMTextMarkupAttribute_BackgroundColorARGB as String: [captionBackground ? 0.75 : 0, 0, 0, 0],
            kCMTextMarkupAttribute_RelativeFontSize as String: fontSize / 30 * 100,
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: edge,
            kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String:
                min(96, 90 + (verticalOffset + 6) / 3)
        ]
        return AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] } ?? []
    }

    private static func bounded(_ value: Double?, fallback: Double, range: ClosedRange<Double>) -> CGFloat {
        guard let value, value.isFinite else { return CGFloat(fallback) }
        return CGFloat(max(range.lowerBound, min(value, range.upperBound)))
    }

    private static func color(defaults: UserDefaults, key: String, fallback: PlaybackPlatformColor) -> PlaybackPlatformColor {
        guard let data = defaults.data(forKey: key),
              let color = try? PortableColorArchive.color(from: data) else {
            return fallback
        }
        return color
    }

    private static func argb(_ color: PlaybackPlatformColor) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [alpha, red, green, blue]
    }
}
