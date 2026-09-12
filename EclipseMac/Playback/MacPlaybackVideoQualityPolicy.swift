#if os(macOS)
import Foundation

enum MacPlaybackVideoQualityPolicy {
    static func effectiveProfile(_ requested: MPVMetalQualityProfile,
                                 thermal: ProcessInfo.ThermalState) -> MPVMetalQualityProfile {
        guard requested == .auto else { return requested }
        switch thermal {
        case .critical, .serious: return .lowHeat
        case .fair: return .balanced
        default: return .sharp
        }
    }

    static func contentsScale(profile: MPVMetalQualityProfile, mode: MPVUpscalingMode,
                              source: CGSize, bounds: CGSize, backingScale: CGFloat) -> CGFloat {
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let multiplier: CGFloat = profile == .lowHeat ? 0.62 : profile == .balanced ? 0.82 : 1
        let base = max(0.5, scale * multiplier)
        guard source.width > 0, source.height > 0, bounds.width > 1, bounds.height > 1 else { return base }
        let target: CGFloat
        switch mode {
        case .upscaleTo4K: target = 2160
        case .oneLevelAlways:
            target = [480, 720, 1080, 1440, 2160].first(where: { $0 > source.height }) ?? source.height
        default: return base
        }
        let displayHeight = min(bounds.height, bounds.width * source.height / source.width)
        return max(0.5, min(base, target / displayHeight))
    }
}
#endif
