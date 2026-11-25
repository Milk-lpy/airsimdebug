import Combine
import Foundation
import LiveCommunicationKit
import XPC

/// A view of the records iOS lets the default dialer read. Never written to the Agent or local history database.
struct SystemCallEntry: Equatable {
    struct Participant: Equatable {
        let label: String
        let phone: String?
    }

    let id: UUID
    let date: Date
    let direction: String
    let status: String
    let missed: Bool
    let duration: TimeInterval?
    let participants: [Participant]

    var presentationID: String { "iphone-system:" + id.uuidString }
    var number: String? { participants.count == 1 ? participants[0].phone : nil }
    var displayParticipants: String {
        let names = participants.map(\.label).filter { !$0.isEmpty }
        return names.isEmpty ? "未知号码" : names.joined(separator: "、")
    }
    var record: CallRecord {
        CallRecord(id: presentationID, index: 0, direction: direction, state: "ended",
                   number: number, startedAt: date, updatedAt: date, endedAt: nil, missed: missed)
    }

    static func combinedRecords(android: [CallRecord], imported: [CallRecord], system: [SystemCallEntry]) -> [CallRecord] {
        let systemIDs = Set(system.map(\.id))
        let imports = imported.filter { call in
            guard let id = call.sourceCallID.flatMap(UUID.init(uuidString:)) else { return true }
            return !systemIDs.contains(id)
        }
        return android + imports + system.map(\.record)
    }

    static func page(_ entries: [Self], limit: Int) -> (entries: [Self], hasMore: Bool) {
        var unique = [UUID: Self]()
        for entry in entries { unique[entry.id] = entry }
        let sorted = unique.values.sorted {
            $0.date == $1.date ? $0.presentationID < $1.presentationID : $0.date > $1.date
        }
        return (Array(sorted.prefix(limit)), sorted.count > limit)
    }
}

@available(iOS 26.0, *)
private extension SystemCallEntry {
    init(_ call: ConversationHistoryManager.RecentConversation) {
        let direction: String
        switch call.direction {
        case .incoming: direction = "incoming"
        case .outgoing: direction = "outgoing"
        @unknown default: direction = "unknown"
        }
        let status: String
        switch call.status {
        case .missed: status = "未接来电"
        case .answeredElsewhere: status = "已在其他设备接听"
        case .cancelled: status = "已取消"
        case .connected: status = "已接通"
        case .unknown: status = "状态未知"
        @unknown default: status = "状态未知"
        }
        self.init(id: call.id, date: call.date, direction: direction, status: status,
                  missed: call.status == .missed, duration: call.status == .connected ? call.duration : nil,
                  participants: call.handles.map { handle in
                      let number = handle.type == .phoneNumber ? SystemCommunicationURL.dialableNumber(from: handle.value) : nil
                      return Participant(label: handle.displayName.isEmpty ? handle.value : handle.displayName, phone: number)
                  })
    }
}

struct SystemHistoryFailure: Equatable {
    let domain: String
    let code: Int
    let canRetry: Bool?

    init(_ error: Error) {
        let ns = error as NSError
        domain = ns.domain
        code = ns.code
        if #available(iOS 17.0, *), let rich = error as? XPCRichError {
            canRetry = rich.canRetry
        } else if domain == NSCocoaErrorDomain && code == CocoaError.Code.xpcConnectionInterrupted.rawValue {
            canRetry = true
        } else {
            // An NSError that carries only the XPC domain and code has lost the retry flag.
            canRetry = nil
        }
    }

    var isXPC: Bool {
        domain == "XPC.XPCRichError" || (domain == NSCocoaErrorDomain && (
            code == CocoaError.Code.xpcConnectionInterrupted.rawValue || code == CocoaError.Code.xpcConnectionInvalid.rawValue))
    }

    var diagnostic: String {
        var fields = ["ConversationHistoryManager.recentConversations", "\(domain) (\(code))"]
        if let canRetry { fields.append("canRetry=\(canRetry)") }
        return fields.joined(separator: " · ")
    }
}

enum SystemHistoryReadState: Equatable {
    case idle, unsupported, loading, ready
    case failed(SystemHistoryFailure)

    func canConfirmEmpty(hasOlder: Bool) -> Bool {
        !hasOlder && (self == .ready || self == .unsupported)
    }
}

@MainActor
final class SystemCallHistory: ObservableObject {
    @Published private(set) var entries: [String: SystemCallEntry] = [:]
    @Published private(set) var hasOlder = false
    @Published private(set) var state: SystemHistoryReadState = .idle

    private let pageSize = 60
    private var limit = 60
    private var observation: Any?
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard #available(iOS 26.0, *) else { state = .unsupported; return }
        if observation != nil {
            if case .failed = state { refresh() }
            return
        }
        observation = NotificationCenter.default.addObserver(
            of: ConversationHistoryManager.self, for: .conversationHistoryDidUpdateMessage
        ) { [weak self] _ in
            await self?.refresh(incremental: true)
        }
        refresh()
    }

    func stop() {
        if #available(iOS 26.0, *), let token = observation as? NotificationCenter.ObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
        observation = nil
        refreshTask?.cancel()
        refreshTask = nil
        state = .idle
        entries = [:]
        hasOlder = false
        limit = pageSize
    }

    func loadOlder() {
        guard hasOlder, state != .loading else { return }
        limit += pageSize
        refresh()
    }

    func refresh(incremental: Bool = false) {
        guard #available(iOS 26.0, *), observation != nil else { return }
        refreshTask?.cancel()
        state = .loading
        let count = limit
        let boundary = incremental && hasOlder ? entries.values.map(\.date).min() : nil
        refreshTask = Task {
            var didRetry = false
            while !Task.isCancelled {
                do {
                    let page = try await Self.fetchPage(count: count, boundary: boundary)
                    try Task.checkCancellation()
                    let updated = Dictionary(uniqueKeysWithValues: page.entries.map { ($0.presentationID, $0) })
                    if updated != entries { entries = updated }
                    hasOlder = page.hasMore
                    state = .ready
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    // Access may have been revoked. Only Android and imported records may remain visible.
                    entries = [:]
                    hasOlder = false
                    let failure = SystemHistoryFailure(error)
                    if !didRetry && failure.canRetry == true {
                        didRetry = true
                        do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
                    } else {
                        state = .failed(failure)
                        return
                    }
                }
            }
        }
    }

    @available(iOS 26.0, *)
    private static func fetchPage(count: Int, boundary: Date?) async throws -> (entries: [SystemCallEntry], hasMore: Bool) {
        let manager = ConversationHistoryManager.sharedInstance
        if let boundary {
            let recent = #Predicate<ConversationHistoryManager.RecentConversation> { $0.date >= boundary }
            let changed = try await manager.recentConversations(matching: recent)
            try Task.checkCancellation()
            let partial = SystemCallEntry.page(changed.map(SystemCallEntry.init), limit: count)
            if partial.entries.count >= count { return (partial.entries, true) }
        }
        let all = #Predicate<ConversationHistoryManager.RecentConversation> { _ in true }
        let snapshot = try await manager.recentConversations(matching: all)
        return SystemCallEntry.page(snapshot.map(SystemCallEntry.init), limit: count)
    }
}
