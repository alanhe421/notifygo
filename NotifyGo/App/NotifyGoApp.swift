import SwiftUI

@main
struct NotifyGoApp: App {
    @StateObject private var store = EndpointStore()

    var body: some Scene {
        WindowGroup {
            EndpointListView()
                .environmentObject(store)
                .tint(.blue)
        }
    }
}
