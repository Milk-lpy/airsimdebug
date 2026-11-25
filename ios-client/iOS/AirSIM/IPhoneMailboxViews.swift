import SwiftUI
import UniformTypeIdentifiers

private struct CarrierFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct IPhoneArchivedThreads: View {
    let threads: [IPhoneCarrierRecord]
    let unread: Set<String>
    @ObservedObject private var mailbox = IPhoneMailbox.shared
    @State private var deleting: IPhoneCarrierRecord?
    var body: some View {
        Section("已保存的 iPhone 消息") {
            ForEach(threads) { thread in
                Button { mailbox.presented = .init(id: thread.threadID) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(thread.title).font(.headline).foregroundStyle(.primary)
                            Text(thread.body.isEmpty ? "附件" : thread.body).foregroundStyle(.secondary).lineLimit(1)
                            Text([thread.kind, thread.lineLabel, thread.importedThread == nil ? nil : "导入记录"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if unread.contains(thread.threadID) { Image(systemName: "circle.fill").font(.caption2).accessibilityLabel("未读") }
                        Text(thread.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions { Button("删除", role: .destructive) { deleting = thread } }
            }
        }
        .confirmationDialog("删除该会话在 AirSIM 中的本机记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let deleting else { return }
                do { try mailbox.remove(thread: deleting.threadID) } catch { mailbox.lastError = error.localizedDescription }
                self.deleting = nil
            }
        }
    }
}

struct IPhoneCarrierPresentation: ViewModifier {
    @ObservedObject private var mailbox = IPhoneMailbox.shared
    func body(content: Content) -> some View {
        content.sheet(item: $mailbox.presented) { route in
            IPhoneCarrierThread(threadID: route.id).id(route.id)
        }
        .alert("iPhone 本机记录", isPresented: Binding(get: { mailbox.lastError != nil }, set: { if !$0 { mailbox.lastError = nil } })) {
            Button("好") { mailbox.lastError = nil }
        } message: { Text(mailbox.lastError ?? "") }
    }
}

private struct IPhoneCarrierThread: View {
    let threadID: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var box = IPhoneMailbox.shared
    @State private var messages: [IPhoneCarrierRecord] = []
    @State private var limit = 100
    @State private var error: String?
    @State private var exported: CarrierFileDocument?
    @State private var filename = ""
    @State private var exporting = false
    private func load() {
        do { messages = try box.messages(thread: threadID, limit: limit); try box.markRead(thread: threadID) }
        catch { self.error = error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            List {
                if messages.count == limit { Button("显示更早的消息") { limit += 100; load() } }
                ForEach(messages) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.outgoing ? "我" : item.peer).font(.caption).foregroundStyle(.secondary)
                        if !item.body.isEmpty { Text(item.body).textSelection(.enabled) }
                        ForEach(item.attachments.indices, id: \.self) { index in
                            let file = item.attachments[index]
                            if file.mimeType == "application/vnd.airsim.rcs-transfer+json" {
                                Label("附件未保存在本机", systemImage: "doc")
                            } else {
                                Button {
                                    do {
                                        exported = CarrierFileDocument(data: try box.attachment(id: item.id, index: index))
                                        filename = (file.name as NSString).lastPathComponent; exporting = true
                                    } catch { self.error = error.localizedDescription }
                                } label: { Label(file.name, systemImage: "square.and.arrow.up") }
                            }
                        }
                        HStack { Text(item.date, style: .date); Text(item.date, style: .time); Text(item.status) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let last = messages.last {
                    Text([last.lineLabel, last.kind].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle(messages.last?.title ?? "iPhone 短信").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { load() }
            .onChange(of: box.revision) { _ in load() }
            .fileExporter(isPresented: $exporting, document: exported, contentType: .data, defaultFilename: filename) {
                if case .failure(let e) = $0 { error = e.localizedDescription }
                exported = nil
            }
            .alert("iPhone 消息", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
