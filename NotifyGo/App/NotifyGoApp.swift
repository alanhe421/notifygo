import SwiftUI

@main
struct NotifyGoApp: App {
    @StateObject private var store = CallbackStore()
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .id(appLanguage)
                .environment(\.locale, selectedLanguage.locale)
                .environmentObject(store)
                .tint(.blue)
                .task {
                    await store.refresh()
                    await pushDelegate.attach(store)
                }
        }
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .system
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            Locale(identifier: Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier)
        default:
            Locale(identifier: rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
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
