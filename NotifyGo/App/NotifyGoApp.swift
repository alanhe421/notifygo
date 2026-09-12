import SwiftUI

@main
struct NotifyGoApp: App {
    @StateObject private var store = CallbackStore()
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate

    var body: some Scene {
        WindowGroup {
            CallbackHomeView()
                .environmentObject(store)
                .tint(.blue)
                .task {
                    await store.refresh()
                    await pushDelegate.attach(store)
                }
        }
    }
}
