@testable import CleanKit
import Foundation
import XCTest

final class DiskImageAttachmentTests: XCTestCase {
    let payload = "/tmp/thermo-attachment-fixture/payload.archive"
    let mount = "/tmp/thermo-attachment-fixture/mounted"
    func image(path: String? = nil, device: String = "/dev/disk900", point: String? = nil) -> [String: Any] {
        ["image-path": path ?? payload, "system-entities": [
            ["dev-entry": device + "s1", "content-hint": "Apple_APFS"],
            ["dev-entry": device, "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk901s1", "mount-point": point ?? mount, "content-hint": "Apple_APFS"],
            ["dev-entry": "/dev/disk901", "content-hint": "APFS_container"]]]
    }
    func testPhysicalRootIsSelectedWithoutRelyingOnEntityOrder() throws {
        let entities = try XCTUnwrap(image()["system-entities"] as? [[String: Any]])
        XCTAssertEqual(NativeDiskImage.rootDevice(entities), "/dev/disk900")
        XCTAssertEqual(NativeDiskImage.rootDevice(Array(entities.reversed())), "/dev/disk900")
        XCTAssertNil(NativeDiskImage.rootDevice([["dev-entry": "/dev/disk900s1"]]))
    }
    func testCleanupDetachesOnlyNewOwnedPhysicalDeviceAndKeepsOtherImages() {
        let unrelated = image(path: "/tmp/unrelated.dmg", device: "/dev/disk800", point: "/Volumes/Unrelated")
        var calls = 0, detached: [String] = []
        let ok = NativeDiskImage.finishAttachment(payload: payload, mount: mount, mountIdentity: "base",
            previousDevices: ["/dev/disk800"], attachedDevices: ["/dev/disk900"], query: {
                calls += 1; return ["images": calls == 1 ? [self.image(), unrelated] : [unrelated]]
            }, detach: { detached.append($0); return true }, identity: { _ in "base" })
        XCTAssertTrue(ok); XCTAssertEqual(detached, ["/dev/disk900"])
    }
    func testDifferentImagePathCanBeCleanedOnlyWithNewReturnedDeviceAndPrivateMount() {
        var calls = 0, detached: [String] = []
        let ok = NativeDiskImage.finishAttachment(payload: payload, mount: mount, mountIdentity: "base",
            previousDevices: [], attachedDevices: ["/dev/disk900"], query: {
                calls += 1; return ["images": calls == 1 ? [self.image(path: "/tmp/original-name.dmg")] : []]
            }, detach: { detached.append($0); return true }, identity: { _ in "base" })
        XCTAssertTrue(ok); XCTAssertEqual(detached, ["/dev/disk900"])
    }
    func testAlreadyAttachedDeviceIsNeverAdoptedForCleanup() {
        var detached = false
        XCTAssertFalse(NativeDiskImage.finishAttachment(payload: payload, mount: mount, mountIdentity: "base",
            previousDevices: ["/dev/disk900"], attachedDevices: ["/dev/disk900"], query: { ["images": [self.image()]] },
            detach: { _ in detached = true; return true }, identity: { _ in "base" }))
        XCTAssertFalse(detached)
    }
    func testUnexpectedDeviceAtPrivatePointCannotAuthorizeDetachment() {
        var detached = false
        XCTAssertFalse(NativeDiskImage.finishAttachment(payload: payload, mount: mount, mountIdentity: "base",
            previousDevices: [], attachedDevices: ["/dev/disk777"], query: { ["images": [self.image(path: "/tmp/other.dmg")]] },
            detach: { _ in detached = true; return true }, identity: { _ in "base" }))
        XCTAssertFalse(detached)
    }
    func testMissingImagePathDoesNotProveThePrivateMountWasReleased() {
        XCTAssertFalse(NativeDiskImage.finishAttachment(payload: payload, mount: mount, mountIdentity: "base",
            previousDevices: [], attachedDevices: [], query: { ["images": []] },
            detach: { _ in XCTFail("No device was identified"); return true }, identity: { _ in "still-mounted" }))
    }
    func testReturnedDeviceAtUnexpectedLocationCannotBeReportedAsClean() {
        XCTAssertFalse(NativeDiskImage.finishAttachment(payload: payload, mount: mount, mountIdentity: "base",
            previousDevices: [], attachedDevices: ["/dev/disk900"],
            query: { ["images": [self.image(path: "/tmp/changed-name.dmg", point: "/Volumes/Unexpected")]] },
            detach: { _ in XCTFail("An unexpected location is not an owned private mount"); return true }, identity: { _ in "base" }))
    }
    func testReportedDetachSuccessStillRequiresFreshAbsenceAndOriginalDirectoryIdentity() {
        XCTAssertFalse(NativeDiskImage.finishAttachment(payload: payload, mount: mount, mountIdentity: "base",
            previousDevices: [], attachedDevices: ["/dev/disk900"], query: { ["images": [self.image()]] },
            detach: { _ in true }, identity: { _ in "base" }))
    }
    func testUnreadableInventoryOrFailedDetachCannotConfirmCleanup() {
        XCTAssertFalse(NativeDiskImage.finishAttachment(payload: payload, mount: mount, mountIdentity: "base",
            previousDevices: [], attachedDevices: [], query: { [:] }, detach: { _ in XCTFail(); return true }, identity: { _ in "base" }))
        XCTAssertFalse(NativeDiskImage.finishAttachment(payload: payload, mount: mount, mountIdentity: "base",
            previousDevices: [], attachedDevices: ["/dev/disk900"], query: { ["images": [self.image()]] },
            detach: { _ in false }, identity: { _ in "base" }))
    }
    func testPartialAttachCanBeCleanedByExactPrivatePayloadWithoutInventingDeviceOutput() {
        var calls = 0
        XCTAssertTrue(NativeDiskImage.finishAttachment(payload: payload, mount: mount, mountIdentity: "base",
            previousDevices: [], attachedDevices: [], query: {
                calls += 1; return ["images": calls == 1 ? [self.image()] : []]
            }, detach: { _ in true }, identity: { _ in "base" }))
    }
}
