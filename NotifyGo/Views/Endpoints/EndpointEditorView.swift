import SwiftUI

struct EndpointEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EndpointStore
    @State private var draft: NotificationEndpoint
    @State private var showsAdvanced = false
    @State private var attemptedSave = false

    private let symbols = ["bell.badge.fill", "shippingbox.fill", "server.rack", "checkmark.seal.fill", "cart.fill", "bolt.fill"]

    init(endpoint: NotificationEndpoint) {
        _draft = State(initialValue: endpoint)
        _showsAdvanced = State(initialValue: !endpoint.group.isEmpty || !endpoint.destinationURL.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") { NotificationPreview(endpoint: draft).listRowInsets(EdgeInsets()) }

                Section("Identity") {
                    TextField("Endpoint name", text: $draft.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Endpoint name")
                    if attemptedSave, let error = EndpointValidation.nameError(draft.name) {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Picker("Icon", selection: $draft.symbolName) {
                        ForEach(symbols, id: \.self) { symbol in
                            Label(symbol.replacingOccurrences(of: ".fill", with: ""), systemImage: symbol).tag(symbol)
                        }
                    }
                    Picker("Accent", selection: $draft.accent) {
                        ForEach(NotificationEndpoint.Accent.allCases) { accent in
                            Label(accent.name, systemImage: "circle.fill").foregroundStyle(accent.color).tag(accent)
                        }
                    }
                }

                Section("Default notification") {
                    TextField("Title", text: $draft.defaultTitle)
                    TextField("Body", text: $draft.defaultBody, axis: .vertical).lineLimit(2...5)
                    Picker("Sound", selection: $draft.sound) {
                        ForEach(NotificationEndpoint.Sound.allCases) { sound in Text(sound.name).tag(sound) }
                    }
                    Toggle("Update app badge", isOn: $draft.includesBadge)
                }

                Section {
                    DisclosureGroup("Advanced options", isExpanded: $showsAdvanced) {
                        TextField("Group (optional)", text: $draft.group)
                        TextField("Open URL (optional)", text: $draft.destinationURL)
                            .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                        if attemptedSave, let error = EndpointValidation.destinationError(draft.destinationURL) {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                } footer: {
                    Text("iOS controls the final notification layout. NotifyGo configures content, sound, grouping, badge, and tap destination.")
                }
            }
            .navigationTitle(store.endpoint(id: draft.id) == nil ? "New Endpoint" : "Edit Endpoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        attemptedSave = true
                        guard EndpointValidation.isValid(draft) else { return }
                        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.save(draft)
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
        }
    }
}
