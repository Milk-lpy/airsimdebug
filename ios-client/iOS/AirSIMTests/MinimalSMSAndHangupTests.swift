import AVFoundation
import Foundation
import SQLite3
import XCTest
import UIKit
@testable import AirSIM

final class RecentCallGroupingUpgradeTests: XCTestCase {
    private func record(_ id: String, _ number: String?, _ time: Double) -> CallRecord {
        CallRecord(id: id, index: 0, direction: "incoming", state: "ended", number: number,
            startedAt: Date(timeIntervalSince1970: time), updatedAt: Date(timeIntervalSince1970: time + 30),
            endedAt: Date(timeIntervalSince1970: time + 30), missed: false)
    }
    func testGroupingPreservesEveryRecordAndSortsLatest() {
        let records = [record("a", "+86 138-0013-8000", 1), record("b", "13800138000", 3),
            record("c", "+1 3800138000", 2), record("d", nil, 4), record("e", nil, 5)]
        let groups = RecentCallGroup.grouped(records)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.first?.latest.id, "e")
        XCTAssertEqual(groups.first { $0.id == "13800138000" }?.records.map(\.id), ["b", "a"])
        XCTAssertEqual(Set(groups.flatMap { $0.records.map(\.id) }), Set(records.map(\.id)))
    }
    func testCountryPrefixesAndServiceNumbersAreNeverSuffixMerged() {
        XCTAssertNotEqual(RecentCallGroup.normalizedNumber("+44 20 1234 5678"), RecentCallGroup.normalizedNumber("02012345678"))
        XCTAssertEqual(RecentCallGroup.normalizedNumber("+86 13800138000"), "13800138000")
        XCTAssertNotEqual(RecentCallGroup.normalizedNumber("12345678"), RecentCallGroup.normalizedNumber("87654321"))
        XCTAssertEqual(RecentCallGroup.normalizedNumber("10086#1"), "10086#1")
    }
    @MainActor func testGroupDeletionPersistsWithoutDeletingOtherNumbers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryStore(directoryURL: directory)
        let calls = [record("a", "+86 13800138000", 1), record("b", "13800138000", 2), record("c", "10086", 3)]
        XCTAssertTrue(store.saveCallHistory(calls))
        let model = AppModel(historyStore: store)
        model.callHistory = calls
        let group = try XCTUnwrap(RecentCallGroup.grouped(calls).first { $0.records.count == 2 })
        model.deleteCallHistory(ids: group.recordIDs)
        XCTAssertEqual(model.callHistory.map(\.id), ["c"])
        XCTAssertEqual(LocalHistoryStore(directoryURL: directory).loadCallHistory().map(\.id), ["c"])
    }
    func testScopedHistoryPreservesReliableConnectionTime() {
        var call = record("a", "10086", 1)
        call.connectedAt = Date(timeIntervalSince1970: 11)
        XCTAssertEqual(call.scopedHistory(to: "fixture-agent").connectedDuration, 20)
    }
    func testMissedAndLegacyRecordsNeverInventDuration() {
        var call = record("a", "10086", 1)
        XCTAssertNil(call.connectedDuration)
        call.connectedAt = Date(timeIntervalSince1970: 11)
        XCTAssertEqual(call.connectedDuration, 20)
        let missed = CallRecord(id: "m", index: 0, direction: "incoming", state: "ended", number: nil,
            startedAt: call.startedAt, updatedAt: call.updatedAt, endedAt: call.endedAt, missed: true, connectedAt: call.connectedAt)
        XCTAssertNil(missed.connectedDuration)
    }
}


final class CallbackSIMDialChoiceTests: XCTestCase {
    private var slots: [AndroidSIMSlot] {
        try! JSONDecoder().decode([AndroidSIMSlot].self, from: Data("""
        [{"id":"voice-one","label":"SIM 1","slot_index":0},{"id":"voice-two","label":"SIM 2","slot_index":1}]
        """.utf8))
    }
    private let primary = IPhoneCellularLine(id: UUID(), label: "主号")
    private let secondary = IPhoneCellularLine(id: UUID(), label: "副号")
    private func roster(_ agent: String?, slots: [AndroidSIMSlot], local: [IPhoneCellularLine]) -> [DialLineChoice] {
        DialLineChoice.roster(agentID: agent, slots: slots, hasAndroid: agent != nil, local: local, supportsSystem: true)
    }

    func testBothIPhoneLinesAndAndroidSlotsKeepExactRouteAndCallbackNumber() {
        let choices = roster("A", slots: slots, local: [primary, secondary])
        let expected: [DialLineID] = [.android(agentID: "A", slotID: "voice-one"), .android(agentID: "A", slotID: "voice-two"),
            .iPhone(primary.id), .iPhone(secondary.id), .system]
        XCTAssertEqual(choices.map(\.id), expected)
        let request = DialLineRequest(number: "+8613800138000", choices: choices)
        for route in expected {
            XCTAssertTrue(request.permits(route, number: request.number, live: choices, idle: true))
            XCTAssertFalse(request.permits(route, number: "10010", live: choices, idle: true))
            XCTAssertFalse(request.permits(route, number: request.number, live: choices, idle: false))
        }
    }

    func testRemovedSIMOrDeviceSwitchCannotRetargetTheCapturedChoice() {
        let request = DialLineRequest(number: "10086", choices: roster("A", slots: slots, local: [primary]))
        let route = DialLineID.android(agentID: "A", slotID: "voice-two")
        XCTAssertFalse(request.permits(route, number: request.number, live: roster("B", slots: slots, local: [primary]), idle: true))
        XCTAssertFalse(request.permits(route, number: request.number, live: roster("A", slots: [slots[0]], local: []), idle: true))
        XCTAssertFalse(request.permits(.iPhone(primary.id), number: request.number, live: roster("A", slots: slots, local: [secondary]), idle: true))
        XCTAssertFalse(request.permits(.iPhone(secondary.id), number: request.number, live: roster("A", slots: slots, local: [secondary]), idle: true))
    }

    func testLocalRoutesRemainSelectableWithoutAndroid() {
        let localOnly = roster(nil, slots: [], local: [primary, secondary])
        XCTAssertEqual(localOnly.map(\.id), [.iPhone(primary.id), .iPhone(secondary.id), .system])
        XCTAssertEqual(roster(nil, slots: [], local: []).map(\.id), [.system])
        XCTAssertTrue(DialLineChoice.roster(agentID: nil, slots: [], hasAndroid: false, local: [], supportsSystem: false).isEmpty)
    }

    func testStoredRoutesSurviveRelaunchAndMissingCardDoesNotFallBack() throws {
        let choices = roster("A", slots: slots, local: [primary, secondary])
        for choice in choices {
            let saved = DialLinePreference(data: try JSONEncoder().encode(choice.id))
            XCTAssertEqual(saved.resolve(in: choices, androidDefault: nil)?.id, choice.id)
            let remaining = choices.filter { $0.id != choice.id }
            XCTAssertNil(saved.resolve(in: remaining, androidDefault: remaining.first?.id))
        }
        let data = try JSONEncoder().encode(DialLineID.iPhone(primary.id))
        let preference = DialLinePreference(data: data)
        XCTAssertNil(preference.resolve(in: roster(nil, slots: [], local: []), androidDefault: nil))
        XCTAssertEqual(preference.resolve(in: roster(nil, slots: [], local: [secondary, primary]), androidDefault: nil)?.id, .iPhone(primary.id))
        XCTAssertNil(DialLinePreference(data: Data("invalid".utf8)).resolve(in: choices, androidDefault: nil))
    }

    func testAutomaticUsesPriorAndroidDefaultAndSystemChoiceIsSeparate() {
        let automatic = DialLinePreference(data: Data())
        let choices = roster("A", slots: slots, local: [primary, secondary])
        let old = DialLineID.android(agentID: "A", slotID: slots[1].id)
        XCTAssertEqual(automatic.resolve(in: choices, androidDefault: old)?.id, old)
        XCTAssertEqual(automatic.resolve(in: roster(nil, slots: [], local: [primary]), androidDefault: nil)?.id, .iPhone(primary.id))
        XCTAssertEqual(automatic.resolve(in: roster(nil, slots: [], local: [primary, secondary]), androidDefault: nil)?.id, .system)
        XCTAssertEqual(DialLinePreference.chosen(.system).resolve(in: choices, androidDefault: old)?.id, .system)
    }

    func testNativeVoiceInventoryReportsOnlyActualServicesAndHidesIdentifiersInDiagnostics() throws {
        let suite = "airsim.test.lines." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(DialLineID.iPhone(primary.id)), forKey: DialLinePreference.storageKey)
        XCTAssertNotEqual(IPhoneCellularLineInventory.notQueried.summary, IPhoneCellularLineInventory.reported([]).summary)
        let duplicateLabel = IPhoneCellularLine(id: UUID(), label: primary.label)
        for lines in [[], [primary], [duplicateLabel, primary]] {
            let inventory = IPhoneCellularLineInventory.reported(lines)
            XCTAssertTrue(inventory.summary.contains("\(lines.count) 条"))
            XCTAssertEqual(inventory.lines.map(\.id), lines.map(\.id))
            let summary = DialLinePreference.storedSummary(in: inventory, defaults: defaults)
            XCTAssertTrue(summary.contains(lines.isEmpty ? "未返回" : "可见"))
            XCTAssertFalse(summary.contains(primary.id.uuidString))
            XCTAssertFalse(summary.contains(primary.label))
        }
    }

}

final class ExternalDialHandoffTests: XCTestCase {
    func testTelLinksPrefillTheExactNormalizedNumber() throws {
        let examples: [(String, String)] = [
            ("tel:10086", "10086"),
            ("tel:%2B86%20(138)-0013-8000", "+8613800138000"),
            ("tel:%2A123%23", "*123#"),
            ("tel://10086", "10086"),
            ("tel:12345?source=contact", "12345"),
        ]
        for (link, number) in examples {
            let url = try XCTUnwrap(URL(string: link))
            XCTAssertEqual(SystemCommunicationURL.destination(for: url), .call(number))
        }
    }

    func testMalformedLinksDoNotProduceDialTargets() throws {
        for link in ["tel:?10086", "tel:12345;ext=6789", "tel:12%0A34", "tel:123+45", "tel:%2B"] {
            let url = try XCTUnwrap(URL(string: link))
            XCTAssertNil(SystemCommunicationURL.destination(for: url))
        }
    }
}


final class SMSCodeHighlightTests: XCTestCase {
    func testMissingBackendCodeStillHighlightsContextualCode() {
        for text in ["您的验证码：123456，请勿泄露", "动态码为123456", "确认码 123456", "Your security code: 123456", "123456 是您的验证码", "Your OTP is 123456"] {
            XCTAssertEqual(SMSCodeHighlight.match(in: text)?.code, "123456", text)
        }
    }
    func testOrdersPhonesAndLongNumbersAreNotCodes() {
        for text in ["订单号 123456", "物流单号12345678", "致电13800138000", "验证码12345678901", "Your barcode is 123456", "验证码已发送至13800138000", "code for order 123456"] {
            XCTAssertNil(SMSCodeHighlight.match(in: text), text)
        }
        XCTAssertEqual(SMSCodeHighlight.match(in: "订单20261104，验证码123456")?.code, "123456")
    }
    @MainActor func testRenderedCodeHasHighlightAndCopyLinkWithoutChangingBody() throws {
        let original = "【测试】验证码：123456，请勿泄露"
        let result = try XCTUnwrap(SMSCodeHighlight.renderedBody(in: original, outgoing: false))
        let range = try XCTUnwrap(SMSCodeHighlight.match(in: original)?.range)
        XCTAssertEqual(result.text.string, original)
        XCTAssertNotNil(result.text.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
        XCTAssertEqual((result.text.attribute(.link, at: range.location, effectiveRange: nil) as? URL)?.absoluteString, "airsim-code://copy/123456")
        XCTAssertNil(SMSCodeHighlight.renderedBody(in: "订单号123456", outgoing: false))
    }
    func testUnicodeRangePointsToOnlyTheCode() {
        let text = "📩【测试】验证码：654321。链接 https://example.com"
        let match = SMSCodeHighlight.match(in: text)
        XCTAssertEqual(match.map { (text as NSString).substring(with: $0.range) }, "654321")
    }
}


final class PhoneContentSearchTests: XCTestCase {
    func testSMSMatchesContactNumberAndOlderBody() {
        let messages = [SMSMessage(sender: "+8613800138000", content: "较早的快递取件码", code: nil, timestamp: Date(timeIntervalSince1970: 1)),
            SMSMessage(sender: "+8613800138000", content: "最新短信", code: nil, timestamp: Date(timeIntervalSince1970: 2))]
        for query in ["小王", "138 0013", "快递", ""] {
            XCTAssertTrue(PhoneContentSearch.smsMatches(sender: "+8613800138000", contactName: "小王", messages: messages, query: query))
        }
        XCTAssertFalse(PhoneContentSearch.smsMatches(sender: "+8613800138000", contactName: "小王", messages: messages, query: "不存在"))
    }
    func testNumberFormattingAndSearchDoNotMutateRecords() {
        XCTAssertTrue(PhoneContentSearch.numberMatches("13800138000", query: "+86 138-0013"))
        XCTAssertTrue(PhoneContentSearch.numberMatches("+86 138 0013 8000", query: "0013"))
        XCTAssertFalse(PhoneContentSearch.numberMatches("13800138000", query: "订单138"))
        XCTAssertFalse(PhoneContentSearch.numberMatches(nil, query: "138"))
        XCTAssertTrue(PhoneContentSearch.numberMatches(nil, query: "  "))
    }
}


final class PhoneRegionLookupTests: XCTestCase {
    func testBundledOfflineDataAndFormatting() {
        XCTAssertNotNil(PhoneRegionLookup.table, "Offline data must be shipped in the app")
        for number in ["13800138000", "+86 138-0013-8000", "008613800138000", "8613800138000"] {
            XCTAssertEqual(PhoneRegionLookup.region(for: number), "北京市", number)
        }
        XCTAssertEqual(PhoneRegionLookup.region(for: "01062503000"), "北京市")
        XCTAssertEqual(PhoneRegionLookup.region(for: "+86 21 68123456"), "上海市")
    }
    func testServicesInternationalAndMalformedNumbersRemainUnknown() {
        for number in ["10086", "110", "4001234567", "+864001234567", "+14155552671", "+85221234567", "138001380001234", "13800138000#", "private"] {
            XCTAssertNil(PhoneRegionLookup.region(for: number), number)
        }
        XCTAssertNil(PhoneRegionLookup.region(for: nil))
        XCTAssertNil(PhoneRegionLookup.Table(data: Data("bad".utf8)))
    }
    func testCStyleKeepsUnknownSIMUnknown() {
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "13800138000", slotIndex: 1), "SIM 2 · 北京市")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "13800138000", slotIndex: nil), "北京市")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "10086", slotIndex: 0), "SIM 1")
        XCTAssertNil(PhoneRegionLookup.infoLine(number: "10086", slotIndex: nil))
    }
}

final class PhoneRegion178RegressionTests: XCTestCase {
    func testMissingMobilePrefixAndServiceCategories() {
        XCTAssertEqual(PhoneRegionLookup.region(for: "17800159951"), "北京市")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "17800159951", slotIndex: nil), "北京市")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "+86 95588", slotIndex: 0), "SIM 1 · 国内 95 服务号码")
        XCTAssertEqual(PhoneRegionLookup.serviceDescription(for: "008696110"), "国内 96 服务号码")
        for value in ["911", "999", "912345", "+9595588", "009695588", "955881234567", "95abc"] {
            XCTAssertNil(PhoneRegionLookup.serviceDescription(for: value), value)
        }
    }
}

final class History181Tests: XCTestCase {
    func testHistoryEvidenceSurvivesLegacyRefreshAndSIMScoping() {
        let date = Date(timeIntervalSince1970: 100)
        var observed = CallRecord(id: "a", index: 0, direction: "incoming", state: "ended", number: "10086", startedAt: date, updatedAt: date, endedAt: date, missed: true)
        observed.slotIndex = 1
        let scoped = observed.scopedHistory(to: "device")
        XCTAssertEqual(scoped.slotIndex, 1)
        var legacy = observed; legacy.missed = false; legacy.slotIndex = nil
        let merged = legacy.preservingHistoryEvidence(from: observed)
        XCTAssertTrue(merged.missed); XCTAssertEqual(merged.slotIndex, 1)
        legacy.connectedAt = date
        XCTAssertFalse(legacy.preservingHistoryEvidence(from: observed).missed)
        let store = LocalHistoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertTrue(store.saveCallHistory([merged]))
        XCTAssertEqual(store.unseenMissedCallIDs(in: [merged]), [merged.id])
        XCTAssertTrue(store.markMissedCallsSeen([merged]))
        XCTAssertTrue(store.unseenMissedCallIDs(in: [merged]).isEmpty)
        XCTAssertTrue(store.loadCallHistory().first!.missed)
    }
}

final class IncomingSIM183Tests: XCTestCase {
    func testLateSIMMetadataUpdatesSameSessionWithoutSecondRing() throws {
        var registry = DeviceCallRegistry()
        var event = DeviceCallEvent(agentID: "A", callID: "call", state: .ringing, transport: .vowlan, transportEpoch: 1)
        _ = registry.apply(event)
        let key = try XCTUnwrap(registry.key(agentID: "A", callID: "call"))
        event.slotIndex = 1
        XCTAssertEqual(registry.apply(event), [.update(key)])
        XCTAssertEqual(registry.latestEvent(for: key)?.slotIndex, 1)
        XCTAssertEqual(registry.ringing, [key])
        XCTAssertTrue(registry.apply(event).isEmpty)
        event.slotIndex = -1
        XCTAssertTrue(registry.apply(event).isEmpty)
        XCTAssertEqual(registry.latestEvent(for: key)?.slotIndex, 1)
    }
}

final class PresentationSIM184Tests: XCTestCase {
    func testFinalPresentationPreservesBothSIMsAndDevice() throws {
        for slot in [0, 1] {
            var store = CallLifecycleStore()
            let date = Date(), uuid = UUID()
            _ = store.apply(.init(callID: "call", callUUID: uuid, generation: 1, state: .ringing, source: .agent, timestamp: date, traceID: nil, failure: nil))
            var record = CallRecord(id: "call", index: 0, direction: "incoming", state: "incoming", number: nil, startedAt: date, updatedAt: date, endedAt: nil, missed: false)
            record.slotIndex = slot; record.slotID = slot; record.sourceAgentID = "actual-device"
            let rendered = try XCTUnwrap(store.presentationRecord(from: record))
            XCTAssertEqual(rendered.slotIndex, slot)
            XCTAssertEqual(rendered.slotID, slot)
            XCTAssertEqual(rendered.sourceAgentID, "actual-device")
        }
    }
}

final class PR33NotificationTests: XCTestCase {
    func testNotificationIdentityDoesNotCrossDevicesOrGenerations() {
        let base: [AnyHashable: Any] = ["agent_id": "a", "call_id": "call", "generation": 1, "call_uuid": "u"]
        XCTAssertTrue(CallNotificationTruth.matches(base, base))
        for (key, value) in [("agent_id", "b"), ("call_id", "other"), ("call_uuid", "v")] {
            var other = base; other[key] = value
            XCTAssertFalse(CallNotificationTruth.matches(base, other))
        }
        var next = base; next["generation"] = 2
        XCTAssertFalse(CallNotificationTruth.matches(base, next))
        XCTAssertFalse(CallNotificationTruth.matches(["call_id": "call"], base))
        XCTAssertTrue(CallNotificationTruth.matches(["agent_id": "a", "call_id": "call"], base))
    }
    func testOnlyExplicitUnansweredIncomingTerminalIsMissed() {
        let now = Date()
        var call = CallRecord(id: "c", index: 0, direction: "incoming", state: "ended", number: "10086",
            startedAt: now, updatedAt: now, endedAt: now, missed: true)
        XCTAssertTrue(CallNotificationTruth.isMissed(call))
        call.connectedAt = now
        XCTAssertFalse(CallNotificationTruth.isMissed(call))
        XCTAssertFalse(CallNotificationTruth.isMissedPush(["event": "call_owner", "phase": "ended"]))
        XCTAssertTrue(CallNotificationTruth.isMissedPush(["event": "call_owner", "phase": "ended",
            "direction": "incoming", "missed": true, "notification_status": "missed"]))
    }
    func testNoticeIncludesNumberAndSIMWithoutDuplicateName() {
        XCTAssertEqual(CallNotificationTruth.body(number: "10086", callerName: "运营商", slotIndex: 1), "运营商 · 10086 · SIM 2")
        XCTAssertEqual(CallNotificationTruth.body(number: "10086", callerName: "10086", slotIndex: -1), "10086")
    }
}

final class PR33CarrierPreferenceTests: XCTestCase {
    func testDefaultUpgradeAndExplicitOptOut() {
        let name = "pr33.preferences." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(CarrierRingbackPreference.isEnabled(defaults: defaults))
        defaults.set(false, forKey: CarrierRingbackPreference.key)
        XCTAssertFalse(CarrierRingbackPreference.isEnabled(defaults: defaults))
    }
    func testReceiveOnlyNeverAuthorizesAnsweredIncomingOrEndedAudio() {
        for enabled in [false, true] {
            for outgoing in [false, true] {
                for state: CallLifecycleState in [.idle, .ringing, .connecting, .active, .ended, .failed] {
                    XCTAssertEqual(CarrierRingbackPreference.allowsReceiveOnly(enabled: enabled, outgoing: outgoing, state: state),
                        enabled && outgoing && state == .connecting)
                }
            }
        }
    }
}

// These tests write real WAV containers with AVFoundation.
final class LocalCallPCMRecordingTests: XCTestCase {
    func testRecordingPublishesBothChannelsAndRejectsPacketsAfterStop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let finalized = expectation(description: "WAV finalized")
        let recording = try CallPCMRecording(directory: directory) { result in
            defer { finalized.fulfill() }
            do {
                let url = try XCTUnwrap(result.get())
                XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
                XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
                XCTAssertEqual(file.fileFormat.channelCount, 2)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_024))
                try file.read(into: buffer)
                let channels = try XCTUnwrap(buffer.int16ChannelData)
                let frames = Int(buffer.frameLength)
                XCTAssertEqual(frames, 320)
                XCTAssertEqual(Array(UnsafeBufferPointer(start: channels[0], count: frames)), Array(repeating: 0x0123, count: 320))
                XCTAssertEqual(Array(UnsafeBufferPointer(start: channels[1], count: frames)), Array(repeating: -52, count: 320))
            } catch { XCTFail("Unable to read finalized recording: \(error)") }
        }
        let feed = CallRecordingFeed()
        feed.attach(recording)
        feed.append(Data(Array(repeating: [UInt8(0x23), 0x01], count: 160).flatMap { $0 }), rate: 8_000, channel: .local)
        feed.append(Data(Array(repeating: [UInt8(0xcc), 0xff], count: 320).flatMap { $0 }), rate: 16_000, channel: .remote)
        feed.finish()
        feed.append(Data(repeating: 0x12, count: 640), rate: 16_000, channel: .local)
        wait(for: [finalized], timeout: 5)
    }

    func testRecordingWithoutMediaDoesNotPublishAnEmptyFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let finalized = expectation(description: "Empty recording discarded")
        let recording = try CallPCMRecording(directory: directory) { result in
            defer { finalized.fulfill() }
            do { XCTAssertNil(try result.get()) }
            catch { XCTFail("Unable to discard empty recording: \(error)") }
        }
        recording.finish()
        wait(for: [finalized], timeout: 5)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".wav") })
    }
}

final class AndroidFilteredSMSHandoffTests: XCTestCase {
    func testLegacyUnmarkedAndAndroidFilteredLocalDeliveryDecode() throws {
        let base: [String: Any] = ["sender": "10002", "content": "测试短信",
            "timestamp": "2026-11-25T04:00:00Z", "delivery_id": "synthetic-1", "sim_slot": "SIM 2"]
        let decoder = AirSIMAPI.makeDecoder()
        let old = try decoder.decode(SMSMessage.self, from: JSONSerialization.data(withJSONObject: base))
        XCTAssertNil(old.androidFiltered)
        var flagged = base
        flagged["android_filtered"] = true
        let blocked = try decoder.decode(SMSMessage.self, from: JSONSerialization.data(withJSONObject: flagged))
        XCTAssertEqual(blocked.androidFiltered, true)
        XCTAssertEqual(blocked.id, old.id)
        XCTAssertEqual(blocked.simSlot, "SIM 2")
        let merged = SMSHistoryPolicy.deduplicated([blocked, old])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.androidFiltered, true)
    }

    func testRuleSnapshotCarriesOnlyRulesAndWhitelist() throws {
        let key = "air.sim.test.sms.rules." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let prefs = HeroSMSFilterPreferences(defaults: defaults)
        prefs.allow(sender: "10001")
        XCTAssertTrue(prefs.replaceLegacyRules([.init(target: .content, keyword: "测试")]))
        let data = try JSONEncoder().encode(AndroidSMSAlertFilter(prefs))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["allow", "rules"])
        XCTAssertEqual(obj["allow"] as? [String], ["10001"])
        XCTAssertEqual((obj["rules"] as? [[String: String]])?.first, ["target": "content", "keyword": "测试"])
    }
}

final class SystemCallHistoryTests: XCTestCase {

    func testFailedQueryDoesNotReportAnEmptyHistory() {
        let error = NSError(domain: "XPC.XPCRichError", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "private data"])
        let failure = SystemHistoryFailure(error)
        XCTAssertTrue(failure.isXPC)
        XCTAssertNil(failure.canRetry)
        XCTAssertFalse(failure.diagnostic.contains("private data"))
        XCTAssertFalse(SystemHistoryReadState.failed(failure).canConfirmEmpty(hasOlder: false))
        XCTAssertFalse(SystemHistoryReadState.idle.canConfirmEmpty(hasOlder: false))
        XCTAssertFalse(SystemHistoryReadState.loading.canConfirmEmpty(hasOlder: false))
        XCTAssertFalse(SystemHistoryReadState.ready.canConfirmEmpty(hasOlder: true))
        XCTAssertTrue(SystemHistoryReadState.ready.canConfirmEmpty(hasOlder: false))
        XCTAssertTrue(SystemHistoryReadState.unsupported.canConfirmEmpty(hasOlder: false))
    }

    func testOnlyExplicitlyInterruptedCocoaConnectionQualifiesForAutomaticRetry() {
        XCTAssertEqual(SystemHistoryFailure(CocoaError(.xpcConnectionInterrupted)).canRetry, true)
        XCTAssertNil(SystemHistoryFailure(CocoaError(.xpcConnectionInvalid)).canRetry)
        XCTAssertNil(SystemHistoryFailure(NSError(domain: "other", code: 1)).canRetry)
    }
    private func entry(_ id: UUID = UUID(), at seconds: TimeInterval = 10, number: String = "5550100") -> SystemCallEntry {
        .init(id: id, date: Date(timeIntervalSince1970: seconds), direction: "incoming", status: "已接通",
              missed: false, duration: 12, participants: [.init(label: number, phone: number)])
    }

    func testPageReplacesUpdatedUUIDAndKeepsCallsFromSameCaller() {
        let before = entry()
        let changed = entry(before.id, at: 20)
        let other = entry(at: 15)
        let page = SystemCallEntry.page([before, other, changed], limit: 1)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.entries, [changed])
        XCTAssertEqual(SystemCallEntry.page([before, other, changed], limit: 2).entries, [changed, other])
    }

    func testHistoryMergeRequiresExactSystemUUID() {
        let system = entry()
        func imported(_ id: String, native: UUID?) -> CallRecord {
            CallRecord(id: id, index: 0, direction: "incoming", state: "ended", number: system.number,
                       startedAt: system.date, updatedAt: system.date, endedAt: nil,
                       missed: false, sourceCallID: native?.uuidString)
        }
        let copy = imported("iphone-import:copy", native: system.id)
        let separate = imported("iphone-import:separate", native: nil)
        let android = imported("agent-call:other", native: nil)
        let records = SystemCallEntry.combinedRecords(android: [android], imported: [copy, separate], system: [system])
        XCTAssertEqual(Set(records.map(\.id)), [android.id, separate.id, system.presentationID])
        XCTAssertEqual(SystemCallEntry.combinedRecords(android: [], imported: [copy], system: []).first?.id, copy.id)
    }

    func testImportedFaceTimeEmailIsNotTreatedAsAnAndroidDialTarget() {
        XCTAssertNil(RecentCallDialPolicy.numberToDial("name@example.invalid", imported: true))
        XCTAssertEqual(RecentCallDialPolicy.numberToDial("tel:%2B1%20555-0100", imported: true), "+15550100")
        XCTAssertEqual(RecentCallDialPolicy.numberToDial("555 0100", imported: true), "5550100")
    }

    func testGroupCallDoesNotPreselectOneParticipant() {
        let group = SystemCallEntry(id: UUID(), date: Date(), direction: "incoming", status: "未接来电",
                                    missed: true, duration: nil, participants: [
                                        .init(label: "First", phone: "5550100"), .init(label: "Second", phone: "5550200")])
        XCTAssertNil(group.record.number)
        XCTAssertEqual(group.displayParticipants, "First、Second")
        XCTAssertTrue(group.record.missed)
        XCTAssertNil(group.record.connectedAt)
    }
}

final class IPhoneMailboxTests: XCTestCase {
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: result) }
        return result
    }

    private func message(_ id: String, line: String = "line-one", outgoing: Bool = false) -> IPhoneCarrierRecord {
        IPhoneCarrierRecord(id: id, lineID: line, lineLabel: line, peer: "5550100",
                            kind: "RCS", body: "fixture", date: Date(timeIntervalSince1970: 100),
                            outgoing: outgoing, status: outgoing ? "发送中" : "")
    }

    @MainActor func testDuplicateReceiveAndTwoLinesStayIsolatedAfterReopen() throws {
        let location = try directory()
        let one = message("1"), two = message("2", line: "line-two")
        let box = IPhoneMailbox(directory: location)
        XCTAssertTrue(try box.insert(one))
        try box.markRead(thread: one.threadID)
        XCTAssertFalse(try box.insert(one))
        XCTAssertTrue(try box.insert(two))
        let reopened = IPhoneMailbox(directory: location)
        XCTAssertNotEqual(one.threadID, two.threadID)
        XCTAssertEqual(Set(try reopened.latestThreads().map(\.id)), Set(["1", "2"]))
        XCTAssertEqual(try reopened.unreadThreads(), Set([two.threadID]))
        try reopened.remove(thread: one.threadID)
        XCTAssertEqual(try reopened.latestThreads().map(\.id), ["2"])
    }

    @MainActor func testLateAcknowledgementsCannotRegressDeliveryOrReadReceipt() throws {
        let box = IPhoneMailbox(directory: try directory())
        let item = message("pending", outgoing: true)
        XCTAssertTrue(try box.insert(item))
        for status in ["已送达", "已发送", "发送未确认"] { try box.updateStatus(id: item.id, to: status) }
        XCTAssertEqual(try box.latestThreads().first?.status, "已送达")
        for status in ["已读", "已送达", "投递异常", "已发送"] { try box.updateStatus(id: item.id, to: status) }
        XCTAssertEqual(try box.latestThreads().first?.status, "已读")
    }

    @MainActor func testImportIsAtomicIdempotentAndReadOnlyThreadsRemainSeparate() throws {
        let box = IPhoneMailbox(directory: try directory())
        let live = message("live")
        XCTAssertTrue(try box.insert(live))
        let messageID = String(repeating: "a", count: 64), callID = String(repeating: "b", count: 64)
        let msg = IPhoneMailbox.Migration.Message(id: messageID, threadID: "backup-thread", title: "5550100",
            direction: "incoming", service: "SMS", text: "import", timestamp: 99, readOnly: true,
            peer: "5550100", sender: nil, line: "line-one")
        func call(_ id: String) -> IPhoneMailbox.Migration.Call {
            .init(id: id, direction: "incoming", service: "cellular", timestamp: 90,
                  number: "5550100", line: "line-two", systemID: nil, duration: 0, answered: false)
        }
        func archive(_ id: String) -> IPhoneMailbox.Migration {
            .init(format: "airsim-iphone-history", version: 1, messages: [msg], calls: [call(id)])
        }
        XCTAssertThrowsError(try box.merge(archive("invalid-id")))
        XCTAssertEqual(try box.latestThreads().map(\.id), [live.id])
        XCTAssertTrue(box.importedCalls.isEmpty)

        let counts = try box.merge(archive(callID))
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        let repeated = try box.merge(archive(callID))
        XCTAssertEqual(repeated.0, 0)
        XCTAssertEqual(repeated.1, 0)
        let imported = try XCTUnwrap(try box.latestThreads().first { $0.importedThread != nil })
        XCTAssertNotEqual(imported.threadID, live.threadID)
        XCTAssertTrue(try box.unreadThreads().contains(live.threadID))
        XCTAssertFalse(try box.unreadThreads().contains(imported.threadID))
        XCTAssertEqual(box.importedCalls.map(\.id), ["iphone-import:" + callID])
        XCTAssertEqual(box.importedCalls.first?.missed, true)
        XCTAssertEqual(box.importedCalls.first?.importedDetails,
                       ImportedCallDetails(service: "cellular", line: "line-two", answered: false, duration: 0))
        XCTAssertNil(box.importedCalls.first?.connectedAt)
        XCTAssertNil(box.importedCalls.first?.endedAt)
        try box.removeImportedCall(id: "iphone-import:" + callID)
        XCTAssertTrue(box.importedCalls.isEmpty)
        XCTAssertEqual(try box.messages(thread: live.threadID, limit: 10).count, 1)
    }

    @MainActor func testImportAddsMissingMediaOnce() throws {
        let box = IPhoneMailbox(directory: try directory())
        let id = String(repeating: "d", count: 64)
        var msg = IPhoneMailbox.Migration.Message(id: id, threadID: "backup-thread", title: "Test", direction: "incoming",
            service: "iMessage", text: "[附件]", timestamp: 100, readOnly: true, peer: nil, sender: nil, line: nil)
        func load() throws {
            _ = try box.merge(.init(format: "airsim-iphone-history", version: 1, messages: [msg], calls: []))
        }
        try load()
        msg.attachments = [.init(name: "one.txt", mimeType: "text/plain", data: Data([65,66]))]
        try load()
        XCTAssertEqual(box.lastImportAttachmentCount, 1)
        try load()
        XCTAssertEqual(box.lastImportAttachmentCount, 0)
        let thread = try XCTUnwrap(try box.latestThreads().first)
        XCTAssertEqual(thread.attachments.count, 1)
        XCTAssertEqual(try box.attachment(id: thread.id, index: 0), Data([65,66]))
    }

    @MainActor func testExclusiveDatabaseLockCannotReplaceMessagesWithEmptyStorage() throws {
        let location = try directory()
        let original = IPhoneMailbox(directory: location)
        XCTAssertTrue(try original.insert(message("before")))
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(location.appendingPathComponent("mail.sqlite").path, &lock,
                                       SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(lock) }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try original.requireWritable())
        XCTAssertThrowsError(try original.insert(message("during")))
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        let reopened = IPhoneMailbox(directory: location)
        XCTAssertNoThrow(try reopened.requireWritable())
        XCTAssertEqual(try reopened.latestThreads().map(\.id), ["before"])
        XCTAssertTrue(try reopened.insert(message("after", line: "line-two")))
        XCTAssertEqual(Set(try reopened.latestThreads().map(\.id)), Set(["before", "after"]))
    }

    @MainActor func testUnreadableStoreIsReportedWithoutReplacingOriginalBytes() throws {
        let location = try directory()
        let path = location.appendingPathComponent("mail.sqlite")
        let original = Data(repeating: 0x61, count: 512)
        try original.write(to: path)
        let box = IPhoneMailbox(directory: location)
        XCTAssertNotNil(box.lastError)
        XCTAssertThrowsError(try box.insert(message("must-not-replace")))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }
}

extension SystemCallHistoryTests {
    private func signingTLV(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        let n = bytes.count
        if n < 128 { return [tag, UInt8(n)] + bytes }
        if n < 256 { return [tag, 0x81, UInt8(n)] + bytes }
        return [tag, 0x82, UInt8(n >> 8), UInt8(n & 255)] + bytes
    }

    private func signingImage(der: [UInt8]?, xml: [UInt8]? = nil) -> Data {
        func word(_ n: Int, little: Bool = false) -> [UInt8] {
            let big: [UInt8] = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: n >> $0) }
            return little ? Array(big.reversed()) : big
        }
        var slots: [(Int, [UInt8])] = []
        if let xml { slots.append((5, word(0xfade7171) + word(xml.count + 8) + xml)) }
        if let der { slots.append((7, word(0xfade7172) + word(der.count + 8) + der)) }
        let start = 12 + 8 * slots.count
        var indices: [UInt8] = [], payload: [UInt8] = []
        for (id, blob) in slots {
            indices += word(id) + word(start + payload.count)
            payload += blob
        }
        var signature = word(0xfade0cc0) + word(start + payload.count) + word(slots.count)
        signature += indices + payload
        let header = [0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0].flatMap { word($0, little: true) }
        let command = [0x1d, 16, 48, signature.count].flatMap { word($0, little: true) }
        return Data(header + command + signature)
    }

    private func signingEntry(_ suffix: String, _ value: [UInt8]) -> [UInt8] {
        let key = Array(("com.apple.developer." + suffix).utf8)
        return signingTLV(0x30, signingTLV(0x0c, key) + value)
    }

    private func signingProfile(_ fields: [String: Any]) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": fields], format: .xml, options: 0)
        let oid: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 7]
        let split = plist.count / 2
        let chunks = signingTLV(4, Array(plist.prefix(split))) + signingTLV(4, Array(plist.dropFirst(split)))
        let content = signingTLV(6, oid + [1]) + signingTLV(0xa0, signingTLV(0x24, chunks))
        let signed = signingTLV(2, [1]) + signingTLV(0x31, []) + signingTLV(0x30, content) + signingTLV(0x31, [])
        // CMS allows indefinite lengths and split octet strings. An unsigned fixture is sufficient to read fields.
        return Data([0x30, 0x80] + signingTLV(6, oid + [2]) + signingTLV(0xa0, signingTLV(0x30, signed)) + [0, 0])
    }

    func testSigningReadsModernDERBeforeXMLAndChecksStrictProfileTypes() throws {
        let entries = signingEntry("dialing-app", [1, 1, 255]) + signingEntry("calling-app", [1, 1, 0])
        let modern = signingTLV(0x70, signingTLV(2, [1]) + signingTLV(0xb0, entries))
        let xml = try PropertyListSerialization.data(fromPropertyList: ["com.apple.developer.dialing-app": false],
                                                       format: .xml, options: 0)
        let profile = try signingProfile([
            "com.apple.developer.dialing-app": true,
            "com.apple.developer.messaging-app": 1
        ])
        let rows = IPhoneSigningDiagnostics.rows(executable: signingImage(der: modern, xml: Array(xml)), profile: profile)
        XCTAssertEqual(rows[0].1, "主 App 签名 · DER · false\n描述文件可读字段 · 未声明")
        XCTAssertEqual(rows[1].1, "主 App 签名 · DER · true\n描述文件可读字段 · true")
        XCTAssertEqual(rows[2].1, "主 App 签名 · DER · 未声明\n描述文件可读字段 · 字段类型异常")
    }

    func testSigningReadsLegacyDERAndMarksMalformedAndFallbackSources() throws {
        let legacy = signingTLV(0x31, signingEntry("dialing-app", [2, 1, 1]))
        let legacyRows = IPhoneSigningDiagnostics.rows(executable: signingImage(der: legacy), profile: nil)
        XCTAssertTrue(legacyRows[1].1.contains("DER · 字段类型异常"))
        let truncated = Array(legacy.dropLast())
        let xml = try PropertyListSerialization.data(fromPropertyList: ["com.apple.developer.dialing-app": true],
                                                       format: .xml, options: 0)
        let fallback = IPhoneSigningDiagnostics.rows(executable: signingImage(der: truncated, xml: Array(xml)), profile: nil)
        XCTAssertTrue(fallback[1].1.contains("XML（DER 不可读取） · true"))
        let invalid = IPhoneSigningDiagnostics.rows(executable: signingImage(der: truncated), profile: Data(xml))
        XCTAssertTrue(invalid[1].1.contains("主 App 签名 · 不可读取"))
        XCTAssertTrue(invalid[1].1.contains("描述文件不可读取"))
        let shortImage = Data(signingImage(der: legacy).dropLast())
        XCTAssertTrue(IPhoneSigningDiagnostics.rows(executable: shortImage, profile: nil)[1].1.contains("不可读取"))
    }
}
