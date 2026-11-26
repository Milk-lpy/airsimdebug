import Foundation
import LiveCommunicationKit
import UIKit

struct IPhoneCellularLine: Identifiable, Hashable {
    let id: UUID
    let label: String
}

enum IPhoneCellularLineInventory: Equatable {
    case notQueried, unsupportedDevice, unsupportedVersion
    case reported([IPhoneCellularLine])

    var lines: [IPhoneCellularLine] {
        if case .reported(let lines) = self { return lines }
        return []
    }

    var summary: String {
        switch self {
        case .notQueried: return "尚未查询 iPhone 蜂窝线路"
        case .unsupportedDevice: return "此设备不支持 iPhone 蜂窝线路"
        case .unsupportedVersion: return "选择具体 iPhone SIM 需要 iOS 26 或更高版本"
        case .reported(let lines): return "iOS 蜂窝通话接口返回 \(lines.count) 条本机线路"
        }
    }
}

@MainActor
enum IPhoneCellularDialer {
    static var supportsSystemFallback: Bool {
        if #available(iOS 18.2, *) {
            return UIDevice.current.userInterfaceIdiom == .phone
        }
        return false
    }

    static var lineInventory: IPhoneCellularLineInventory {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .unsupportedDevice }
        guard #available(iOS 26, *) else { return .unsupportedVersion }
        let services = TelephonyConversationManager.sharedInstance.cellularServices
        return .reported(services.enumerated().map { index, service in
            let label = service.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return IPhoneCellularLine(id: service.id, label: label.isEmpty ? "线路 \(index + 1)" : label)
        })
    }

    static func dial(_ number: String, using lineID: UUID) async throws {
        guard #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone else {
            throw DialError.unavailableLine
        }
        guard let normalized = SystemCommunicationURL.dialableNumber(from: number) else {
            throw DialError.invalidNumber
        }
        let manager = TelephonyConversationManager.sharedInstance
        // The user can remove, disable or switch a SIM while the selector is open.
        guard let service = manager.cellularServices.first(where: { $0.id == lineID }) else {
            throw DialError.unavailableLine
        }
        let handle = LiveCommunicationKit.Handle(type: .phoneNumber, value: normalized)
        try await manager.startCellularConversation(StartCellularConversationAction(handle, cellularService: service))
    }

    /// Only call this after the person explicitly requests a system cellular call.
    static func dialWithSystem(_ number: String) async throws {
        guard supportsSystemFallback else { throw DialError.systemUnavailable }
        guard let normalized = SystemCommunicationURL.dialableNumber(from: number) else {
            throw DialError.invalidNumber
        }
        if #available(iOS 26, *) {
            let handle = LiveCommunicationKit.Handle(type: .phoneNumber, value: normalized)
            try await TelephonyConversationManager.sharedInstance.startCellularConversation(
                StartCellularConversationAction(handle, cellularService: nil)
            )
            return
        }
        var components = URLComponents()
        components.scheme = "telephony"
        components.path = normalized
        guard let url = components.url, await UIApplication.shared.open(url) else {
            throw DialError.systemUnavailable
        }
    }

    private enum DialError: LocalizedError {
        case invalidNumber, unavailableLine, systemUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidNumber: return "请输入有效的电话号码。"
            case .unavailableLine: return "所选 iPhone 线路已不可用，请重新选择拨号线路。"
            case .systemUnavailable: return "无法打开 iPhone 蜂窝拨号。"
            }
        }
    }
}
