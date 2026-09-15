import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PortableColorArchive {
#if os(macOS)
    typealias ArchivedColor = NSColor
#else
    typealias ArchivedColor = UIColor
#endif

    static func data(for color: ArchivedColor, requiringSecureCoding: Bool = true) throws -> Data {
#if os(macOS)
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.setClassName("UIColor", for: PortableRGBAColor.self)
        archive.encode(try PortableRGBAColor(color), forKey: NSKeyedArchiveRootObjectKey)
        archive.finishEncoding()
        return archive.encodedData
#else
        return try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: requiringSecureCoding)
#endif
    }

    static func data(for colors: [ArchivedColor]) throws -> Data {
#if os(macOS)
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.setClassName("UIColor", for: PortableRGBAColor.self)
        archive.encode(try colors.map(PortableRGBAColor.init), forKey: NSKeyedArchiveRootObjectKey)
        archive.finishEncoding()
        return archive.encodedData
#else
        return try NSKeyedArchiver.archivedData(withRootObject: colors, requiringSecureCoding: true)
#endif
    }

    static func color(from data: Data) throws -> ArchivedColor? {
#if os(macOS)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.decodingFailurePolicy = .setErrorAndReturn
        decoder.setClass(NSColor.self, forClassName: "UIColor")
        let result = decoder.decodeObject(of: NSColor.self, forKey: NSKeyedArchiveRootObjectKey)
        decoder.finishDecoding()
        if let error = decoder.error { throw error }
        return result.map(restoreSRGB)
#else
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data)
#endif
    }

    static func colors(from data: Data) throws -> [ArchivedColor]? {
#if os(macOS)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.decodingFailurePolicy = .setErrorAndReturn
        decoder.setClass(NSColor.self, forClassName: "UIColor")
        let colors = decoder.decodeObject(of: [NSArray.self, NSColor.self], forKey: NSKeyedArchiveRootObjectKey) as? [NSColor]
        decoder.finishDecoding()
        if let error = decoder.error { throw error }
        return colors?.map(restoreSRGB)
#else
        return try NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: UIColor.self, from: data)
#endif
    }

#if os(macOS)
    private static func restoreSRGB(_ color: NSColor) -> NSColor {
        guard color.colorSpace == .deviceRGB else { return color }
        return NSColor(srgbRed: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: color.alphaComponent)
    }

    @objc(EclipsePortableRGBAColor)
    private final class PortableRGBAColor: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let components: [Double]

        init(_ color: NSColor) throws {
            guard let rgb = color.usingColorSpace(.sRGB) else {
                throw CocoaError(.coderInvalidValue)
            }
            components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map(Double.init)
            guard components.allSatisfy(\.isFinite) else { throw CocoaError(.coderInvalidValue) }
            super.init()
        }

        required init?(coder: NSCoder) { nil }

        func encode(with coder: NSCoder) {
            coder.encode(4, forKey: "UIColorComponentCount")
            for (key, value) in zip(["UIRed", "UIGreen", "UIBlue", "UIAlpha"], components) {
                coder.encode(Float(value), forKey: key)
                coder.encode(value, forKey: key + "-Double")
            }
            coder.encode(2, forKey: "NSColorSpace")
            let bytes = Array(components.map(String.init(describing:)).joined(separator: " ").utf8)
            coder.encodeBytes(bytes, length: bytes.count, forKey: "NSRGB")
        }
    }
#endif
}
