import AppKit
import XCTest
@testable import EclipseMac

final class PortableColorArchiveTests: XCTestCase {
    func testUIKitFixturePreservesSRGBComponents() throws {
        let fixture = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGjCwwjVSRudWxs2w0ODxAREhMUFRYXGBkaGxwdHh8gISJfEBVVSUNvbG9yQ29tcG9uZW50Q291bnRXVUlHcmVlblZVSUJsdWVdVUlCbHVlLURvdWJsZVdVSUFscGhhVU5TUkdCViRjbGFzc1VVSVJlZFxOU0NvbG9yU3BhY2VeVUlBbHBoYS1Eb3VibGVeVUlHcmVlbi1Eb3VibGUQBCI99cKPIj7mZmYjP9zMzMzMzM0iP0zMzU8QEjAuMjUgMC4xMiAwLjQ1IDAuOIACIj6AAAAQAiM/6ZmZmZmZmiM/vrhR64UeuNMkJSYnKCpaJGNsYXNzbmFtZVgkY2xhc3Nlc1skY2xhc3NoaW50c1dVSUNvbG9yoicpWE5TT2JqZWN0oStXTlNDb2xvcgAIABEAGgAkACkAMgA3AEkATABRAFMAVwBdAHQAjACUAJsAqQCxALcAvgDEANEA4ADvAPEA9gD7AQQBCQEeASABJQEnATABOQFAAUsBVAFgAWgBawF0AXYAAAAAAAACAQAAAAAAAAAsAAAAAAAAAAAAAAAAAAABfg=="
        let data = try XCTUnwrap(Data(base64Encoded: fixture))
        let color = try XCTUnwrap(PortableColorArchive.color(from: data)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0.25, accuracy: 0.000001)
        XCTAssertEqual(color.greenComponent, 0.12, accuracy: 0.000001)
        XCTAssertEqual(color.blueComponent, 0.45, accuracy: 0.000001)
        XCTAssertEqual(color.alphaComponent, 0.8, accuracy: 0.000001)
    }

    func testMacWriterUsesUIKitArchiveClassAndRoundTripsPalette() throws {
        let inputs = [NSColor(srgbRed: 0.25, green: 0.12, blue: 0.45, alpha: 0.8), NSColor.white]
        let data = try PortableColorArchive.data(for: inputs)
        let archive = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(archive["$objects"] as? [Any])
        let names = objects.compactMap { ($0 as? [String: Any])?["$classname"] as? String }
        XCTAssertTrue(names.contains("UIColor"))
        XCTAssertFalse(names.contains("NSColor"))
        let colors = try XCTUnwrap(PortableColorArchive.colors(from: data))
        XCTAssertEqual(colors.count, inputs.count)
        for (input, color) in zip(inputs, colors) {
            let expected = try XCTUnwrap(input.usingColorSpace(.sRGB))
            let actual = try XCTUnwrap(color.usingColorSpace(.sRGB))
            XCTAssertEqual(expected.redComponent, actual.redComponent, accuracy: 0.000001)
            XCTAssertEqual(expected.greenComponent, actual.greenComponent, accuracy: 0.000001)
            XCTAssertEqual(expected.blueComponent, actual.blueComponent, accuracy: 0.000001)
            XCTAssertEqual(expected.alphaComponent, actual.alphaComponent, accuracy: 0.000001)
        }
    }

    func testCorruptAndWrongClassArchivesFailWithoutInventingColor() throws {
        XCTAssertThrowsError(try PortableColorArchive.color(from: Data([0, 1, 2, 3])))
        let wrongClass = try NSKeyedArchiver.archivedData(withRootObject: NSDate(), requiringSecureCoding: true)
        XCTAssertThrowsError(try PortableColorArchive.color(from: wrongClass))
    }
}
