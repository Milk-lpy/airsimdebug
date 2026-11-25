import AVFoundation
import Foundation
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
    func testBothExplicitSlotsKeepOriginalCallbackNumber() {
        let request = CallbackSIMDialRequest(agentID: "A", number: "+8613800138000", slots: slots)
        for slot in slots { XCTAssertTrue(request.permits(agentID: "A", liveSlots: slots, slotID: slot.id, callInProgress: false)) }
        XCTAssertEqual(request.number, "+8613800138000")
    }
    func testRemovedSIMAndDeviceSwitchCannotDialAnotherCard() {
        let request = CallbackSIMDialRequest(agentID: "A", number: "10086", slots: slots)
        XCTAssertFalse(request.permits(agentID: "B", liveSlots: slots, slotID: "voice-two", callInProgress: false))
        XCTAssertFalse(request.permits(agentID: "A", liveSlots: [slots[0]], slotID: "voice-two", callInProgress: false))
        XCTAssertFalse(request.permits(agentID: "A", liveSlots: slots, slotID: "unknown", callInProgress: false))
    }
    func testIncomingCallBlocksPendingCallback() {
        let request = CallbackSIMDialRequest(agentID: "A", number: "10086", slots: slots)
        XCTAssertFalse(request.permits(agentID: "A", liveSlots: slots, slotID: "voice-one", callInProgress: true))
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
