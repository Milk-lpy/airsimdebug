import Foundation
import SQLite3
import SwiftUI

struct IPhoneCarrierAttachment: Codable {
    let name: String
    let mimeType: String
    var data: Data
}

struct IPhoneCarrierRecord: Codable, Identifiable {
    let id: String
    let lineID: String
    let lineLabel: String
    let peer: String
    var groupID: String? = nil
    let kind: String
    let body: String
    let date: Date
    let outgoing: Bool
    var status: String = ""
    var attachments: [IPhoneCarrierAttachment] = []
    var recipients: [String] = []
    var requiresEncryptedReply: Bool = false
    var importedThread: String? = nil
    var importedTitle: String? = nil
    var threadID: String {
        if let importedThread { return "import/" + importedThread }
        let handle = peer.lowercased().hasPrefix("tel:") ? String(peer.dropFirst(4)) : peer
        let participant = groupID ?? (SystemCommunicationURL.dialableNumber(from: handle) ?? handle)
        return [lineID, kind, groupID == nil ? "person" : "group", participant]
            .map { Data($0.utf8).base64EncodedString() }.joined(separator: "/")
    }
    var title: String { importedTitle ?? (groupID == nil ? peer : "群组 · " + (recipients.isEmpty ? peer : recipients.joined(separator: "、"))) }
}

struct IPhoneMailboxRoute: Identifiable {
    let id: String
}

private enum MailboxValue {
    case string(String), blob(Data), number(Double)
}

enum IPhoneMailboxError: LocalizedError {
    case store, invalidImport, tooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .store: return "无法读写 iPhone 本机记录。请确认手机已解锁并有可用存储空间。"
        case .invalidImport: return "文件内容或格式无效。请选择由 AirSIM 历史记录工具导出的 JSON 文件。"
        case .tooLarge: return "迁移文件超过 128 MB，请分批导出。"
        case .unavailable: return "这份记录已不可用。"
        }
    }
}

/// The native carrier inbox is device-local. It never enters the Android sync model.
@MainActor
final class IPhoneMailbox: ObservableObject {
    static let shared = IPhoneMailbox()
    @Published private(set) var revision = 0
    @Published private(set) var importedCalls: [CallRecord] = []
    private(set) var lastImportAttachmentCount = 0
    @Published var presented: IPhoneMailboxRoute?
    @Published var lastError: String?
    private var database: OpaquePointer?
    private let directory: URL
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPhoneCarrier", isDirectory: true)
        encoder.outputFormat = .binary
        do { try reloadCalls() } catch { lastError = error.localizedDescription }
    }
    deinit { sqlite3_close(database) }

    private func db() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var handle: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("mail.sqlite").path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { sqlite3_close(handle); throw IPhoneMailboxError.store }
        sqlite3_busy_timeout(handle, 2500)
        let schema = """
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, thread TEXT NOT NULL, date REAL NOT NULL, unread INTEGER NOT NULL, meta BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS message_order ON messages(thread,date DESC,id DESC);
        CREATE TABLE IF NOT EXISTS parts (message TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE, pos INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(message,pos));
        CREATE TABLE IF NOT EXISTS encrypted_threads (thread TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS calls (id TEXT PRIMARY KEY, date REAL NOT NULL, data BLOB NOT NULL);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle); throw IPhoneMailboxError.store
        }
        database = handle
        return handle
    }

    private func statement<T>(_ sql: String, _ values: [MailboxValue] = [],
                              _ action: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(try db(), sql, -1, &prepared, nil) == SQLITE_OK,
              let prepared else { throw IPhoneMailboxError.store }
        defer { sqlite3_finalize(prepared) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .string(let string): result = sqlite3_bind_text(prepared, index, string, -1, Self.transient)
            case .number(let value): result = sqlite3_bind_double(prepared, index, value)
            case .blob(let data):
                result = data.isEmpty ? sqlite3_bind_zeroblob(prepared, index, 0) : data.withUnsafeBytes {
                    sqlite3_bind_blob64(prepared, index, $0.baseAddress, UInt64($0.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else { throw IPhoneMailboxError.store }
        }
        return try action(prepared)
    }

    @discardableResult private func execute(_ sql: String, _ values: [MailboxValue] = []) throws -> Int32 {
        try statement(sql, values) { s in
            guard sqlite3_step(s) == SQLITE_DONE else { throw IPhoneMailboxError.store }
            return sqlite3_changes(sqlite3_db_handle(s))
        }
    }
    private func transaction<T>(_ action: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try action(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func rows(_ sql: String, _ values: [MailboxValue] = []) throws -> [Data] {
        try statement(sql, values) { s in
            var results: [Data] = []
            while true {
                switch sqlite3_step(s) {
                case SQLITE_DONE: return results
                case SQLITE_ROW:
                    let count = Int(sqlite3_column_bytes(s, 0))
                    if let ptr = sqlite3_column_blob(s, 0) { results.append(Data(bytes: ptr, count: count)) }
                    else { results.append(Data()) }
                default: throw IPhoneMailboxError.store
                }
            }
        }
    }
    private func metadata(_ record: IPhoneCarrierRecord) throws -> Data {
        var copy = record
        copy.attachments = record.attachments.map { IPhoneCarrierAttachment(name: $0.name, mimeType: $0.mimeType, data: Data()) }
        return try encoder.encode(copy)
    }
    private func addParts(_ id: String, _ parts: [IPhoneCarrierAttachment]) throws {
        for (index, part) in parts.enumerated() {
            try execute("INSERT INTO parts VALUES (?,?,?)", [.string(id), .number(Double(index)), .blob(part.data)])
        }
    }
    private func add(_ item: IPhoneCarrierRecord, unread: Bool) throws -> Bool {
        let inserted = try execute("INSERT INTO messages VALUES (?,?,?,?,?) ON CONFLICT(id) DO NOTHING", [
            .string(item.id), .string(item.threadID), .number(item.date.timeIntervalSince1970),
            .number(unread ? 1 : 0), .blob(try metadata(item))])
        if inserted > 0 {
            try addParts(item.id, item.attachments)
            if item.requiresEncryptedReply {
                try execute("INSERT OR IGNORE INTO encrypted_threads VALUES (?)", [.string(item.threadID)])
            }
        }
        return inserted > 0
    }
    /// Test the same write lock and file protection as a message insert before draining carrier queues.
    func requireWritable() throws {
        try transaction { }
    }

    @discardableResult func insert(_ message: IPhoneCarrierRecord) throws -> Bool {
        let added = try transaction { try add(message, unread: !message.outgoing) }
        if added { revision &+= 1 }; return added
    }
    private func record(id: String) throws -> IPhoneCarrierRecord? {
        try rows("SELECT meta FROM messages WHERE id=?", [.string(id)]).first.map { try decoder.decode(IPhoneCarrierRecord.self, from: $0) }
    }
    func updateStatus(id: String, to status: String) throws {
        guard var item = try record(id: id), item.status != status else { return }
        let order = ["发送中": 0, "发送未确认": 1, "已发送": 2, "投递异常": 3, "已送达": 4, "已读": 5]
        if let old = order[item.status], let next = order[status], next < old { return }
        if item.status == "已读" || (item.status == "已送达" && order[status] == nil) { return }
        item.status = status
        try execute("UPDATE messages SET meta=? WHERE id=?", [.blob(try metadata(item)), .string(id)])
        revision &+= 1
    }
    func updateAttachments(id: String, to attachments: [IPhoneCarrierAttachment]) throws {
        guard var item = try record(id: id) else { throw IPhoneMailboxError.unavailable }
        item.attachments = attachments
        try transaction {
            try execute("UPDATE messages SET meta=? WHERE id=?", [.blob(try metadata(item)), .string(id)])
            try execute("DELETE FROM parts WHERE message=?", [.string(id)])
            try addParts(id, attachments)
        }
        revision &+= 1
    }
    func attachment(id: String, index: Int) throws -> Data {
        guard let data = try rows("SELECT data FROM parts WHERE message=? AND pos=?", [.string(id), .number(Double(index))]).first else { throw IPhoneMailboxError.unavailable }
        return data
    }
    func pendingRCSDownloads() throws -> [IPhoneCarrierRecord] {
        // Only fetch the transfer descriptor bytes. Attachments belonging to other messages stay on disk.
        try rows("SELECT meta FROM messages WHERE id LIKE 'RCS:%'").compactMap { data in
            var item = try decoder.decode(IPhoneCarrierRecord.self, from: data)
            guard !item.outgoing, let pos = item.attachments.firstIndex(where: { $0.mimeType == "application/vnd.airsim.rcs-transfer+json" }) else { return nil }
            item.attachments[pos].data = try attachment(id: item.id, index: pos)
            return item
        }
    }
    func latestThreads(matching search: String = "") throws -> [IPhoneCarrierRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            var seen = Set<String>()
            return try rows("SELECT meta FROM messages ORDER BY date DESC,id DESC").compactMap {
                let item = try decoder.decode(IPhoneCarrierRecord.self, from: $0)
                guard !seen.contains(item.threadID), [item.title, item.peer, item.body, item.lineLabel].contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { return nil }
                seen.insert(item.threadID); return item
            }
        }
        let sql = """
        SELECT m.meta FROM messages m WHERE m.id=(
          SELECT t.id FROM messages t WHERE t.thread=m.thread ORDER BY t.date DESC,t.id DESC LIMIT 1)
        ORDER BY m.date DESC,m.id DESC
        """
        return try rows(sql).map { try decoder.decode(IPhoneCarrierRecord.self, from: $0) }
    }
    func messages(thread: String, limit: Int) throws -> [IPhoneCarrierRecord] {
        try rows("SELECT meta FROM messages WHERE thread=? ORDER BY date DESC,id DESC LIMIT ?",
                 [.string(thread), .number(Double(limit))]).reversed().map { try decoder.decode(IPhoneCarrierRecord.self, from: $0) }
    }
    func requiresEncryptedReplies(thread: String) throws -> Bool {
        try !rows("SELECT CAST(thread AS BLOB) FROM encrypted_threads WHERE thread=?", [.string(thread)]).isEmpty
    }
    func markRead(thread: String) throws {
        if try execute("UPDATE messages SET unread=0 WHERE thread=? AND unread=1", [.string(thread)]) > 0 { revision &+= 1 }
    }
    func unreadThreads() throws -> Set<String> {
        Set(try rows("SELECT DISTINCT CAST(thread AS BLOB) FROM messages WHERE unread=1").map { String(decoding: $0, as: UTF8.self) })
    }
    func remove(thread: String) throws {
        try transaction {
            try execute("DELETE FROM messages WHERE thread=?", [.string(thread)])
            try execute("DELETE FROM encrypted_threads WHERE thread=?", [.string(thread)])
        }
        revision &+= 1
    }
    func openNotification(id: String) {
        do { if let item = try record(id: id) { presented = .init(id: item.threadID) } }
        catch { lastError = error.localizedDescription }
    }
    func reloadCalls() throws {
        importedCalls = try rows("SELECT data FROM calls ORDER BY date DESC,id").map { try decoder.decode(CallRecord.self, from: $0) }
    }
    func removeImportedCall(id: String) throws {
        try execute("DELETE FROM calls WHERE id=?", [.string(id)]); try reloadCalls()
    }

    struct Migration: Decodable {
        let format: String
        let version: Int
        let messages: [Message]
        let calls: [Call]
        struct Message: Decodable {
            let id, threadID, title, direction, service, text: String
            let timestamp: Double
            let readOnly: Bool
            let peer, sender, line: String?
            var attachments: [IPhoneCarrierAttachment]? = nil
        }
        struct Call: Decodable {
            let id, direction, service: String
            let timestamp: Double
            let number, line, systemID: String?
            let duration: Double?
            let answered: Bool?
        }
        nonisolated static func read(_ url: URL) throws -> Migration {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let cap = 128 * 1024 * 1024
            guard let data = try file.read(upToCount: cap + 1), data.count <= cap else { throw IPhoneMailboxError.tooLarge }
            let archive = try JSONDecoder().decode(Self.self, from: data)
            guard archive.format == "airsim-iphone-history", archive.version == 1 else { throw IPhoneMailboxError.invalidImport }
            return archive
        }
    }

    func merge(_ archive: Migration) throws -> (Int, Int) {
        func validID(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        func date(_ seconds: Double) throws -> Date {
            guard seconds.isFinite, abs(seconds) < 32_503_680_000 else { throw IPhoneMailboxError.invalidImport }
            return Date(timeIntervalSince1970: seconds)
        }
        var counts = (0, 0)
        var addedParts = 0
        try transaction {
            for entry in archive.messages {
                guard validID(entry.id), !entry.threadID.isEmpty, entry.readOnly,
                      ["outgoing","incoming"].contains(entry.direction) else { throw IPhoneMailboxError.invalidImport }
                let importedParts = entry.attachments ?? []
                guard importedParts.allSatisfy({ $0.data.count <= 32 * 1024 * 1024 }) else { throw IPhoneMailboxError.tooLarge }
                let record = IPhoneCarrierRecord(id: "iphone-import:" + entry.id, lineID: entry.line ?? "", lineLabel: entry.line ?? "",
                    peer: entry.peer ?? entry.sender ?? entry.title, kind: entry.service, body: entry.text, date: try date(entry.timestamp),
                    outgoing: entry.direction == "outgoing", attachments: importedParts, importedThread: entry.threadID, importedTitle: entry.title)
                if try add(record, unread: false) {
                    counts.0 += 1
                    addedParts += importedParts.count
                } else if !importedParts.isEmpty, var previous = try self.record(id: record.id), previous.threadID == record.threadID {
                    // An earlier import may have contained only the text. Enrich that record without duplicating it.
                    for part in importedParts {
                        let exists = try previous.attachments.enumerated().contains { i, old in
                            guard old.name == part.name, old.mimeType == part.mimeType else { return false }
                            return try attachment(id: previous.id, index: i) == part.data
                        }
                        if !exists {
                            try execute("INSERT INTO parts VALUES (?,?,?)", [.string(previous.id), .number(Double(previous.attachments.count)), .blob(part.data)])
                            previous.attachments.append(part)
                            addedParts += 1
                        }
                    }
                    try execute("UPDATE messages SET meta=? WHERE id=?", [.blob(try metadata(previous)), .string(previous.id)])
                }
            }
            for entry in archive.calls {
                guard validID(entry.id), ["outgoing","incoming","unknown"].contains(entry.direction) else { throw IPhoneMailboxError.invalidImport }
                let start = try date(entry.timestamp)
                let duration = entry.duration.flatMap { $0.isFinite && $0 >= 0 && $0 < 31_536_000 ? $0 : nil }
                let record = CallRecord(id: "iphone-import:" + entry.id, index: 0, direction: entry.direction, state: "ended", number: entry.number,
                    startedAt: start, updatedAt: start, endedAt: nil, missed: entry.direction == "incoming" && entry.answered == false,
                    sourceCallID: entry.systemID.flatMap { UUID(uuidString: $0)?.uuidString },
                    importedDetails: .init(service: entry.service, line: entry.line, answered: entry.answered, duration: duration))
                counts.1 += Int(try execute("INSERT INTO calls VALUES (?,?,?) ON CONFLICT(id) DO NOTHING",
                    [.string(record.id), .number(entry.timestamp), .blob(try encoder.encode(record))]))
            }
        }
        try reloadCalls(); revision &+= 1
        lastImportAttachmentCount = addedParts
        return counts
    }
}
