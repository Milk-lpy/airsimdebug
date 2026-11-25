import Combine
import Foundation
import LiveCommunicationKit

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

@MainActor
final class SystemCallHistory: ObservableObject {
    @Published private(set) var entries: [String: SystemCallEntry] = [:]
    @Published private(set) var hasOlder = false
    @Published private(set) var problem: String?
    @Published private(set) var loading = false

    private let pageSize = 60
    private var limit = 60
    private var observation: Any?
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard #available(iOS 26.0, *), observation == nil else { return }
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
        loading = false
        entries = [:]
        hasOlder = false
        problem = nil
        limit = pageSize
    }

    func loadOlder() {
        guard hasOlder, !loading else { return }
        limit += pageSize
        refresh()
    }

    func refresh(incremental: Bool = false) {
        guard #available(iOS 26.0, *), observation != nil else { return }
        refreshTask?.cancel()
        loading = true
        let count = limit
        let boundary = incremental && hasOlder ? entries.values.map(\.date).min() : nil
        refreshTask = Task {
            do {
                let manager = ConversationHistoryManager.sharedInstance
                let all = #Predicate<ConversationHistoryManager.RecentConversation> { _ in true }
                let page: (entries: [SystemCallEntry], hasMore: Bool)
                if let boundary {
                    let recent = #Predicate<ConversationHistoryManager.RecentConversation> { $0.date >= boundary }
                    let changed = try await manager.recentConversations(matching: recent)
                    try Task.checkCancellation()
                    let partial = SystemCallEntry.page(changed.map(SystemCallEntry.init), limit: count)
                    if partial.entries.count >= count {
                        // This query excluded the older pages that the previous snapshot reported.
                        page = (partial.entries, true)
                    } else {
                        let snapshot = try await manager.recentConversations(matching: all)
                        page = SystemCallEntry.page(snapshot.map(SystemCallEntry.init), limit: count)
                    }
                } else {
                    let snapshot = try await manager.recentConversations(matching: all)
                    page = SystemCallEntry.page(snapshot.map(SystemCallEntry.init), limit: count)
                }
                try Task.checkCancellation()
                let updated = Dictionary(uniqueKeysWithValues: page.entries.map { ($0.presentationID, $0) })
                if updated != entries { entries = updated }
                hasOlder = page.hasMore
                problem = nil
            } catch {
                guard !Task.isCancelled else { return }
                // A failed access check must also remove previously readable carrier records.
                entries = [:]
                hasOlder = false
                problem = "无法读取 iPhone 通话记录。请确认 AirSIM 已设为默认拨号 App。\n" + error.localizedDescription
            }
            loading = false
        }
    }
}
