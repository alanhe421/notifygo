import SwiftUI

struct EndpointListView: View {
    @EnvironmentObject private var store: EndpointStore
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Group {
                if store.endpoints.isEmpty {
                    ContentUnavailableView {
                        Label("No endpoints yet", systemImage: "bell.badge")
                    } description: {
                        Text("Create an endpoint, configure its notification, then copy its Push URL.")
                    } actions: {
                        Button("Create Endpoint") { isCreating = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(store.endpoints) { endpoint in
                                NavigationLink(value: endpoint.id) {
                                    EndpointRow(endpoint: endpoint)
                                }
                                .swipeActions {
                                    Button(role: .destructive) { store.delete(id: endpoint.id) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } footer: {
                            Text("Push URLs are mock addresses and do not send notifications yet.")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("NotifyGo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isCreating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Create endpoint")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                EndpointDetailView(endpointID: id)
            }
            .sheet(isPresented: $isCreating) {
                EndpointEditorView(endpoint: NotificationEndpoint())
            }
        }
    }
}

private struct EndpointRow: View {
    let endpoint: NotificationEndpoint

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: endpoint.symbolName)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(endpoint.accent.color.gradient, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(endpoint.name).font(.headline)
                Text(endpoint.defaultTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(endpoint.name), \(endpoint.defaultTitle)")
    }
}
