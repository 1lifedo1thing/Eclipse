#if os(macOS)
import Foundation

enum MacPlaybackFileTypes {
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "mks", "dfxp", "ttml"]
    static let avOverlaySubtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]
}
#endif
