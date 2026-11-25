import Combine
import Foundation
import TelephonyMessagingKit
import UIKit
import UniformTypeIdentifiers
import UserNotifications

struct IPhoneMessagingLine: Identifiable, Hashable {
    let id: String
    let label: String
    let supportsSMS: Bool
    let supportsMMS: Bool
    let supportsRCS: Bool
}

@MainActor
final class IPhoneCarrierMessaging: ObservableObject {
    static let shared = IPhoneCarrierMessaging()

    @Published private(set) var isConfigured = false
    @Published private(set) var lines: [IPhoneMessagingLine] = []
    @Published private(set) var lastError: String?
    @Published private(set) var notificationsEnabled: Bool?
    private var listeners: [Task<Void, Never>] = []
    private var pendingWrites: [String: IPhoneCarrierRecord] = [:]
    private var activeDownloads: Set<String> = []
    private init() {}

    func requestNotifications() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch { lastError = error.localizedDescription }
        await refreshNotificationPermission()
    }

    private func refreshNotificationPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsEnabled = [.authorized, .provisional, .ephemeral].contains(status)
    }

    func refresh() {
        Task {
            await refreshNotificationPermission()
            for record in pendingWrites.values.sorted(by: { $0.date < $1.date }) {
                do { try await receive(record) } catch { lastError = error.localizedDescription }
            }
            if #available(iOS 26, *), isConfigured {
                do {
                    for record in try IPhoneMailbox.shared.pendingRCSDownloads() { enqueueDownload(for: record) }
                } catch { lastError = error.localizedDescription }
            }
        }
        guard #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone,
              TelephonyMessagingSession.shared.isConfiguredForCarrierMessaging else {
            listeners.forEach { $0.cancel() }
            listeners.removeAll()
            lines = []
            isConfigured = false
            lastError = nil
            return
        }
        isConfigured = true
        let session = TelephonyMessagingSession.shared
        refreshLines(session)
        guard listeners.isEmpty else { return }
        listen { [self] in
            for await _ in session.cellularServiceStateUpdates { refreshLines(session) }
        }
        listen { [self] in
            let notifications = try session.smsService.incomingMessageNotifications
            for await entry in notifications {
                do {
                    let sms = entry.message
                    let record = try incomingRecord(kind: "SMS", id: String(sms.messageID.rawValue),
                        service: sms.cellularServiceID, peer: sms.handle.phoneNumber, body: sms.content.body)
                    try await receive(record)
                } catch { lastError = error.localizedDescription }
            }
        }
        listen { [self] in
            let notifications = try session.mmsService.incomingMessageNotifications
            for await entry in notifications {
                do {
                    let message: MMSMessage
                    if #available(iOS 26.1, *) { message = entry.message }
                    else {
                        message = try await session.mmsService.receiveMessage(using: entry.cellularServiceID,
                                                                              messageID: entry.messageID)
                    }
                    try await receive(mmsRecord(message))
                } catch { lastError = error.localizedDescription }
            }
        }
        listen { [self] in
            let notifications = try session.rcsService.incomingMessageNotifications
            for await entry in notifications {
                do { try await receiveRCS(entry) } catch { lastError = error.localizedDescription }
            }
        }
        listen { [self] in
            let notifications = try session.smsService.viabilityNotifications
            for await _ in notifications { refreshLines(session) }
        }
        listen { [self] in
            let notifications = try session.mmsService.viabilityNotifications
            for await _ in notifications { refreshLines(session) }
        }
        listen { [self] in
            let notifications = try session.rcsService.viabilityNotifications
            for await _ in notifications { refreshLines(session) }
        }
    }

    @available(iOS 26, *)
    private func listen(_ operation: @escaping @MainActor () async throws -> Void) {
        listeners.append(Task {
            var delay = 2
            while !Task.isCancelled && TelephonyMessagingSession.shared.isConfiguredForCarrierMessaging {
                do { try await operation() } catch {
                    if !Task.isCancelled { lastError = error.localizedDescription }
                }
                guard !Task.isCancelled else { return }
                if !TelephonyMessagingSession.shared.isConfiguredForCarrierMessaging { refresh(); return }
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
                catch { return }
                delay = min(delay * 2, 120)
            }
        })
    }

    @available(iOS 26, *)
    private func refreshLines(_ session: TelephonyMessagingSession) {
        do {
            lines = try session.cellularServices.map { state in
                try IPhoneMessagingLine(id: encodedKey(state.id), label: state.label,
                    supportsSMS: session.smsService.isViable(for: state.id),
                    supportsMMS: session.mmsService.isViable(for: state.id),
                    supportsRCS: session.rcsService.isViable(for: state.id))
            }
        } catch {
            lines = []
            lastError = error.localizedDescription
        }
    }

    private func encodedKey<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value).base64EncodedString()
    }

    private func decodeGroup<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
        guard let data = Data(base64Encoded: key) else { throw MessagingError.invalidGroup }
        return try JSONDecoder().decode(type, from: data)
    }

    static func mmsGroupRecipients(_ groupID: String) -> [String] {
        guard let data = Data(base64Encoded: groupID) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func mmsGroupID(from sender: String, recipients: [String]) throws -> String? {
        // Apple omits the current user in its incoming MMS example. A sender
        // plus a single different address already forms a group.
        let members = Set(([sender] + recipients).filter { !$0.isEmpty }).sorted()
        guard !sender.isEmpty, members.count > 1 else { return nil }
        return try JSONEncoder().encode(members).base64EncodedString()
    }

    private func recordID(_ raw: String, kind: String, line: String, outgoing: Bool) -> String {
        "\(kind):\(line):\(outgoing ? "out" : "in"):\(raw)"
    }

    @available(iOS 26, *)
    private func incomingRecord(kind: String, id: String, service: CellularServiceID,
                                peer: String, body: String, groupID: String? = nil) throws -> IPhoneCarrierRecord {
        let line = try encodedKey(service)
        return IPhoneCarrierRecord(id: recordID(id, kind: kind, line: line, outgoing: false),
            lineID: line, lineLabel: lines.first(where: { $0.id == line })?.label ?? "iPhone",
            peer: peer, groupID: groupID, kind: kind, body: body, date: Date(), outgoing: false)
    }

    @discardableResult
    private func receive(_ record: IPhoneCarrierRecord) async throws -> Bool {
        let inserted: Bool
        do {
            inserted = try IPhoneMailbox.shared.insert(record)
            pendingWrites.removeValue(forKey: record.id)
        } catch {
            // A cold carrier wake can precede the first unlock after reboot.
            pendingWrites[record.id] = record
            throw error
        }
        guard inserted else { return false }
        if UIApplication.shared.applicationState != .active {
            let note = UNMutableNotificationContent()
            note.title = "iPhone \(record.kind)"
            note.body = "收到来自\(record.peer)的新消息"
            note.sound = .default
            note.userInfo = ["event": "iphone_carrier_message", "record_id": record.id]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: record.id, content: note, trigger: nil))
        }
        return true
    }

    @available(iOS 26, *)
    private func mmsRecord(_ message: MMSMessage) throws -> IPhoneCarrierRecord {
        let content = message.content
        let from = content.from?.phoneNumber ?? ""
        let recipients = content.recipients.map(\.phoneNumber)
        let group = try Self.mmsGroupID(from: from, recipients: recipients)
        var text = [content.subject].compactMap { $0 }.filter { !$0.isEmpty }
        var attachments: [IPhoneCarrierAttachment] = []
        for part in content.parts {
            if part.contentType?.conforms(to: .plainText) == true,
               let value = String(data: part.data, encoding: .utf8),
               case .inline = part.disposition {
                text.append(value)
            } else {
                attachments.append(IPhoneCarrierAttachment(name: part.filename.isEmpty ? "彩信附件" : part.filename,
                    mimeType: part.contentType?.preferredMIMEType ?? "application/octet-stream", data: part.data))
            }
        }
        var record = try incomingRecord(kind: "MMS", id: String(message.messageID.rawValue),
            service: message.cellularServiceID, peer: from.isEmpty ? "未知发件人" : from,
            body: text.joined(separator: "\n"), groupID: group)
        record.recipients = recipients
        record.attachments = attachments
        return record
    }

    @available(iOS 26, *)
    private func receiveRCS(_ entry: RCSService.IncomingMessageNotification) async throws {
        let message = entry.message
        let sender: String
        var group = entry.groupContext?.handle
        switch message.handle {
        case .uri(let address): sender = address.rawValue
        case .group(let handle): group = handle; sender = "RCS 群聊"
        @unknown default: sender = "未知发件人"
        }
        var encrypted = false
        if #available(iOS 26.5, *) { encrypted = entry.groupContext?.isEndToEndEncrypted == true }
        var content = message.content
        if #available(iOS 27, *), case let .reply(reply) = content {
            switch reply.content {
            case .text(let value): content = .text(value)
            case .fileTransfer(let value): content = .fileTransfer(value)
            case .geolocationPush(let value): content = .geolocationPush(value)
            @unknown default: break
            }
        }
        var body: String
        var metadata: RCSFileTransferMetadata?
        var attachments: [IPhoneCarrierAttachment] = []
        switch content {
        case .text(let value):
            body = value.body
            if #available(iOS 26.5, *) { encrypted = encrypted || value.isEndToEndEncrypted }
        case .fileTransfer(let file):
            metadata = file.fileMetadata
            body = file.fileMetadata.fileName ?? "RCS 附件"
            attachments = [IPhoneCarrierAttachment(name: "RCS-附件信息.json", mimeType: "application/vnd.airsim.rcs-transfer+json",
                data: try JSONEncoder().encode(file.fileMetadata))]
            if #available(iOS 26.5, *) { encrypted = encrypted || file.isEndToEndEncrypted }
        case .geolocationPush(let location):
            body = [location.description, "\(location.latitude), \(location.longitude)"].compactMap { $0 }.joined(separator: "\n")
            if #available(iOS 26.5, *) { encrypted = encrypted || location.isEndToEndEncrypted }
        case .dispositionNotification(let receipt):
            let status: String
            switch receipt.disposition {
            case .delivered, .interworkingDelivered: status = "已送达"
            case .displayed: status = "已读"
            default: status = "投递异常"
            }
            let lineID = try encodedKey(message.cellularServiceID)
            try IPhoneMailbox.shared.updateStatus(id: recordID(receipt.disposedMessageID.rawValue,
                kind: "RCS", line: lineID, outgoing: true), to: status)
            return
        case .composingIndicator: return
        default:
            body = "RCS 富媒体消息"
            attachments = [IPhoneCarrierAttachment(name: "RCS-消息.json", mimeType: "application/json",
                data: try JSONEncoder().encode(message))]
            if #available(iOS 27, *) {
                switch content {
                case .reaction(let item): encrypted = encrypted || item.isEndToEndEncrypted
                case .customReaction(let item): encrypted = encrypted || item.isEndToEndEncrypted
                default: break
                }
            }
        }
        var record = try incomingRecord(kind: "RCS", id: message.id.rawValue, service: message.cellularServiceID,
            peer: sender, body: body, groupID: try group.map { try encodedKey($0) })
        record.attachments = attachments
        record.requiresEncryptedReply = encrypted
        let inserted = try await receive(record)
        if inserted, metadata != nil { enqueueDownload(for: record) }
    }

    @available(iOS 26, *)
    private func enqueueDownload(for record: IPhoneCarrierRecord) {
        guard isConfigured, !activeDownloads.contains(record.id),
              let reference = record.attachments.first(where: { $0.mimeType == "application/vnd.airsim.rcs-transfer+json" }),
              let metadata = try? JSONDecoder().decode(RCSFileTransferMetadata.self, from: reference.data),
              metadata.expirationDate > Date(), let data = Data(base64Encoded: record.lineID),
              let service = try? JSONDecoder().decode(CellularServiceID.self, from: data) else { return }
        activeDownloads.insert(record.id)
        Task {
            defer { activeDownloads.remove(record.id) }
            do {
                let attachment = try await download(metadata, service: service)
                try IPhoneMailbox.shared.updateAttachments(id: record.id, to: [attachment])
            } catch { lastError = error.localizedDescription }
        }
    }

    @available(iOS 26, *)
    private func download(_ file: RCSFileTransferMetadata, service: CellularServiceID) async throws -> IPhoneCarrierAttachment {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let request: RCSService.FileDownloadRequest
        if #available(iOS 26.5, *) {
            request = RCSService.FileDownloadRequest(cellularServiceID: service, fileMetadata: file,
                                                     destinationFileURL: destination)
        } else {
            request = RCSService.FileDownloadRequest(cellularServiceID: service, fileURL: file.url,
                                                     destinationFileURL: destination)
        }
        let result = try await TelephonyMessagingSession.shared.rcsService.download(request)
        return try IPhoneCarrierAttachment(name: result.suggestedFileName ?? file.fileName ?? "RCS 附件",
            mimeType: (result.contentType ?? file.contentType)?.preferredMIMEType ?? "application/octet-stream",
            data: Data(contentsOf: destination, options: .mappedIfSafe))
    }

    func send(_ body: String, to peer: String, lineID: String, kind: String = "SMS", groupID: String? = nil,
              attachments: [IPhoneCarrierAttachment] = [], encrypted: Bool = false) async throws {
        guard #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone,
              TelephonyMessagingSession.shared.isConfiguredForCarrierMessaging else { throw MessagingError.unavailable }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            throw MessagingError.empty
        }
        let session = TelephonyMessagingSession.shared
        guard let state = try session.cellularServices.first(where: { try encodedKey($0.id) == lineID }) else {
            throw MessagingError.missingLine
        }
        let numericID = UInt32.random(in: 1...UInt32.max)
        let messageID = kind == "RCS" ? UUID().uuidString : String(numericID)
        var recipients = [peer]
        let rcsDestination: RCSHandle?
        switch kind {
        case "SMS":
            guard !encrypted, groupID == nil, attachments.isEmpty,
                  session.smsService.isViable(for: state.id) else { throw MessagingError.unavailable }
            recipients = [try validatedAddress(peer)]
            rcsDestination = nil
        case "MMS":
            guard !encrypted, session.mmsService.isViable(for: state.id) else { throw MessagingError.unavailable }
            if let groupID { recipients = try decodeGroup(groupID, as: [String].self) }
            guard !recipients.isEmpty else { throw MessagingError.invalidGroup }
            recipients = try recipients.map(validatedAddress)
            rcsDestination = nil
        case "RCS":
            guard session.rcsService.isViable(for: state.id) else { throw MessagingError.unavailable }
            guard attachments.isEmpty || (attachments.count == 1 && body.isEmpty) else { throw MessagingError.rcsFile }
            if encrypted, #unavailable(iOS 26.5) { throw MessagingError.encryptionUnavailable }
            if let groupID { rcsDestination = .group(try decodeGroup(groupID, as: RCSHandle.Group.self)) }
            else if peer.hasPrefix("tel:") || peer.hasPrefix("sip:") || peer.hasPrefix("sips:") {
                rcsDestination = .uri(RCSHandle.URI(rawValue: peer))
            } else { rcsDestination = RCSHandle.phoneNumber(try validatedAddress(peer)) }
            guard rcsDestination != nil else { throw MessagingError.invalidAddress }
        default: throw MessagingError.unavailable
        }
        let id = recordID(messageID, kind: kind, line: lineID, outgoing: true)
        var record = IPhoneCarrierRecord(id: id, lineID: lineID, lineLabel: state.label, peer: peer,
            groupID: groupID, kind: kind, body: body, date: Date(), outgoing: true, status: "发送中")
        record.attachments = attachments
        record.recipients = recipients
        record.requiresEncryptedReply = encrypted
        guard try IPhoneMailbox.shared.insert(record) else { throw MessagingError.duplicate }
        do {
            switch kind {
            case "SMS":
                try await session.smsService.sendMessage(TelephonyMessagingKit.SMSMessage(cellularServiceID: state.id,
                    handle: SMSHandle(phoneNumber: recipients[0]), messageID: SMSMessageID(rawValue: numericID),
                    content: SMSContent(body: body)))
            case "MMS":
                var parts = attachments.map { file in
                    MMSPartContent(data: file.data, contentType: UTType(mimeType: file.mimeType),
                        contentID: UUID().uuidString, disposition: .attachment, fileName: file.name)
                }
                if !body.isEmpty {
                    parts.insert(MMSPartContent(data: Data(body.utf8), contentType: .plainText,
                        contentID: UUID().uuidString, disposition: .inline, fileName: "text.txt"), at: 0)
                }
                let content = MMSContent(parts: parts, recipients: recipients.map { MMSHandle(phoneNumber: $0) })
                try await session.mmsService.sendMessage(MMSMessage(cellularServiceID: state.id,
                    messageID: MMSMessageID(rawValue: numericID), content: content))
            default:
                guard let destination = rcsDestination else { throw MessagingError.invalidAddress }
                try await sendRCS(body, file: attachments.first, to: destination, using: state.id,
                    messageID: RCSMessageID(rawValue: messageID), encrypted: encrypted)
            }
        } catch {
            try IPhoneMailbox.shared.updateStatus(id: id, to: "发送未确认")
            throw error
        }
        do { try IPhoneMailbox.shared.updateStatus(id: id, to: "已发送") }
        catch {
            // The carrier already accepted this message. Keep the send successful so UI won't invite a duplicate.
            lastError = "消息已提交，更新本机状态失败：\(error.localizedDescription)"
        }
    }

    private func validatedAddress(_ raw: String) throws -> String {
        guard let value = SystemCommunicationURL.dialableNumber(from: raw),
              !value.contains("*"), !value.contains("#") else { throw MessagingError.invalidAddress }
        return value
    }

    @available(iOS 26, *)
    private func sendRCS(_ body: String, file: IPhoneCarrierAttachment?, to destination: RCSHandle,
                         using line: CellularServiceID, messageID: RCSMessageID, encrypted: Bool) async throws {
        let service = TelephonyMessagingSession.shared.rcsService
        if let file {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = (file.name as NSString).lastPathComponent
            let url = directory.appendingPathComponent(["", ".", "..", "/"].contains(name) ? "attachment" : name)
            try file.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var upload = RCSService.FileUploadRequest(cellularServiceID: line, fileURL: url,
                                                       contentType: UTType(mimeType: file.mimeType))
            if #available(iOS 26.5, *) { upload.isEndToEndEncrypted = encrypted }
            let metadata = try await service.upload(upload)
            let transfer = RCSMessage.FileTransfer(fileMetadata: metadata.fileMetadata, thumbnailMetadata: metadata.thumbnailMetadata)
            if #available(iOS 26.5, *), encrypted {
                _ = try await service.sendEncryptedMessageRequest(.init(content: transfer, destination: destination,
                                                                         cellularServiceID: line, messageID: messageID))
            } else { try await service.sendMessage(transfer, to: destination, using: line, messageID: messageID) }
        } else {
            let text = RCSMessage.Text(body: body)
            if #available(iOS 26.5, *), encrypted {
                _ = try await service.sendEncryptedMessageRequest(.init(content: text, destination: destination,
                                                                         cellularServiceID: line, messageID: messageID))
            } else { try await service.sendMessage(text, to: destination, using: line, messageID: messageID) }
        }
    }

    private enum MessagingError: LocalizedError {
        case unavailable, missingLine, invalidAddress, invalidGroup, empty, duplicate, rcsFile, encryptionUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: return "所选线路暂时无法使用此消息协议，请检查默认运营商消息 App 和线路状态。"
            case .missingLine: return "所选 iPhone 线路已不可用。"
            case .invalidAddress: return "收件地址无效。"
            case .invalidGroup: return "无法恢复原有群组，请重新选择收件人。"
            case .empty: return "请输入消息或选择附件。"
            case .duplicate: return "此条消息已保存，请检查发件记录。"
            case .rcsFile: return "每条 RCS 附件消息可单独发送一个文件，文字请另发一条。"
            case .encryptionUnavailable: return "此会话需要端到端加密，目前系统版本不支持发送。"
            }
        }
    }
}
