import GoogleSignIn
import SwiftUI
import UIKit
import UserNotifications

enum Route: Hashable {
    case list(ReminderFilter)
    /// The reminder with this external identifier: its fields and its assistant conversation.
    case thread(String)
    /// Plan my day: the reminders worth working on today.
    case plan
}

/// The objects the whole app shares. The app delegate needs them too, for
/// pushes that arrive while no view is on screen.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let session = Session()
    let reminders = RemindersStore()
    let assistant = AssistantStore()
    let planner = PlannerStore()
    var path: [Route] = []

    func refresh() async {
        await reminders.start()
        await assistant.sync(session: session, reminders: reminders)
    }

    func open(reminderId: String) {
        path = [.thread(reminderId)]
    }

    func enablePush() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if let clientID = GoogleConfig.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            let model = AppModel.shared
            await model.assistant.registerDevice(token: token, session: model.session)
        }
    }

    /// A push means the assistant settled or queued edits: sync applies them
    /// to Reminders even when the app is in the background.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await AppModel.shared.refresh()
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let reminderId = notification.request.content.userInfo["reminderId"] as? String
        // No banner for the thread already on screen.
        if let reminderId, AppModel.shared.path.last == .thread(reminderId) { return [] }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let reminderId = response.notification.request.content.userInfo["reminderId"] as? String else { return }
        AppModel.shared.open(reminderId: reminderId)
    }
}

@main
struct RemindersAIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.session)
                .environment(model.reminders)
                .environment(model.assistant)
                .environment(model.planner)
                .onOpenURL { _ = GIDSignIn.sharedInstance.handle($0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active, model.session.isSignedIn else { return }
                    Task { await model.refresh() }
                }
        }
    }
}

enum GoogleConfig {
    /// The iOS OAuth client id, or nil while project.yml still has its placeholder.
    static var clientID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !id.isEmpty, !id.hasPrefix("YOUR_") else { return nil }
        return id
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    @Environment(RemindersStore.self) private var reminders
    @Environment(AssistantStore.self) private var assistant

    var body: some View {
        Group {
            if !session.isSignedIn {
                SignInView()
            } else if reminders.access == .denied {
                AccessDeniedView()
            } else {
                HomeView()
            }
        }
        .animation(.default, value: session.isSignedIn)
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn {
                Task {
                    await model.refresh()
                    await model.enablePush()
                }
            } else {
                assistant.reset()
                model.planner.reset()
                model.path = []
            }
        }
        .task {
            guard session.isSignedIn else { return }
            await model.enablePush()
        }
    }
}

struct AccessDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Reminders access is off", systemImage: "checklist")
        } description: {
            Text("This app shows and edits your Apple Reminders. Allow full access in Settings to continue.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
