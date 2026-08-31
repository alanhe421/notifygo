import SwiftUI
import UIKit

struct EndpointDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EndpointStore
    let endpointID: UUID
    @State private var isEditing = false
    @State private var confirmsDelete = false

    var body: some View {
        Group {
            if let endpoint = store.endpoint(id: endpointID) {
                List {
                    Section { NotificationPreview(endpoint: endpoint).listRowInsets(EdgeInsets()) }
                    Section("Push URL") {
                        Text(endpoint.pushURL.absoluteString)
                            .font(.body.monospaced()).textSelection(.enabled)
                        Button { UIPasteboard.general.string = endpoint.pushURL.absoluteString } label: {
                            Label("Copy Push URL", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: endpoint.pushURL) { Label("Share Push URL", systemImage: "square.and.arrow.up") }
                    } footer: {
                        Label("Mock only — the NotifyGo service is not connected.", systemImage: "exclamationmark.triangle")
                    }
                    Section {
                        LabeledContent("Sound", value: endpoint.sound.name)
                        LabeledContent("Badge", value: endpoint.includesBadge ? "On" : "Off")
                        if !endpoint.group.isEmpty { LabeledContent("Group", value: endpoint.group) }
                        if !endpoint.destinationURL.isEmpty { LabeledContent("Opens", value: endpoint.destinationURL) }
                    }
                    Section {
                        Button("Delete Endpoint", role: .destructive) { confirmsDelete = true }
                    }
                }
                .navigationTitle(endpoint.name)
                .toolbar {
                    Button("Edit") { isEditing = true }
                }
                .sheet(isPresented: $isEditing) { EndpointEditorView(endpoint: endpoint) }
                .confirmationDialog("Delete \(endpoint.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        store.delete(id: endpoint.id)
                        dismiss()
                    }
                } message: { Text("This endpoint and its local configuration will be removed.") }
            } else {
                ContentUnavailableView("Endpoint unavailable", systemImage: "bell.slash", description: Text("It may have been deleted."))
            }
        }
    }
}
