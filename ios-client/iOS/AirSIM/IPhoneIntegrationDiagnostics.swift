import SwiftUI
import LiveCommunicationKit
import TelephonyMessagingKit

/// This report contains counts and capability flags. No call handles, messages or SIM identifiers are exported.
struct IPhoneIntegrationDiagnosticsButton: View {
    var history: SystemCallHistory? = nil
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Label("iPhone 通信自检", systemImage: "stethoscope") }
            .sheet(isPresented: $showing) { IPhoneIntegrationDiagnostics(history: history) }
    }
}

private struct IPhoneIntegrationDiagnostics: View {
    let history: SystemCallHistory?
    @Environment(\.dismiss) private var dismiss
    @State private var signed: [(String, String)] = []
    @State private var runtime: [(String, String)] = []
    @State private var request = 0
    @State private var loading = true
    @State private var copied = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "AirSIM \(info?["CFBundleShortVersionString"] as? String ?? "—") (\(info?["CFBundleVersion"] as? String ?? "—")) · iOS \(UIDevice.current.systemVersion)"
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(version).font(.subheadline)
                    if loading { ProgressView("正在读取本机状态") }
                    ForEach(runtime, id: \.0) { row in LabeledContent(row.0) { Text(row.1).multilineTextAlignment(.trailing) } }
                } header: { Text("系统接口") } footer: {
                    Text("通话线路和短信线路分别由 iOS 返回。通话历史限当前系统授权范围；以前的短信可从「短信 → 导入 iPhone 历史记录」迁移。")
                }
                if !signed.isEmpty {
                    Section {
                        ForEach(signed, id: \.0) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.0)
                                Text(row.1).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    } header: { Text("本机安装包") } footer: {
                        Text("描述文件列出可申请的权限，主 App 签名记录实际声明。iOS 独立决定当前默认角色和可访问的数据。")
                    }
                }
                Section {
                    Button("重新检查") { copied = false; request += 1 }.disabled(loading)
                    Button(copied ? "已复制" : "复制自检结果") {
                        let rows = runtime + signed
                        UIPasteboard.general.string = ([version] + rows.map { "\($0.0)　\($0.1)" }).joined(separator: "\n")
                        copied = true
                    }.disabled(runtime.isEmpty && signed.isEmpty)
                }
            }
            .navigationTitle("iPhone 通信自检").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: request) { await check(useSnapshot: request == 0) }
        }
    }

    @MainActor private func check(useSnapshot: Bool) async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        let summary = await Task.detached(priority: .userInitiated) {
            IPhoneSigningDiagnostics.rows(bundle: .main)
        }.value
        guard !Task.isCancelled else { return }
        signed = summary

        guard #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone else {
            runtime = [("运营商接口", "需要运行 iOS 26 或更高版本的 iPhone")]
            return
        }
        let session = TelephonyMessagingSession.shared
        let configured = session.isConfiguredForCarrierMessaging
        let inventory = IPhoneCellularDialer.lineInventory
        var rows: [(String, String)] = [
            ("通话线路", inventory.summary),
            ("默认拨号线路", DialLinePreference.storedSummary(in: inventory)),
            ("运营商消息角色", configured ? "iOS 已确认" : "iOS 未确认（false）")
        ]
        if configured {
            do {
                let services = try session.cellularServices
                rows.append(("短信线路", "iOS 返回 \(services.count) 条"))
            } catch {
                let failure = error as NSError
                rows.append(("短信线路", "\(failure.domain) (\(failure.code))"))
            }
        } else { rows.append(("短信线路", "尚无已确认的运营商消息角色")) }
        runtime = rows + [("通话历史", "查询中")]
        if useSnapshot, let history {
            switch history.state {
            case .failed(let error): rows.append(("最近一次通话历史查询", error.diagnostic)); runtime = rows; return
            case .ready: rows.append(("当前已加载的通话记录", "\(history.entries.count) 条")); runtime = rows; return
            default: break
            }
        }
        do {
            let all = #Predicate<ConversationHistoryManager.RecentConversation> { _ in true }
            let recent = try await ConversationHistoryManager.sharedInstance.recentConversations(matching: all)
            rows.append(("通话历史", "iOS 返回 \(recent.count) 条"))
        } catch {
            rows.append(("通话历史", SystemHistoryFailure(error).diagnostic))
        }
        guard !Task.isCancelled else { return }
        runtime = rows
    }
}
