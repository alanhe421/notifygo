import UIKit
import UserNotifications

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var store: CallbackStore?
    private var pendingToken: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    @MainActor
    func attach(_ store: CallbackStore) async {
        self.store = store
        if let pendingToken {
            do { try await store.registerDevice(pendingToken) } catch { store.report(error) }
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        pendingToken = token
        Task { @MainActor in
            do { try await store?.registerDevice(token) } catch { store?.report(error) }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in store?.report(error) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let metadata = response.notification.request.content.userInfo["notifygo"] as? [String: Any]
        if let text = metadata?["url"] as? String, let url = URL(string: text),
           ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        completionHandler()
    }
}
