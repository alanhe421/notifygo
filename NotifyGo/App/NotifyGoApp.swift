import SwiftUI

@main
struct NotifyGoApp: App {
    @StateObject private var store = CallbackStore()
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(store)
                .tint(.blue)
                .task {
                    await store.refresh()
                    await pushDelegate.attach(store)
                }
        }
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            CallbackHomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            NotificationHistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
