import SwiftUI
import UIKit

struct CallbackHomeView: View {
    @EnvironmentObject private var store: CallbackStore
    @Environment(\.openURL) private var openURL
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                if !store.deviceRegistered {
                    Section {
                        Button("Enable notifications") { Task { await store.enableNotifications() } }
                            .disabled(!store.connected)
                        Button("Open notification settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    } footer: { Text("Allow notifications, create a Callback, then send a test. No server setup is needed.") }
                }
                if store.isLoading && store.callbacks.isEmpty { ProgressView("Connecting…") }
                else if !store.connected {
                    ContentUnavailableView("Service unavailable", systemImage: "wifi.exclamationmark", description: Text("Try connecting again. If this continues, contact the app publisher."))
                    Button("Retry") { Task { await store.refresh() } }
                } else if store.callbacks.isEmpty {
                    ContentUnavailableView("No Callbacks yet", systemImage: "bell.badge", description: Text("Turn a JSON payload or App Store event into a notification."))
                    Button("Create Callback") { creating = true }
                }
                ForEach(store.callbacks) { callback in
                    NavigationLink(value: callback.id) {
                        HStack {
                            SourceIcon(symbol: callback.symbol, emoji: callback.emoji, imageURL: callback.imageURL, color: callback.color)
                            VStack(alignment: .leading) {
                                Text(callback.name).font(.headline)
                                Text(callback.enabled ? (callback.parser == "apple" ? "App Store transactions" : "Generic JSON") : "Paused")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("NotifyGo")
            .refreshable { await store.refresh() }
            .toolbar {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Create Callback").disabled(!store.connected)
            }
            .navigationDestination(for: String.self) { CallbackDetailView(id: $0) }
            .sheet(isPresented: $creating) { CallbackEditorView(callback: HostedCallback()) }
            .alert("NotifyGo", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
        }
    }
}

struct SourceIcon: View {
    let symbol: String
    let emoji: String
    let imageURL: String
    let color: String
    private var accent: Color { (NotificationEndpoint.Accent(rawValue: color) ?? .blue).color }

    var body: some View {
        Group {
            if !imageURL.isEmpty, let url = URL(string: imageURL), url.scheme == "https" {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else { fallback }
                }
            } else { fallback }
        }
        .frame(width: 40, height: 40)
        .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
    private var fallback: some View {
        Group {
            if !emoji.isEmpty { Text(emoji).font(.title2) }
            else { Image(systemName: UIImage(systemName: symbol) == nil ? "bell.badge.fill" : symbol).foregroundStyle(accent) }
        }
    }
}

struct CallbackDetailView: View {
    @EnvironmentObject private var store: CallbackStore
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var editing = false
    @State private var testing = false
    @State private var confirmDelete = false
    @State private var confirmRotate = false
    @State private var busy = false
    @State private var copied = false

    var body: some View {
        Group {
            if let callback = store.callbacks.first(where: { $0.id == id }) {
                List {
                    Section("Callback URL") {
                        if let url = callback.callbackURL {
                            Text(url).font(.footnote.monospaced()).textSelection(.enabled)
                            Button(copied ? "Copied" : "Copy URL") {
                                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: url]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                                copied = true
                            }
                        } else { Text("Reset the key to obtain a new URL.") }
                        Button("Reset key", role: .destructive) { confirmRotate = true }
                    } footer: { Text("Anyone with this URL can trigger this Callback. Resetting the key immediately invalidates the old URL.") }
                    Section {
                        Button(callback.enabled ? "Pause Callback" : "Enable Callback") {
                            perform {
                                var updated = callback
                                updated.enabled.toggle()
                                _ = try await store.save(updated)
                            }
                        }
                        Button("Test & preview") { testing = true }
                        NavigationLink("Recent notifications") { CallbackHistoryView(id: id) }
                    }
                    Section {
                        Text("Rules run from lowest priority number to highest. The first matching rule wins. No match means no notification.")
                        ForEach(callback.rules.sorted { $0.priority < $1.priority }) { rule in
                            LabeledContent(rule.name, value: "\(rule.priority) · \(rule.enabled ? (rule.send ? "Send" : "Suppress") : "Disabled")")
                        }
                    }
                    Section { Button("Delete Callback", role: .destructive) { confirmDelete = true } }
                }
                .disabled(busy)
                .navigationTitle(callback.name)
                .toolbar { Button("Edit") { editing = true }.disabled(busy) }
                .sheet(isPresented: $editing) { CallbackEditorView(callback: callback) }
                .sheet(isPresented: $testing) { CallbackTestView(callback: callback, canSend: true) }
                .confirmationDialog("Reset Callback key?", isPresented: $confirmRotate, titleVisibility: .visible) {
                    Button("Reset key", role: .destructive) { perform { try await store.rotate(id); copied = false } }
                } message: { Text("Update the URL at every third-party service after resetting.") }
                .confirmationDialog("Delete Callback and history?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { perform { try await store.delete(id); dismiss() } }
                }
            } else { ContentUnavailableView("Callback unavailable", systemImage: "bell.slash") }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { store.report(error) }
        }
    }
}

struct CallbackEditorView: View {
    @EnvironmentObject private var store: CallbackStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HostedCallback
    @State private var saving = false
    @State private var previewing = false
    @State private var error: String?

    init(callback: HostedCallback) { _draft = State(initialValue: callback) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Callback") {
                    TextField("Name", text: $draft.name)
                    Toggle("Enabled", isOn: $draft.enabled)
                    Picker("Payload parser", selection: $draft.parser) {
                        Text("Generic JSON").tag("json")
                        Text("App Store transactions").tag("apple")
                    }
                    if draft.parser == "apple" {
                        TextField("App Bundle ID", text: $draft.appleBundleId).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("App Apple ID (required for production)", value: $draft.appleAppId, format: .number.grouping(.never)).keyboardType(.numberPad)
                        Picker("Environment", selection: $draft.appleEnvironment) {
                            Text("Sandbox").tag("Sandbox"); Text("Production").tag("Production")
                        }
                        Text("Verified fields: type, subtype, product, amount, currency, country, environment. Country uses the three-letter storefront code. Amount is in currency units, not milliunits.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Source appearance") {
                    TextField("SF Symbol", text: $draft.symbol).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Emoji (optional)", text: $draft.emoji)
                    TextField("Image HTTPS URL (optional)", text: $draft.imageURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Color", selection: $draft.color) {
                        ForEach(NotificationEndpoint.Accent.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    TextField("Tags, separated by commas", text: Binding(get: { draft.tags.joined(separator: ",") }, set: { draft.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                    HStack { SourceIcon(symbol: draft.symbol, emoji: draft.emoji, imageURL: draft.imageURL, color: draft.color); Text(draft.name) }
                    Text("The iOS notification App Icon is always NotifyGo. Source appearance is used in attachments and history; iOS controls notification backgrounds.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Field mapping") {
                    ForEach(draft.mappings.indices, id: \.self) { index in
                        VStack {
                            TextField("Alias (for {{mapped.alias}})", text: $draft.mappings[index].field)
                            TextField("Source path, e.g. event.title", text: $draft.mappings[index].source)
                            Button("Remove mapping", role: .destructive) { draft.mappings.remove(at: index) }
                        }.textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button("Add field mapping") { draft.mappings.append(FieldMapping()) }.disabled(draft.mappings.count >= 30)
                }
                Section {
                    ForEach($draft.rules) { $rule in
                        NavigationLink { CallbackRuleEditor(rule: $rule) } label: {
                            LabeledContent(rule.name, value: "Priority \(rule.priority)")
                        }
                    }
                    .onDelete { draft.rules.remove(atOffsets: $0) }
                    Button("Add rule") { draft.rules.append(CallbackRule(name: "Rule \(draft.rules.count + 1)", priority: (draft.rules.count + 1) * 100)) }.disabled(draft.rules.count >= 30)
                } header: { Text("Rules") } footer: {
                    Text("AND conditions. Lowest priority number wins; ties use rule ID. An empty condition list matches all payloads. Missing template fields prevent sending.")
                }
                Section { Button("Preview sample payload") { previewing = true } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .disabled(saving)
            .navigationTitle(draft.id.isEmpty ? "New Callback" : "Edit Callback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task { @MainActor in
                            defer { saving = false }
                            do { _ = try await store.save(draft); dismiss() } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.rules.isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $previewing) { CallbackTestView(callback: draft, canSend: false) }
            .onChange(of: draft.parser) {
                guard draft.parser == "apple", draft.rules.count == 1,
                      draft.rules[0].template == CallbackTemplate(), draft.rules[0].conditions.isEmpty else { return }
                var transaction = CallbackRule(name: "Transaction", priority: 100)
                transaction.conditions = [CallbackCondition(field: "amount", op: "gt", value: .number(0))]
                transaction.template.title = "{{type}} · {{product}}"
                transaction.template.body = "{{amount}} {{currency}} · {{country}}"
                var fallback = CallbackRule(name: "Other App Store events", priority: 1000)
                fallback.template.title = "{{type}}"
                fallback.template.body = "Environment: {{environment}}"
                draft.rules = [transaction, fallback]
            }
        }
    }
}

struct CallbackRuleEditor: View {
    @Binding var rule: CallbackRule

    var body: some View {
        Form {
            Section("Rule") {
                TextField("Rule name", text: $rule.name)
                TextField("Priority", value: $rule.priority, format: .number.grouping(.never)).keyboardType(.numberPad)
                Toggle("Enabled", isOn: $rule.enabled)
                Toggle("Send when matched", isOn: $rule.send)
            }
            Section("All conditions must match") {
                ForEach(rule.conditions.indices, id: \.self) { index in
                    ConditionEditor(condition: $rule.conditions[index])
                    Button("Remove condition", role: .destructive) { rule.conditions.remove(at: index) }
                }
                Button("Add condition") { rule.conditions.append(CallbackCondition()) }.disabled(rule.conditions.count >= 20)
            }
            if rule.send {
                Section("Notification template") {
                    TextField("Title, e.g. {{type}} · {{product}}", text: $rule.template.title)
                    TextField("Body", text: $rule.template.body, axis: .vertical).lineLimit(2...6)
                    TextField("Open URL (optional)", text: $rule.template.url).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Sound", selection: $rule.template.sound) {
                        Text("Default").tag("default"); Text("Silent").tag("none")
                    }
                    Picker("Notification level", selection: $rule.template.level) {
                        Text("Passive").tag("passive"); Text("Active").tag("active"); Text("Time Sensitive").tag("time-sensitive")
                    }
                    Picker("Badge", selection: $rule.template.badge) {
                        Text("Keep unchanged").tag("unchanged"); Text("Set number").tag("set")
                        Text("Add one").tag("increment"); Text("Clear").tag("clear")
                    }
                    if rule.template.badge == "set" {
                        TextField("Badge number", value: $rule.template.badgeValue, format: .number.grouping(.never)).keyboardType(.numberPad)
                    }
                    Text("Use {{field.path}} for variables. URL variable values are percent-encoded. iOS permissions and Focus settings determine presentation.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Edit rule")
    }
}

private struct ConditionEditor: View {
    @Binding var condition: CallbackCondition
    private var kind: Binding<String> {
        Binding(get: {
            switch condition.value { case .number: "number"; case .bool: "boolean"; default: "text" }
        }, set: { value in
            switch value { case "number": condition.value = .number(0); case "boolean": condition.value = .bool(true); default: condition.value = .string("") }
        })
    }
    var body: some View {
        VStack(alignment: .leading) {
            TextField("Field path", text: $condition.field).textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker("Operator", selection: $condition.op) {
                Text("Equals").tag("eq"); Text("Not equal").tag("ne"); Text("Contains").tag("contains")
                Text("Greater than").tag("gt"); Text("Less than").tag("lt")
            }
            Picker("Value type", selection: kind) {
                Text("Text").tag("text"); Text("Number").tag("number"); Text("Boolean").tag("boolean")
            }
            switch condition.value {
            case .number(let value):
                TextField("Number", value: Binding(get: { if case .number(let n) = condition.value { return n }; return value }, set: { condition.value = .number($0) }), format: .number.grouping(.never)).keyboardType(.decimalPad)
            case .bool(let value):
                Toggle("True", isOn: Binding(get: { if case .bool(let b) = condition.value { return b }; return value }, set: { condition.value = .bool($0) }))
            default:
                TextField("Value", text: Binding(get: { condition.value.text }, set: { condition.value = .string($0) }))
            }
        }
    }
}

struct CallbackTestView: View {
    @EnvironmentObject private var store: CallbackStore
    @Environment(\.dismiss) private var dismiss
    let callback: HostedCallback
    let canSend: Bool
    @State private var text: String
    @State private var appleSample: Bool
    @State private var result: CallbackPreview?
    @State private var error: String?
    @State private var busy = false

    init(callback: HostedCallback, canSend: Bool) {
        self.callback = callback; self.canSend = canSend
        _text = State(initialValue: callback.sample)
        _appleSample = State(initialValue: callback.parser == "apple")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Payload") {
                    if callback.parser == "apple" {
                        Toggle("Use decoded sample (preview only)", isOn: $appleSample)
                        Text(appleSample ? "Sample data is not signature verified and cannot send a push." : "Paste the original JSON object containing signedPayload. Both event and transaction signatures are verified.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 180)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("JSON payload")
                    Button("Preview") { run(send: false) }
                    if canSend {
                        Button("Send test notification") { run(send: true) }
                            .disabled(appleSample || !store.deviceRegistered || !callback.enabled)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if let result {
                    Section("Result") {
                        Text(result.status)
                        if result.sampleOnly == true { Text("Unverified sample · preview only").foregroundStyle(.orange) }
                        if let notification = result.notification {
                            Text(notification.title).font(.headline)
                            Text(notification.body)
                            if !notification.url.isEmpty { Text(notification.url).textSelection(.enabled) }
                        }
                        if !result.missing.isEmpty { Text("Missing fields: \(result.missing.joined(separator: ", "))") }
                    }
                    Section("Rule matching") {
                        ForEach(result.trace) { trace in
                            Label(trace.name, systemImage: result.matchedRuleId == trace.id ? "checkmark.seal.fill" : trace.matched ? "checkmark.circle" : "minus.circle")
                                .accessibilityLabel("\(trace.name): \(result.matchedRuleId == trace.id ? "selected" : trace.matched ? "matched, not selected" : "not matched")")
                        }
                    }
                    Section("Parsed fields") { Text(result.fields.pretty).font(.footnote.monospaced()).textSelection(.enabled) }
                }
            }
            .disabled(busy)
            .onChange(of: text) { result = nil; error = nil }
            .onChange(of: appleSample) { result = nil; error = nil }
            .navigationTitle("Test & preview")
            .toolbar { Button("Done") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
        }
    }
    private func run(send: Bool) {
        busy = true; error = nil; result = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                if send { result = try await store.test(callback.id, text: text) }
                else { result = try await store.preview(callback, text: text, appleSample: appleSample) }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CallbackHistoryView: View {
    @EnvironmentObject private var store: CallbackStore
    let id: String
    @State private var events: [CallbackEvent] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        List {
            if loading { ProgressView("Loading…") }
            if let error { Text(error); Button("Retry") { Task { await load() } } }
            if !loading && error == nil && events.isEmpty { ContentUnavailableView("No notifications yet", systemImage: "tray") }
            ForEach(events) { event in
                DisclosureGroup {
                    Text(event.fields.pretty).font(.footnote.monospaced()).textSelection(.enabled)
                } label: {
                    HStack(alignment: .top) {
                        SourceIcon(symbol: event.source.symbol, emoji: event.source.emoji, imageURL: event.source.imageURL, color: event.source.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.notification?.title ?? event.source.name).font(.headline)
                            Text(event.notification?.body ?? "No notification sent")
                            Text("\(event.status) · \(event.test ? "Test · " : "")\(event.createdAt)").font(.caption).foregroundStyle(.secondary)
                            if !event.source.tags.isEmpty { Text(event.source.tags.joined(separator: " · ")).font(.caption) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Recent notifications")
        .task { await load() }
        .refreshable { await load() }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { events = try await store.history(id) } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
