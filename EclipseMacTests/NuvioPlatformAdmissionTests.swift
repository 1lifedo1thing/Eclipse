import XCTest
@testable import EclipseMac

final class NuvioPlatformAdmissionTests: XCTestCase {
    func testIOSRuntimeABIIsAdmittedOnMac() {
        XCTAssertTrue(NuvioPlatformAdmissionPolicy.allows(supported: ["ios"], disabled: nil, isMac: true))
    }

    func testExplicitMacDisableOverridesCompatibleRuntimeABI() {
        for spelling in ["mac", "macOS", "osx", "apple"] {
            XCTAssertFalse(NuvioPlatformAdmissionPolicy.allows(supported: ["ios", "all"], disabled: [spelling], isMac: true))
        }
    }

    func testUnrelatedPlatformsAreRejected() {
        XCTAssertFalse(NuvioPlatformAdmissionPolicy.allows(supported: ["android", "windows"], disabled: nil, isMac: true))
    }

    func testNativeMacDeclarationsAreCaseInsensitive() {
        for spelling in ["Mac", "macOS", "OSX", "Apple", "ALL"] {
            XCTAssertTrue(NuvioPlatformAdmissionPolicy.allows(supported: [spelling], disabled: nil, isMac: true))
        }
    }

    func testIOSAdmissionRemainsIndependentOfMacDisable() {
        XCTAssertTrue(NuvioPlatformAdmissionPolicy.allows(supported: ["ios"], disabled: ["macos"], isMac: false))
        XCTAssertFalse(NuvioPlatformAdmissionPolicy.allows(supported: ["macos"], disabled: nil, isMac: false))
    }
}
