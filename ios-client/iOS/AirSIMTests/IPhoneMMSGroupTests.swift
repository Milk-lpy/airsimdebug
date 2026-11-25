import XCTest
@testable import AirSIM

@MainActor
final class IPhoneMMSGroupTests: XCTestCase {
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
