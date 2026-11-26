import SwiftUI

struct IPhoneIntegrationDiagnosticsButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Label("iPhone 通信自检", systemImage: "stethoscope") }
            .sheet(isPresented: $showing) { IPhoneIntegrationDiagnostics() }
    }
}

private struct IPhoneIntegrationDiagnostics: View {
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
                } header: { Text("系统接口") }
                if !signed.isEmpty {
                    Section {
                        ForEach(signed, id: \.0) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.0)
                                Text(row.1).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    } header: { Text("本机安装包") }
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
            .task(id: request) { await check() }
        }
    }

    @MainActor private func check() async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        let summary = await Task.detached(priority: .userInitiated) {
            IPhoneSigningDiagnostics.rows(bundle: .main)
        }.value
        guard !Task.isCancelled else { return }
        signed = summary

        let inventory = IPhoneCellularDialer.lineInventory
        runtime = [
            ("通话线路", inventory.summary),
            ("默认拨号线路", DialLinePreference.storedSummary(in: inventory))
        ]
    }
}
