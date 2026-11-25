import SwiftUI

/// AirSIM iPhone/iPad 入口：三星 VoWLAN 与独立云端 Relay。
@main
struct AirSIMIPadApp: App {
    // One lazy instance for both scene presentation and background widget intents.
    // Do not wait for onAppear, or create a second transport/CallKit owner.
    private static let productionModel = AppModel()
    @UIApplicationDelegateAdaptor(AirSIMNotificationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var settings = AppSettings()
    @StateObject private var appUpdates: AppUpdateController
    @Environment(\.scenePhase) private var scenePhase
    private let uiTestDefaults: UserDefaults?

    init() {
#if DEBUG && targetEnvironment(simulator)
        let fixture = SMSNavigationFixture.fromLaunchEnvironment()
        _model = StateObject(wrappedValue: fixture?.model ?? Self.productionModel)
        _appUpdates = StateObject(wrappedValue: fixture?.updates ?? AppUpdateController())
        uiTestDefaults = fixture?.defaults
#else
        _model = StateObject(wrappedValue: Self.productionModel)
        _appUpdates = StateObject(wrappedValue: AppUpdateController())
        uiTestDefaults = nil
#endif
        if uiTestDefaults == nil {
            AirSIMWidgetControlBridge.bootstrap = {
                // A locked cold launch must not overwrite protected history or
                // take ownership away from an incoming PushKit call handler.
                guard UIApplication.shared.isProtectedDataAvailable,
                      !CallKitController.shared.managesCurrentCall else { return }
                _ = Self.productionModel
            }
        }
    }

    // Resolve the owner before CallKit fulfills the answer. The AppModel adopts
    // the exact PushKit identity in init and owns all later CallKit callbacks.
    @MainActor
    static func adoptColdLaunchAnswer(uuid: UUID) {
        let callKit = CallKitController.shared
        let mode = ConnectionModePreference.selected()
        guard callKit.handler is ColdLaunchCallKitHandler,
              mode == .automatic || mode == .vowlan || mode == .localDual,
              let incoming = callKit.currentIncomingPush, incoming.uuid == uuid,
              !incoming.isVirtual, let agentID = incoming.agentID,
              PairedAndroidDeviceStore.permits(agentID),
              VoWLANCredentialStore.load(agentID: agentID) != nil,
              callKit.matchesCurrentCall(callID: incoming.callID, uuid: uuid,
                                         agentID: agentID, generation: incoming.generation) else { return }
        let model = productionModel
        if callKit.handler is ColdLaunchCallKitHandler {
            callKit.handler = model
            (UIApplication.shared.delegate as? AirSIMNotificationDelegate)?.releaseColdLaunchHandler()
            model.callKitDidReceiveIncoming(incoming)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.contacts)
                .environmentObject(model.audio)
                .environmentObject(settings)
                .environmentObject(appUpdates)
                .defaultAppStorage(uiTestDefaults ?? .standard)
                .onAppear {
                    guard uiTestDefaults == nil else { return }
                    appDelegate.knownSMSSender = { [weak model] sender in
                        model.map { $0.contacts.contact(for: sender) != nil } ?? true
                    }
                    WatchCallCoordinator.shared.configure(model: model)
                    WatchCallCoordinator.shared.start()
                    model.start(sceneIsActive: scenePhase == .active)
                }
        }
        .onChange(of: scenePhase) { phase in
            guard uiTestDefaults == nil else { return }
            switch phase {
            case .active:
                IPhoneCarrierMessaging.shared.refresh()
                model.didBecomeActive()
            case .inactive:
                // 必须在真正进入后台前启动音频会话；等到 .background 才启动时，
                // iOS 可能已经冻结进程，后续来电和短信事件便无法继续等待。
                model.willResignActive()
            case .background:
                model.didEnterBackground()
            default:
                break
            }
        }
    }
}
