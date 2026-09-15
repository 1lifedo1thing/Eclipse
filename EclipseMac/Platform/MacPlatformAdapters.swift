import AppKit
import SwiftUI
import ImageIO

typealias UIImage = NSImage
typealias UIColor = NSColor
typealias UIEdgeInsets = NSEdgeInsets

extension NSImage {
    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    var scale: CGFloat {
        guard size.width > 0, let cgImage else { return 1 }
        return CGFloat(cgImage.width) / size.width
    }

    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    convenience init(cgImage: CGImage, scale: CGFloat, orientation: MacImageOrientation) {
        let validScale = scale.isFinite && scale > 0 ? scale : 1
        self.init(cgImage: cgImage, size: CGSize(width: CGFloat(cgImage.width) / validScale, height: CGFloat(cgImage.height) / validScale))
    }

    convenience init?(systemName: String) {
        self.init(systemSymbolName: systemName, accessibilityDescription: nil)
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(
            using: .jpeg,
            properties: [.compressionFactor: min(1, max(0, compressionQuality))]
        )
    }

    func pngData() -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    func resized(to targetSize: CGSize, contentMode: MacImageContentMode = .scaleAspectFit) -> NSImage? {
        guard targetSize.width > 0, targetSize.height > 0,
              size.width > 0, size.height > 0, let source = cgImage,
              let context = CGContext(
                data: nil,
                width: Int(targetSize.width.rounded(.up)),
                height: Int(targetSize.height.rounded(.up)),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let widthScale = targetSize.width / size.width
        let heightScale = targetSize.height / size.height
        let scale = contentMode == .scaleAspectFill ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let destinationSize = CGSize(width: size.width * scale, height: size.height * scale)
        let destination = CGRect(
            x: (targetSize.width - destinationSize.width) / 2,
            y: (targetSize.height - destinationSize.height) / 2,
            width: destinationSize.width,
            height: destinationSize.height
        )
        context.interpolationQuality = .high
        context.draw(source, in: destination)
        return context.makeImage().map(NSImage.init(cgImage:))
    }
}

enum MacImageOrientation { case up }

enum MacImageContentMode {
    case scaleAspectFit
    case scaleAspectFill
}

extension NSColor {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .underPageBackgroundColor }
    static var tertiarySystemBackground: NSColor { .controlBackgroundColor }
    static var separator: NSColor { .separatorColor }
    static var systemGray2: NSColor { .systemGray }
    static var systemGray3: NSColor { .systemGray.withAlphaComponent(0.8) }
    static var systemGray4: NSColor { .systemGray.withAlphaComponent(0.6) }
    static var systemGray5: NSColor { .systemGray.withAlphaComponent(0.4) }
    static var systemGray6: NSColor { .systemGray.withAlphaComponent(0.2) }

    func getRed(_ red: inout CGFloat, green: inout CGFloat, blue: inout CGFloat, alpha: inout CGFloat) -> Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
        alpha = rgb.alphaComponent
        return true
    }

    func getHue(_ hue: inout CGFloat, saturation: inout CGFloat, brightness: inout CGFloat, alpha: inout CGFloat) -> Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        hue = rgb.hueComponent
        saturation = rgb.saturationComponent
        brightness = rgb.brightnessComponent
        alpha = rgb.alphaComponent
        return true
    }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

enum MacNavigationTitleDisplayMode {
    case automatic
    case inline
    case large
}

extension View {
    func navigationBarTitleDisplayMode(_ mode: MacNavigationTitleDisplayMode) -> some View { self }
    func navigationBarHidden(_ hidden: Bool) -> some View { self }
}
