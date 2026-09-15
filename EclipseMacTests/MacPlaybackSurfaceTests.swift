import AppKit
import AVFoundation
import XCTest
@testable import EclipseMac

@MainActor
final class MacPlaybackSurfaceTests: XCTestCase {
    func testPictureInPictureUsesHostBackingScaleOutsideAVKitOwnership() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = MacPlaybackSurfaceView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        let layer = AVSampleBufferDisplayLayer()
        surface.installPictureInPictureLayer(layer)
        window.contentView = surface
        defer { window.contentView = nil; window.close() }
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(layer.contentsScale, window.backingScaleFactor)
        surface.setPictureInPictureOwnsLayerGeometry(true)
        layer.contentsScale = 3
        surface.viewDidChangeBackingProperties()
        XCTAssertEqual(layer.contentsScale, 3)
        surface.setPictureInPictureOwnsLayerGeometry(false)
        XCTAssertEqual(layer.contentsScale, window.backingScaleFactor)
    }

    func testPictureInPictureOwnsItsLayerGeometryUntilInlineRestoration() {
        let surface = MacPlaybackSurfaceView(frame: CGRect(x: 0, y: 0, width: 492, height: 468))
        let layer = AVSampleBufferDisplayLayer()
        surface.installPictureInPictureLayer(layer)
        XCTAssertEqual(layer.bounds.width, 492, accuracy: 0.01)
        XCTAssertEqual(layer.bounds.height, 276.75, accuracy: 0.01)
        surface.setPictureInPictureOwnsLayerGeometry(true)
        let pictureInPictureFrame = CGRect(x: 0, y: 0, width: 350, height: 196.875)
        layer.frame = pictureInPictureFrame
        surface.frame.size = CGSize(width: 720, height: 520)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(layer.frame, pictureInPictureFrame)
        surface.setPictureInPictureOwnsLayerGeometry(false)
        XCTAssertEqual(layer.bounds.width, 720, accuracy: 0.01)
        XCTAssertEqual(layer.bounds.height, 405, accuracy: 0.01)
    }
}
