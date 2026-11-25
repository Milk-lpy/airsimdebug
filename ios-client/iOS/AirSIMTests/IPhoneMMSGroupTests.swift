import XCTest
@testable import AirSIM

@MainActor
final class IPhoneMMSGroupTests: XCTestCase {
    private let primary = IPhoneMessagingLine(id: "primary", label: "主号", supportsSMS: true, supportsMMS: false, supportsRCS: true)
    private let offline = IPhoneMessagingLine(id: "secondary", label: "副号", supportsSMS: false, supportsMMS: false, supportsRCS: false)

    func testComposerWaitsForCarrierRoleWithoutAndroid() {
        XCTAssertNil(ComposerSender.initial(hasAndroid: false, role: .inactive, lines: [primary]))
        XCTAssertNil(ComposerSender.initial(hasAndroid: false, role: .configured, lines: []))
        XCTAssertEqual(ComposerSender.initial(hasAndroid: true, role: .inactive, lines: []), .android)
        XCTAssertEqual(ComposerSender.initial(hasAndroid: false, role: .configured, lines: [primary]), .iPhone(primary.id))
    }

    func testComposerDoesNotSilentlySelectAnotherSIMWhileOneIsOffline() {
        XCTAssertNil(ComposerSender.initial(hasAndroid: false, role: .configured, lines: [primary, offline]))
        XCTAssertNil(ComposerSender.initial(hasAndroid: false, role: .configured, lines: [offline]))
        XCTAssertNil(ComposerSender.initial(hasAndroid: false, role: .configured, lines: [primary], enumerationComplete: false))
        XCTAssertEqual(primary.protocols, ["SMS", "RCS"])
        XCTAssertTrue(offline.protocols.isEmpty)
    }

    func testExplicitSIMIsRememberedAndNeverReplacedByAnotherSender() {
        XCTAssertEqual(ComposerSender.initial(hasAndroid: true, role: .configured, lines: [offline, primary], rememberedLine: primary.id),
                       .iPhone(primary.id))
        XCTAssertNil(ComposerSender.initial(hasAndroid: true, role: .configured, lines: [offline], rememberedLine: primary.id))
        XCTAssertNil(ComposerSender.initial(hasAndroid: true, role: .inactive, lines: [], rememberedLine: primary.id))
    }

    func testSenderAndOneOtherRecipientAlreadyFormGroup() throws {
        let group = try XCTUnwrap(IPhoneCarrierMessaging.mmsGroupID(from: "+12025550101", recipients: ["+12025550102"]))
        XCTAssertEqual(IPhoneCarrierMessaging.mmsGroupRecipients(group), ["+12025550101", "+12025550102"])
        XCTAssertEqual(try IPhoneCarrierMessaging.mmsGroupID(from: "+12025550102",
            recipients: ["+12025550101", "+12025550101"]), group)
    }

    func testOneToOneIsNotConvertedIntoGroup() throws {
        XCTAssertNil(try IPhoneCarrierMessaging.mmsGroupID(from: "+12025550101", recipients: []))
        XCTAssertNil(try IPhoneCarrierMessaging.mmsGroupID(from: "+12025550101", recipients: ["+12025550101"]))
        XCTAssertNil(try IPhoneCarrierMessaging.mmsGroupID(from: "", recipients: ["+12025550101"]))
    }

    func testFormattingDoesNotAddAnotherRecipient() throws {
        XCTAssertNil(try IPhoneCarrierMessaging.mmsGroupID(from: "+1 (202) 555-0101", recipients: ["+12025550101"]))
        let id = try XCTUnwrap(IPhoneCarrierMessaging.mmsGroupID(from: "+12025550101",
            recipients: ["+1 (202) 555-0102", "+12025550102"]))
        XCTAssertEqual(IPhoneCarrierMessaging.mmsGroupRecipients(id), ["+12025550101", "+12025550102"])
    }

    func testInvalidGroupKeyIsNotTreatedAsAnAddress() {
        XCTAssertEqual(IPhoneCarrierMessaging.mmsGroupRecipients("not a group"), [])
    }
}
