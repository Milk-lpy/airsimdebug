import SwiftUI
import UIKit
import Intents

enum SystemCommunicationDestination: Equatable {
    case call(String)
    case liveActivity(AirSIMLiveActivityAction, callID: String)
}

enum SystemCommunicationURL {
    static func destination(for url: URL) -> SystemCommunicationDestination? {
        if let action = AirSIMLiveActivityActionURL.parse(url) {
            return .liveActivity(action.action, callID: action.callID)
        }
        guard url.scheme?.lowercased() == "tel" else { return nil }
        let prefixLength = "tel:".count
        guard url.absoluteString.count > prefixLength else { return nil }
        var target = String(url.absoluteString.dropFirst(prefixLength))
        while target.hasPrefix("//") { target.removeFirst(2) }
        target = String(target.prefix(while: { $0 != "?" }))
        guard let decoded = target.removingPercentEncoding else { return nil }
        target = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return dialableNumber(from: target).map(SystemCommunicationDestination.call)
    }

    static func callNumber(for activity: NSUserActivity) -> String? {
        let people: [INPerson]
        switch activity.interaction?.intent {
        case let intent as INStartCallIntent:
            let contacts = intent.contacts ?? []
            let callbackPerson = intent.callRecordToCallBack?.caller
            people = contacts.isEmpty ? (callbackPerson.map { [$0] } ?? []) : contacts
        case let intent as INStartAudioCallIntent:
            people = intent.contacts ?? []
        default:
            return nil
        }
        guard people.count == 1, let handle = people.first?.personHandle,
              handle.type == .phoneNumber || handle.type == .unknown,
              let value = handle.value else { return nil }
        return dialableNumber(from: value)
    }

    static func dialableNumber(from value: String) -> String? {
        let numberCharacters = CharacterSet(charactersIn: "0123456789+*#")
        let formatting = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-()."))
        guard value.unicodeScalars.allSatisfy({ numberCharacters.contains($0) || formatting.contains($0) })
        else { return nil }
        let number = String(value.unicodeScalars.filter { numberCharacters.contains($0) })
        let digits = CharacterSet(charactersIn: "0123456789")
        guard number.count <= 64, !number.dropFirst().contains("+"),
              number.unicodeScalars.contains(where: { digits.contains($0) }) else { return nil }
        return number
    }
}

enum PhoneTab: String, CaseIterable, Identifiable {
    case dial = "拨号"
    case recents = "最近通话"
    case messages = "短信"
    case contacts = "通讯录"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dial: return "circle.grid.3x3.fill"
        case .recents: return "clock.fill"
        case .messages: return "bubble.left.fill"
        case .contacts: return "person.crop.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }

    // Reuse immutable symbol images when connection updates invalidate RootView.
    // Keep titles and native hit targets independent of artwork size.
    private static let tabImages: [PhoneTab: UIImage] = Dictionary(uniqueKeysWithValues:
        allCases.map { tab in
            (tab, UIImage(systemName: tab.icon, withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 23, weight: .regular, scale: .medium)) ?? UIImage())
        })

    var tabImage: UIImage { Self.tabImages[self] ?? UIImage() }

    var tabTitle: String {
        switch self {
        case .recents: return "最近"
        case .contacts: return "联系人"
        default: return rawValue
        }
    }
}


/// 五个主要目的地使用系统 TabView；iOS 26 原生标签栏负责 Liquid Glass、
/// 长按放大与选中态交互，避免分页手势和自绘按钮争抢横向滑动。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appUpdates: AppUpdateController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appUpdatePresentation: AppUpdatePresentation?
    @AppStorage("airsim.selected-tab") private var selectedTabRawValue = PhoneTab.dial.rawValue
    @State private var collapsedCallID: String?
    @State private var dialLineRequest: DialLineRequest?
    @AppStorage(DialLinePreference.storageKey) private var defaultDialLineData = Data()
    @State private var iPhoneInventory: IPhoneCellularLineInventory = .notQueried
    @State private var submittingDial = false
    @State private var pendingSMSRecipient: String?
    @State private var messageListState = SMSConversationListState()
    @State private var conversationSender: String?
    @State private var showingConversation = false
    @AppStorage("airsim.first-connection-complete") private var firstConnectionComplete = false

    private var presentedCall: CallRecord? {
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["AIRSIM_UI_FIXTURE"] == "sms-navigation",
           let preview = SMSNavigationFixture.previewCall { return preview }
#endif
        return model.inAppPresentedCall
    }

    private var callSurfaceVisible: Bool {
        guard let call = presentedCall else { return false }
        // A new incoming state must never remain hidden by an earlier collapse.
        return CallSurfaceContent(state: call.state).phase == .incoming || collapsedCallID != call.id
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
                TabView(selection: selectedTabBinding) {
                    dialPad
                        .tag(PhoneTab.dial)
                        .tabItem { Label { Text(L10n.t(PhoneTab.dial.tabTitle)) } icon: {
                            Image(uiImage: PhoneTab.dial.tabImage)
                        }.environment(\.symbolVariants, .none) }


                    RecentsView(onCall: prefillDialPad, onMessage: composeMessage)
                        .tag(PhoneTab.recents)
                        .tabItem { Label { Text(L10n.t(PhoneTab.recents.tabTitle)) } icon: {
                            Image(uiImage: PhoneTab.recents.tabImage)
                        }.environment(\.symbolVariants, .none) }

                        .badge(AirSIMWidgetSnapshot.badgeText(model.unseenMissedCallIDs.count))

                    Group {
                        if #available(iOS 17.0, *) {
                            AdaptiveMessagesView(pendingRecipient: $pendingSMSRecipient,
                                state: $messageListState, sender: $conversationSender,
                                showingConversation: $showingConversation,
                                openConversation: showSMSConversation)
                        } else {
                            NavigationStack {
                                MessagesView(
                                    pendingRecipient: $pendingSMSRecipient,
                                    state: $messageListState,
                                    openConversation: showSMSConversation
                                )
                                .navigationTitle(L10n.t("短信"))
                                .navigationBarTitleDisplayMode(.large)
                                .toolbar { SMSConversationListToolbar(state: $messageListState) }
                                .navigationDestination(isPresented: $showingConversation) {
                                    if let sender = conversationSender {
                                        MessageThreadView(sender: sender)
                                            .id(sender)
                                            .toolbar(.hidden, for: .tabBar)
                                    }
                                }
                            }
                        }
                    }
                        .tag(PhoneTab.messages)
                        .tabItem { Label { Text(L10n.t(PhoneTab.messages.tabTitle)) } icon: {
                            Image(uiImage: PhoneTab.messages.tabImage)
                        }.environment(\.symbolVariants, .none) }

                        .badge(AirSIMWidgetSnapshot.badgeText(model.unreadMessageIDs.count))

                    ContactsView(onCall: prefillDialPad, onMessage: composeMessage)
                        .tag(PhoneTab.contacts)
                        .tabItem { Label { Text(L10n.t(PhoneTab.contacts.tabTitle)) } icon: {
                            Image(uiImage: PhoneTab.contacts.tabImage)
                        }.environment(\.symbolVariants, .none) }


                    AirSIMSettingsView()
                        .tag(PhoneTab.settings)
                        .tabItem { Label { Text(L10n.t(PhoneTab.settings.tabTitle)) } icon: {
                            Image(uiImage: PhoneTab.settings.tabImage)
                        }.environment(\.symbolVariants, .none) }

                }
                // Keep navigation state, but remove the underlying native tab
                // chrome from rendering, hit testing and VoiceOver during calls.
                // Duo promotes that chrome outside the SwiftUI content stack.
                .opacity(callSurfaceVisible ? 0 : 1)
                .allowsHitTesting(!callSurfaceVisible)
                .accessibilityHidden(callSurfaceVisible)
                .phoneTabBarAlwaysExpanded()
                .phoneTabSelectionFeedback(selectedTabRawValue)
                .tint(settings.theme.accent)

            if let call = presentedCall {
                ActiveCallView(call: call, isPresented: callSurfaceVisible,
                               onMinimize: { collapsedCallID = call.id })
                    // Keep the same call view mounted; collapse changes presentation only.
                    .opacity(callSurfaceVisible ? 1 : 0)
                    .allowsHitTesting(callSurfaceVisible)
                    .accessibilityHidden(!callSurfaceVisible)
                    .zIndex(1)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .background(PhoneBackdrop())
        .modifier(IPhoneCarrierPresentation())
        .modifier(DialLinePicker(request: $dialLineRequest, inventory: $iPhoneInventory,
            preference: defaultDialPreference,
            choose: selectDialLine))
        .onChange(of: model.callLifecycleSnapshot.state.representsCall) { inCall in
            if inCall { dialLineRequest = nil }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.inAppPresentedCall?.id)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onChange(of: presentedCall?.id) { _ in collapsedCallID = nil }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let call = presentedCall, !callSurfaceVisible {
                Button { collapsedCallID = nil } label: {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text("返回通话")
                        Text(model.contacts.displayName(for: call.number)).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(12).foregroundStyle(.white)
                    .background(Color.green.gradient, in: Capsule())
                }
                .buttonStyle(.plain).padding(.horizontal)
                .accessibilityIdentifier("call.restore")
            }
            if let reminder = model.otherDeviceCallReminders.first {
                Button {
                    _ = model.openOtherDeviceCallNotification(reminder.userInfo)
                } label: {
                    Label("\(reminder.deviceName) 来电 · 其他设备 \(model.otherDeviceCallReminders.count)", systemImage: "phone.badge.waveform")
                        .font(.subheadline.weight(.semibold)).padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain).padding(.horizontal)
            }
        }
        .sheet(item: $model.focusedOtherDeviceCall, onDismiss: presentAppUpdateIfIdle) { reminder in
            OtherDeviceCallSheet(reminder: reminder).environmentObject(model)
        }
        .fullScreenCover(isPresented: Binding(
            get: { !firstConnectionComplete && !appUpdates.needsNotes && appUpdatePresentation == nil && appUpdateCallIdle },
            // Completion is written only by explicit actions in the onboarding view.
            // A call can temporarily dismiss this cover without completing pairing.
            set: { _ in }
        )) {
            AirSIMFirstConnectionView()
                .environmentObject(model)
        }
        .onOpenURL(perform: handleSystemCommunicationURL)
        .onContinueUserActivity("INStartCallIntent", perform: handleSystemCallActivity)
        .onContinueUserActivity("INStartAudioCallIntent", perform: handleSystemCallActivity)
        .fullScreenCover(item: $appUpdatePresentation, onDismiss: presentAppUpdateIfIdle) { presentation in
            AppUpdateSheet(presentation: presentation, updates: appUpdates)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            presentAppUpdateIfIdle()
            if firstConnectionComplete && appUpdateCallIdle {
                _ = await appUpdates.check(manual: false)
                presentAppUpdateIfIdle()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            iPhoneInventory = IPhoneCellularDialer.lineInventory
            // Recheck after foreground activation if the first native query came back empty.
            if case .reported(let lines) = iPhoneInventory, lines.isEmpty {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                iPhoneInventory = IPhoneCellularDialer.lineInventory
            }
        }
        .onChange(of: appUpdates.needsNotes) { _ in presentAppUpdateIfIdle() }
        .onChange(of: appUpdates.pendingUpdate) { _ in presentAppUpdateIfIdle() }
        .onChange(of: selectedTabRawValue) { _ in presentAppUpdateIfIdle() }
        .onChange(of: firstConnectionComplete) { complete in
            if complete && scenePhase == .active && appUpdateCallIdle {
                Task { _ = await appUpdates.check(manual: false); presentAppUpdateIfIdle() }
            }
        }
        .onChange(of: model.inAppPresentedCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.activeCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.remoteCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.pendingOutgoingCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.errorMessage) { _ in presentAppUpdateIfIdle() }
        .onAppear {
            if let info = OtherAndroidCallPresentationRequest.consume() { _ = model.openOtherDeviceCallNotification(info) }
            if let sender = IncomingSMSPresentationRequest.consume() {
                openSMSConversation(sender)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimRemoteSMSReceived)) { _ in
            model.reloadMessagesFromLocalStore()
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenSMSConversation)) { notification in
            let sender = IncomingSMSPresentationRequest.consume()
                ?? notification.userInfo?["sender"] as? String
            guard let sender else {
                selectedTab = .messages
                return
            }
            openSMSConversation(sender)
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenIncomingCall)) { _ in
            model.presentCurrentCallInApp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenOtherAndroidCall)) { notification in
            let info = OtherAndroidCallPresentationRequest.consume() ?? notification.userInfo ?? [:]
            _ = model.openOtherDeviceCallNotification(info)
        }
        .alert(L10n.t("错误"), isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage?.isEmpty == false },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private func presentAppUpdateIfIdle() {
        guard scenePhase == .active, appUpdatePresentation == nil,
              appUpdateCallIdle, model.focusedOtherDeviceCall == nil,
              model.errorMessage == nil else { return }
        if appUpdates.needsNotes {
            appUpdatePresentation = .notes
        } else if firstConnectionComplete && selectedTabRawValue == PhoneTab.dial.rawValue,
                  let candidate = appUpdates.pendingUpdate {
            appUpdatePresentation = .result(.init(message: "发现应用新版本", candidate: candidate))
        }
    }

    private var appUpdateCallIdle: Bool {
        model.inAppPresentedCall == nil && model.activeCall == nil
            && model.remoteCall == nil && model.pendingOutgoingCall == nil
    }

    private func handleAppUpdateCallChange() {
        if !appUpdateCallIdle { appUpdatePresentation = nil }
        else { presentAppUpdateIfIdle() }
    }

    private var selectedTabBinding: Binding<PhoneTab> {
        Binding(
            get: { PhoneTab(rawValue: selectedTabRawValue) ?? .dial },
            set: { newTab in
                guard newTab.rawValue != selectedTabRawValue else { return }
                selectedTabRawValue = newTab.rawValue
            }
        )
    }

    private var selectedTab: PhoneTab {
        get { PhoneTab(rawValue: selectedTabRawValue) ?? .dial }
        nonmutating set { selectedTabRawValue = newValue.rawValue }
    }

    private var dialAgentID: String? {
        AndroidAgentBindingPreference.selected() ?? model.currentAndroidAgent?.id
    }

    private var dialIdle: Bool {
        appUpdateCallIdle && !model.callLifecycleSnapshot.state.representsCall && !submittingDial
    }

    private func dialLines(_ local: [IPhoneCellularLine]) -> [DialLineChoice] {
        DialLineChoice.roster(model: model, local: local)
    }

    private var defaultDialPreference: DialLinePreference {
        DialLinePreference(data: defaultDialLineData)
    }

    private var activeDialLine: DialLineChoice? {
        defaultDialPreference.resolve(in: dialLines(iPhoneInventory.lines))
    }

    private var dialPad: some View {
        let line = activeDialLine
        let missingTitle = defaultDialPreference == .unselected
            ? "选择通话线路" : "所选线路不可用 · 重新选择"
        let canSubmit = line.map { !$0.id.isAndroid || (!model.isBusy && model.canStartOutgoingCommand) }
            ?? !dialLines(iPhoneInventory.lines).isEmpty
        return DialPadView(lineTitle: line?.title ?? missingTitle,
            canDial: dialIdle && canSubmit,
            canChooseLine: dialIdle, chooseLine: { presentDialLines() },
            chooseAndroid: model.bindAndroidAgent,
            submit: {
                if let line { submitDial(using: line.id) }
                else { presentDialLines() }
            })
    }

    private func presentDialLines(onlyIfNeeded: Bool = false) {
        guard dialIdle else { return }
        iPhoneInventory = IPhoneCellularDialer.lineInventory
        let choices = dialLines(iPhoneInventory.lines)
        if onlyIfNeeded && (activeDialLine != nil || choices.isEmpty) { return }
        dialLineRequest = DialLineRequest(number: model.numberInput, choices: choices)
    }

    private func prefillDialPad(_ number: String) {
        showingConversation = false
        model.numberInput = number
        selectedTab = .dial
        dialLineRequest = nil
        presentDialLines(onlyIfNeeded: true)
    }

    private func selectDialLine(_ request: DialLineRequest, _ line: DialLineChoice) {
        guard dialLineRequest?.id == request.id else { return }
        dialLineRequest = nil
        iPhoneInventory = IPhoneCellularDialer.lineInventory
        guard request.permits(line.id, number: model.numberInput, live: dialLines(iPhoneInventory.lines), idle: dialIdle) else {
            model.errorMessage = "号码或通话线路已变化，请重新选择"
            return
        }
        do {
            defaultDialLineData = try JSONEncoder().encode(line.id)
            if case let .android(agent?, slot?) = line.id { model.selectSIMSlot(slot, for: agent) }
        } catch {
            model.errorMessage = "无法保存默认拨号线路"
        }
    }

    private func submitDial(using route: DialLineID) {
        guard dialIdle, !model.numberInput.isEmpty else { return }
        let number = model.numberInput
        iPhoneInventory = IPhoneCellularDialer.lineInventory
        guard dialLines(iPhoneInventory.lines).contains(where: { $0.id == route }) else {
            model.errorMessage = "所选通话线路已不可用，请重新选择"
            return
        }
        submittingDial = true
        Task { @MainActor in
            defer { submittingDial = false }
            guard model.numberInput == number, appUpdateCallIdle,
                  !model.callLifecycleSnapshot.state.representsCall else { return }
            do {
                switch route {
                case let .android(agent, slot):
                    guard !model.isBusy, model.canStartOutgoingCommand, agent == dialAgentID,
                          dialLines(iPhoneInventory.lines).contains(where: { $0.id == route }) else {
                        model.errorMessage = "安卓通话线路已变化或离线，请重新选择"
                        return
                    }
                    if let agent, let slot { model.selectSIMSlot(slot, for: agent) }
                    await model.dial()
                    return
                case .iPhone(let id):
                    try await IPhoneCellularDialer.dial(number, using: id)
                case .system:
                    try await IPhoneCellularDialer.dialWithSystem(number)
                }
                if model.numberInput == number { model.numberInput = "" }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleSystemCallActivity(_ activity: NSUserActivity) {
        guard let number = SystemCommunicationURL.callNumber(for: activity) else { return }
        prefillDialPad(number)
    }

    private func composeMessage(_ number: String) {
        showingConversation = false
        pendingSMSRecipient = number
        selectedTab = .messages
    }

    private func openSMSConversation(_ sender: String) {
        model.reloadMessagesFromLocalStore()
        showSMSConversation(sender)
    }

    private func showSMSConversation(_ sender: String) {
        selectedTab = .messages
        conversationSender = sender
        showingConversation = true
    }

    private func handleSystemCommunicationURL(_ url: URL) {
        if let target = AirSIMWidgetDestination.parse(url) {
            // Widget links only navigate. Never treat a widget tap as a dial or
            // SMS-send command, and never retarget an established call.
            if let id = target.agentID,
               !model.callLifecycleSnapshot.state.representsCall,
               !IPhoneCloudCallSession.shared.hasActiveCall,
               model.pairedAndroidAgents.contains(where: { $0.id == id }) {
                model.bindAndroidAgent(id)
            }
            switch target.destination {
            case .status: selectedTab = .settings
            case .dial: selectedTab = .dial
            case .messages: selectedTab = .messages
            case .contacts: selectedTab = .contacts
            case .recents: selectedTab = .recents
            }
            return
        }
        switch SystemCommunicationURL.destination(for: url) {
        case let .call(number):
            prefillDialPad(number)
        case let .liveActivity(action, callID):
            // Legacy links still open the app; use the same unified path as intents
            // so a stale island is dismissed instead of showing a Bluetooth-call error.
            Task { _ = await model.performLiveActivityAction(action, callID: callID) }
        case nil:
            break
        }
    }
}

/// 浅色模式使用系统电话式纯白底；深色模式才绘制深蓝黑底部环境光。
struct PhoneBackdrop: View {
    var grouped = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                Color(red: 0.008, green: 0.016, blue: 0.035)
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(red: 0.018, green: 0.075, blue: 0.16).opacity(0.72),
                        Color(red: 0.025, green: 0.20, blue: 0.48).opacity(0.62),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Color(uiColor: grouped ? .systemGroupedBackground : .systemBackground)
            }
        }
        .ignoresSafeArea()
    }
}

/// 内容卡片使用系统分组背景，保证深浅色和主题下的可读性。
struct PhoneCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct PhoneGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = interactive
                ? Glass.regular.tint(tint).interactive()
                : Glass.regular.tint(tint)
            content.glassEffect(
                glass,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08))
                }
        }
    }
}

/// 自定义工具栏材质仅用于隐藏了系统共享背景的 ToolbarItem，确保始终只有一层玻璃。
private struct PhoneToolbarGlassMorph: ViewModifier {
    let id: String
    @Namespace private var glassNamespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                content
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .glassEffectID(id, in: glassNamespace)
                    .glassEffectTransition(.materialize)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.82)))
        } else {
            content
        }
    }
}

/// iOS 26 隐藏导航栏自动生成的共享按钮背景，再使用上面的单层可变形玻璃；
/// 旧系统继续交给 ToolbarItem 使用平台默认样式。
@ToolbarContentBuilder
func phoneMorphingToolbarItem<Content: View>(
    placement: ToolbarItemPlacement,
    id: String,
    @ViewBuilder content: () -> Content
) -> some ToolbarContent {
    if #available(iOS 26.0, *) {
        ToolbarItem(placement: placement) {
            content().phoneToolbarGlassMorph(id: id)
        }
        .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}

extension View {
    func phoneCard() -> some View { modifier(PhoneCard()) }

    func phoneGlassSurface(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(PhoneGlassSurface(
            cornerRadius: cornerRadius,
            tint: tint,
            interactive: interactive
        ))
    }

    @ViewBuilder
    func phoneTabBarAlwaysExpanded() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.never)
        } else {
            self
        }
    }

    func phoneToolbarGlassMorph(id: String) -> some View {
        modifier(PhoneToolbarGlassMorph(id: id))
    }

    @ViewBuilder
    func phoneTabSelectionFeedback(_ trigger: String) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }
}

/// The entire TabView is the root of the outer navigation stack. Its native
/// bar fades with that root, below the opaque conversation being pushed/popped.
private struct PhoneTabBarNavigationFade: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private weak var nativeTabBar: UITabBar?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            transitionTabBar(visible: true, animated: animated)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            transitionTabBar(visible: false, animated: animated)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let bar = findTabBar() { Self.settle(bar, visible: true) }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if let bar = nativeTabBar { Self.settle(bar, visible: false) }
        }


        private func findTabBar() -> UITabBar? {
            if let nativeTabBar { return nativeTabBar }
            func find(in controller: UIViewController) -> UITabBar? {
                if let tabs = controller as? UITabBarController { return tabs.tabBar }
                for child in controller.children {
                    if let bar = find(in: child) { return bar }
                }
                return nil
            }
            var ancestor = parent
            while let controller = ancestor {
                if let bar = find(in: controller) {
                    nativeTabBar = bar
                    return bar
                }
                ancestor = controller.parent
            }
            return nil
        }

        private func transitionTabBar(visible: Bool, animated: Bool) {
            guard let bar = findTabBar() else { return }
            bar.isUserInteractionEnabled = false
            bar.accessibilityElementsHidden = true
            guard animated, !UIAccessibility.isReduceMotionEnabled,
                  let coordinator = transitionCoordinator else {
                Self.settle(bar, visible: visible)
                return
            }
            let queued = coordinator.animateAlongsideTransition(in: bar, animation: { _ in
                bar.alpha = visible ? 1 : 0
            }, completion: { context in
                let finalVisible = context.isCancelled ? !visible : visible
                Self.settle(bar, visible: finalVisible)
            })
            if !queued { Self.settle(bar, visible: visible) }
        }

        private static func settle(_ bar: UITabBar, visible: Bool) {
            bar.alpha = visible ? 1 : 0
            bar.isUserInteractionEnabled = visible
            bar.accessibilityElementsHidden = !visible
        }
    }
}

/// One split-view hierarchy survives folding/resizing without recreating the
/// thread composer. Compact columns are managed by the system's back gesture.
@available(iOS 17.0, *)
private struct AdaptiveMessagesView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var pendingRecipient: String?
    @Binding var state: SMSConversationListState
    @Binding var sender: String?
    @Binding var showingConversation: Bool
    let openConversation: (String) -> Void
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            MessagesView(pendingRecipient: $pendingRecipient, state: $state,
                         openConversation: openConversation)
                .navigationTitle(L10n.t("短信"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar { SMSConversationListToolbar(state: $state) }
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            if let sender, showingConversation {
                MessageThreadView(sender: sender)
                    .id(sender)
            } else {
                ContentUnavailableView("选择一段对话", systemImage: "message",
                    description: Text("从左侧选择短信，或新建一条短信。"))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(horizontalSizeClass == .compact && showingConversation ? .hidden : .automatic, for: .tabBar)
        .onChange(of: showingConversation) { _, showing in
            compactColumn = showing ? .detail : .sidebar
        }
        .onChange(of: compactColumn) { _, column in
            if horizontalSizeClass == .compact && column == .sidebar {
                showingConversation = false
            }
        }
        .onAppear { compactColumn = showingConversation ? .detail : .sidebar }
    }
}


enum DialLineID: Hashable, Codable {
    case android(agentID: String?, slotID: String?)
    case iPhone(UUID)
    case system

    var isAndroid: Bool {
        if case .android = self { return true }
        return false
    }
}

enum DialLinePreference: Equatable {
    case unselected, chosen(DialLineID), unreadable

    static let storageKey = "airsim.default-outgoing-voice-line.v1"

    static func storedSummary(in inventory: IPhoneCellularLineInventory, defaults: UserDefaults = .standard) -> String {
        let saved = Self(data: defaults.data(forKey: storageKey) ?? Data())
        switch saved {
        case .unselected: return "尚未选择"
        case .unreadable: return "已保存的线路设置无法读取，请重新选择"
        case .chosen(.system): return "iPhone 系统选线"
        case .chosen(.android): return "指定安卓线路"
        case .chosen(.iPhone(let id)):
            switch inventory {
            case .reported(let lines):
                return lines.contains { $0.id == id } ? "指定 iPhone SIM（本次可见）" : "指定 iPhone SIM（本次未返回）"
            default: return "指定 iPhone SIM（尚未核实可用性）"
            }
        }
    }

    init(data: Data) {
        if data.isEmpty { self = .unselected }
        else if let id = try? JSONDecoder().decode(DialLineID.self, from: data) { self = .chosen(id) }
        else { self = .unreadable }
    }

    func resolve(in choices: [DialLineChoice]) -> DialLineChoice? {
        guard case .chosen(let id) = self else { return nil }
        return choices.first { $0.id == id }
    }
}

struct DialLineChoice: Identifiable, Equatable {
    let id: DialLineID
    let title: String

    @MainActor
    static func roster(model: AppModel, local: [IPhoneCellularLine]) -> [Self] {
        let agent = AndroidAgentBindingPreference.selected() ?? model.currentAndroidAgent?.id
        return roster(agentID: agent, slots: agent.map { model.simSlots(for: $0) } ?? [],
            hasAndroid: agent != nil || model.canStartOutgoingCommand, local: local,
            supportsSystem: IPhoneCellularDialer.supportsSystemFallback)
    }

    static func roster(agentID: String?, slots: [AndroidSIMSlot], hasAndroid: Bool,
                       local: [IPhoneCellularLine], supportsSystem: Bool) -> [Self] {
        var choices: [Self] = []
        if let agentID, !slots.isEmpty {
            choices = slots.map { slot in
                Self(id: .android(agentID: agentID, slotID: slot.id),
                     title: "安卓 · \(CompactSIMSelectionPanel.title(for: slot))")
            }
        } else if hasAndroid {
            choices.append(Self(id: .android(agentID: agentID, slotID: nil), title: "安卓默认线路"))
        }
        choices += local.map { Self(id: .iPhone($0.id), title: "iPhone · \($0.label)") }
        if supportsSystem { choices.append(Self(id: .system, title: "iPhone · 由系统选择 SIM")) }
        return choices
    }
}

struct DialLineRequest: Identifiable {
    let id: UUID
    let number: String
    let choices: [DialLineChoice]

    init(id: UUID = UUID(), number: String, choices: [DialLineChoice]) {
        self.id = id
        self.number = number
        self.choices = choices
    }

    func permits(_ route: DialLineID, number currentNumber: String, live: [DialLineChoice], idle: Bool) -> Bool {
        idle && number == currentNumber && choices.contains { $0.id == route } && live.contains { $0.id == route }
    }
}

private struct DialLinePicker: ViewModifier {
    @Binding var request: DialLineRequest?
    @Binding var inventory: IPhoneCellularLineInventory
    let preference: DialLinePreference
    let choose: (DialLineRequest, DialLineChoice) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            Color.clear.frame(width: 1, height: 1)
                .popover(item: $request) { captured in
                    DialLinePickerContents(request: captured, inventory: $inventory,
                        preference: preference, choose: choose)
                        .compactSIMPopoverPresentation()
                }
        }
    }
}

private struct DialLinePickerContents: View {
    @EnvironmentObject private var model: AppModel
    let request: DialLineRequest
    @Binding var inventory: IPhoneCellularLineInventory
    let preference: DialLinePreference
    let choose: (DialLineRequest, DialLineChoice) -> Void

    var body: some View {
        let choices = DialLineChoice.roster(model: model, local: inventory.lines)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("默认拨号线路").font(.headline)
                Spacer()
                Button { inventory = IPhoneCellularDialer.lineInventory } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新本机线路")
            }
            if choices.isEmpty { Text("没有可用线路").foregroundStyle(.secondary) }
            ForEach(choices) { line in
                Button {
                    let visible = DialLineRequest(id: request.id, number: request.number,
                        choices: choices)
                    choose(visible, line)
                } label: {
                    row(line.title, icon: line.id.isAndroid ? "simcard" : "iphone", selected: preference == .chosen(line.id))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(idealWidth: 315)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func row(_ title: String, icon: String, selected: Bool) -> some View {
        HStack {
            Image(systemName: icon)
            Text(title).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if selected { Image(systemName: "checkmark") }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
