import SwiftUI
import UniformTypeIdentifiers

private struct CarrierFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct IPhoneHistoryImportButton: View {
    @State private var choosing = false
    @State private var migration: IPhoneMailbox.Migration?
    @State private var message: String?
    @State private var confirming = false
    @State private var busy = false
    var body: some View {
        Button { choosing = true } label: { Label("导入 iPhone 历史记录", systemImage: "square.and.arrow.down") }
            .disabled(busy)
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            migration = try await Task.detached(priority: .userInitiated) { try IPhoneMailbox.Migration.read(url) }.value
                            confirming = true
                        } catch { message = error.localizedDescription }
                    }
                } catch { message = error.localizedDescription }
            }
            .confirmationDialog("导入到这台 iPhone？", isPresented: $confirming, titleVisibility: .visible) {
                Button("导入") {
                    guard let archive = migration else { return }
                    migration = nil
                    do {
                        let (messages, calls) = try IPhoneMailbox.shared.merge(archive)
                        message = "已新增 \(messages) 条消息、\(calls) 条通话，已导入 \(IPhoneMailbox.shared.lastImportAttachmentCount) 个附件。重复记录已跳过。"
                    } catch { message = error.localizedDescription }
                }
                Button("取消", role: .cancel) { migration = nil }
            } message: {
                Text("文件包含 \(migration?.messages.count ?? 0) 条消息、\(migration?.calls.count ?? 0) 条通话。历史消息将作为只读记录保存。")
            }
            .alert("历史记录", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
    }
}

struct IPhoneCarrierThreads: View {
    let query: String
    @ObservedObject private var mailbox = IPhoneMailbox.shared
    @ObservedObject private var carrier = IPhoneCarrierMessaging.shared
    @State private var threads: [IPhoneCarrierRecord] = []
    @State private var unread: Set<String> = []
    @State private var deleting: IPhoneCarrierRecord?
    private func reload() {
        do {
            threads = try mailbox.latestThreads(matching: query)
            unread = try mailbox.unreadThreads()
        } catch { mailbox.lastError = error.localizedDescription }
    }
    var body: some View {
        Section("iPhone 本机") {
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
            if query.isEmpty {
                if UIDevice.current.userInterfaceIdiom == .phone {
                    IPhoneCarrierStatus()
                }
                Text("以前保存在「信息」中的短信可从本机备份导入。")
                    .font(.footnote).foregroundStyle(.secondary)
                IPhoneHistoryImportButton()
            }
        }
        .onAppear { carrier.refresh(); reload() }
        .onChange(of: mailbox.revision) { _ in reload() }
        .onChange(of: query) { _ in reload() }
        .confirmationDialog("删除该会话在 AirSIM 中的本机记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let deleting else { return }
                do { try mailbox.remove(thread: deleting.threadID) } catch { mailbox.lastError = error.localizedDescription }
                self.deleting = nil
            }
        }
    }
}

private struct IPhoneCarrierStatus: View {
    @ObservedObject private var carrier = IPhoneCarrierMessaging.shared

    private var summary: String {
        switch carrier.role {
        case .checking: return "正在检查本机运营商消息"
        case .unsupported: return "本机运营商消息需要 iOS 26 或更高版本"
        case .inactive: return "iOS 尚未启用 AirSIM 的运营商消息服务"
        case .configured:
            if carrier.lineReadError != nil { return "运营商消息已启用 · 线路读取异常" }
            return "运营商消息已启用 · iOS 返回 " + String(carrier.lines.count) + " 条线路"
        }
    }

    var body: some View {
        DisclosureGroup(summary) {
            if carrier.isConfigured {
                ForEach(carrier.lines) { line in
                    Text(line.label + " · " + (line.protocols.isEmpty ? "暂不可发送" : line.protocols.joined(separator: " / ")))
                }
                if let issue = carrier.lineReadError {
                    Text("已识别 " + String(carrier.lines.count) + " 条线路，读取诊断 " + issue)
                } else if carrier.lines.isEmpty {
                    Text("iOS 尚未返回可列出的蜂窝线路。")
                }
                ForEach(["SMS", "MMS", "RCS"], id: \.self) { kind in
                    Text(kind + " 收件 · " + (carrier.receiverStates[kind]?.description ?? "等候本机收件箱就绪"))
                }
                Text("iOS 会将新收到的运营商消息交给 AirSIM。")
                if carrier.notificationsEnabled == false {
                    Button("启用本机消息通知") { Task { await carrier.requestNotifications() } }
                }
            } else if carrier.role == .inactive {
                Text("请在系统默认 App 设置中确认 AirSIM 已获准处理运营商消息，并检查本机的地区与系统版本是否支持。")
            }
            if let error = carrier.lastError { Text("最近操作错误 · " + error) }
            if carrier.role != .unsupported {
                Button("重新检查线路和收件") { carrier.refresh(retryNow: true) }
            }
        }.font(.footnote)
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

struct IPhoneMessageAttachmentPicker: View {
    @Binding var attachment: IPhoneCarrierAttachment?
    @Binding var error: String?
    @State private var choosing = false
    var body: some View {
        if let attachment {
            Button { self.attachment = nil } label: { Label(attachment.name, systemImage: "xmark.circle") }
                .lineLimit(1).accessibilityLabel("移除附件 " + attachment.name)
        } else {
            Button { choosing = true } label: { Label("添加附件", systemImage: "paperclip") }
                .fileImporter(isPresented: $choosing, allowedContentTypes: [.data]) { result in
                    do {
                        let url = try result.get()
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let cap = 32 * 1024 * 1024
                        guard let data = try handle.read(upToCount: cap + 1), data.count <= cap else {
                            error = "请选择 32 MB 以内的附件。"; return
                        }
                        attachment = .init(name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data)
                    } catch { self.error = error.localizedDescription }
                }
        }
    }
}

private struct IPhoneCarrierThread: View {
    let threadID: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var box = IPhoneMailbox.shared
    @ObservedObject private var carrier = IPhoneCarrierMessaging.shared
    @State private var messages: [IPhoneCarrierRecord] = []
    @State private var limit = 100
    @State private var draft = ""
    @State private var sending = false
    @State private var confirmingGroup = false
    @State private var error: String?
    @State private var attachment: IPhoneCarrierAttachment?
    @State private var exported: CarrierFileDocument?
    @State private var filename = ""
    @State private var exporting = false
    private func load() {
        do { messages = try box.messages(thread: threadID, limit: limit); try box.markRead(thread: threadID) }
        catch { self.error = error.localizedDescription }
    }
    private func send(_ record: IPhoneCarrierRecord) {
        guard !sending, record.importedThread == nil else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                let encrypted = try box.requiresEncryptedReplies(thread: record.threadID)
                try await carrier.send(draft, to: record.peer, lineID: record.lineID, kind: record.kind,
                    groupID: record.groupID, attachments: attachment.map { [$0] } ?? [], encrypted: encrypted)
                draft = ""; attachment = nil
            } catch { self.error = error.localizedDescription }
        }
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
                                Label("附件等待下载", systemImage: "arrow.down.circle")
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text([last.importedThread == nil ? "iPhone" : "导入历史 · 只读", last.lineLabel, last.kind].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if last.importedThread == nil {
                            let canReply = carrier.isConfigured && carrier.lines.contains { $0.id == last.lineID && $0.protocols.contains(last.kind) }
                            if !canReply {
                                Text("此会话原来的 iPhone 线路暂时无法发送 " + last.kind + "。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                TextField("回复", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                                Button("发送") {
                                    if last.kind == "MMS" && last.groupID != nil { confirmingGroup = true } else { send(last) }
                                }.disabled(sending || !canReply || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil))
                            }
                            if last.kind != "SMS" { IPhoneMessageAttachmentPicker(attachment: $attachment, error: $error).disabled(sending) }
                        }
                    }.padding().background(.bar)
                }
            }
            .navigationTitle(messages.last?.title ?? "iPhone 短信").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { carrier.refresh(); load() }
            .onChange(of: box.revision) { _ in load() }
            .fileExporter(isPresented: $exporting, document: exported, contentType: .data, defaultFilename: filename) {
                if case .failure(let e) = $0 { error = e.localizedDescription }
                exported = nil
            }
            .confirmationDialog("发送给彩信群组？", isPresented: $confirmingGroup, titleVisibility: .visible) {
                Button("发送") { if let last = messages.last { send(last) } }
            } message: {
                Text(messages.last?.groupID.map { IPhoneCarrierMessaging.mmsGroupRecipients($0).joined(separator: "、") } ?? "")
            }
            .alert("iPhone 消息", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
