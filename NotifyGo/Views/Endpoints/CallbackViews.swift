import SwiftUI
import UIKit

struct CallbackHomeView: View {
    @EnvironmentObject private var store: CallbackStore
    @State private var creating = false
    @State private var customizing = false
    @State private var copiedPushURL = false
    @State private var showingCurlExample = false
    @State private var sendingTestNotification = false
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    QuickPushCard(
                        pushURL: store.pushURL,
                        loading: store.isLoading,
                        deviceRegistered: store.deviceRegistered,
                        sendingTest: sendingTestNotification,
                        copied: copiedPushURL,
                        copyURL: copyPushURL,
                        showCurl: { showingCurlExample = true },
                        sendTest: sendTestNotification,
                        customize: { customizing = true },
                        retry: { Task { await store.refresh() } }
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Callbacks")
                                .font(.title2.bold())
                            Spacer()
                            Button { creating = true } label: {
                                Label("New", systemImage: "plus")
                            }
                            .disabled(!store.connected)
                        }

                    if !store.connected && !store.isLoading {
                        ContentUnavailableView("Service unavailable", systemImage: "wifi.exclamationmark", description: Text("Try connecting again. If this continues, contact the app publisher."))
                        Button("Retry") { Task { await store.refresh() } }
                    } else if store.callbacks.isEmpty {
                        ContentUnavailableView("No Callbacks yet", systemImage: "bell.badge", description: Text("Turn a JSON payload or App Store event into a notification."))
                        Button("Create Callback") { creating = true }
                    } else {
                        ForEach(store.callbacks) { callback in
                            NavigationLink(value: callback.id) {
                                CallbackHomeRow(callback: callback)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("NotifyGo")
            .refreshable { await store.refresh() }
            .navigationDestination(for: String.self) { CallbackDetailView(id: $0) }
            .sheet(isPresented: $creating) { CallbackEditorView(callback: HostedCallback()) }
            .sheet(isPresented: $customizing) { DirectPushView() }
            .sheet(isPresented: $showingCurlExample) {
                if let pushURL = store.pushURL {
                    CurlExampleSheet(example: curlExample(for: pushURL))
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    CopyToast(message: toastMessage)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert("NotifyGo", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
        }
    }

    private func copyPushURL() {
        guard let pushURL = store.pushURL else { return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: pushURL]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        copiedPushURL = true
        showToast("Copied to clipboard")
    }

    private func curlExample(for pushURL: String) -> String {
        """
        curl --request POST '\(pushURL)' \\
          --header 'Content-Type: application/json' \\
          --data '{
            "title": "Hello from NotifyGo",
            "subtitle": "Production",
            "body": "Your notification message.",
            "url": "https://example.com",
            "icon": "https://example.com/icon.png",
            "group": "server-monitoring",
            "sound": "default",
            "level": "active"
          }'
        """
    }

    private func sendTestNotification() {
        sendingTestNotification = true
        Task { @MainActor in
            defer { sendingTestNotification = false }
            do {
                try await store.sendDirect(title: "NotifyGo Test", subtitle: "", body: "Your device notification is working.", url: "", icon: "", group: "", sound: "default", level: "active")
                showToast("Test notification sent")
            } catch {
                store.report(error)
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) { toastMessage = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeIn(duration: 0.2)) {
                toastMessage = nil
                copiedPushURL = false
            }
        }
    }
}

private struct CallbackHomeRow: View {
    let callback: HostedCallback

    private var detail: String {
        guard callback.enabled else { return "Paused" }
        return callback.parser == "apple" ? "App Store transactions" : "Generic JSON"
    }

    var body: some View {
        HStack {
            SourceIcon(symbol: callback.symbol, emoji: callback.emoji, imageURL: callback.imageURL, color: callback.color)
            VStack(alignment: .leading) {
                Text(callback.name)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    }
}

private struct QuickPushCard: View {
    let pushURL: String?
    let loading: Bool
    let deviceRegistered: Bool
    let sendingTest: Bool
    let copied: Bool
    let copyURL: () -> Void
    let showCurl: () -> Void
    let sendTest: () -> Void
    let customize: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Push")
                        .font(.title2.bold())
                    Text("Send directly to this device")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }

            if let pushURL {
                Button(action: copyURL) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(copied ? "Copied" : "Device Push URL", systemImage: copied ? "checkmark" : "link")
                            .font(.caption.weight(.semibold))
                        Text(pushURL)
                            .font(.caption.monospaced())
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.success, trigger: copied)
                .accessibilityLabel(copied ? "Push URL copied" : "Copy Push URL")
                .accessibilityHint("Copies this device's private Push URL")

                HStack(spacing: 10) {
                    cardAction("cURL", systemImage: "chevron.left.forwardslash.chevron.right", action: showCurl)
                    cardAction(sendingTest ? "Sending…" : "Test", systemImage: "paperplane", disabled: sendingTest || !deviceRegistered, action: sendTest)
                    cardAction("Customize", systemImage: "slider.horizontal.3", action: customize)
                }
            } else if loading {
                ProgressView("Preparing Quick Push…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else {
                Text("Connect to create this device's private Push URL.")
                    .foregroundStyle(.white.opacity(0.82))
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.2))
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.10, blue: 0.72), Color(red: 0.37, green: 0.18, blue: 0.94)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color(red: 1.0, green: 0.34, blue: 0.15).opacity(0.9))
                    .frame(width: 150, height: 150)
                    .blur(radius: 18)
                    .offset(x: 50, y: -70)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.indigo.opacity(0.25), radius: 18, y: 8)
    }

    private func cardAction(_ title: String, systemImage: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(.white.opacity(disabled ? 0.45 : 1))
            .background(.black.opacity(disabled ? 0.08 : 0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct NotificationHistoryView: View {
    @EnvironmentObject private var store: CallbackStore
    @State private var events: [CallbackEvent] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ProgressView("Loading…")
                } else if let error {
                    ContentUnavailableView("History unavailable", systemImage: "exclamationmark.arrow.triangle.2.circlepath", description: Text(error))
                    Button("Retry") { Task { await load() } }
                } else if events.isEmpty {
                    ContentUnavailableView("No notifications yet", systemImage: "tray", description: Text("Notifications sent by your Callbacks will appear here."))
                } else {
                    ForEach(events) { event in
                        NotificationHistoryRow(event: event)
                    }
                }
            }
            .navigationTitle("History")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            events = try await store.history()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NotificationHistoryRow: View {
    let event: CallbackEvent

    var body: some View {
        DisclosureGroup {
            Text(event.fields.pretty)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                SourceIcon(symbol: event.source.symbol, emoji: event.source.emoji, imageURL: event.source.imageURL, color: event.source.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.notification?.title ?? event.source.name).font(.headline)
                    Text(event.notification?.body ?? "No notification sent").lineLimit(2)
                    Text("\(event.source.name) · \(event.status) · \(event.test ? "Test · " : "")\(event.createdAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: CallbackStore
    @Environment(\.openURL) private var openURL
    @State private var confirmsDeviceKeyReset = false
    @State private var copiedDeviceToken = false
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Notifications") {
                    LabeledContent("Status", value: store.deviceRegistered ? "Enabled" : "Not enabled")
                    if !store.deviceRegistered {
                        Button("Enable notifications") { Task { await store.enableNotifications() } }
                            .disabled(!store.connected)
                        Button("Open notification settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }

                Section {
                    if let deviceToken = store.deviceToken {
                        Button {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: deviceToken]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                            copiedDeviceToken = true
                            showCopyToast()
                        } label: {
                            Text(deviceToken)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .sensoryFeedback(.success, trigger: copiedDeviceToken)
                        .accessibilityLabel(copiedDeviceToken ? "Device Token copied" : "Copy Device Token")
                        .accessibilityHint("Copies the APNs Device Token to the clipboard")
                    } else {
                        Text("The Device Token will appear after notification registration completes.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Device Token")
                } footer: {
                    Text("This APNs token identifies this app installation. Treat it as diagnostic information and avoid sharing it publicly.")
                }

                Section {
                    if store.pushURL != nil {
                        Button("Reset Device Key", role: .destructive) { confirmsDeviceKeyReset = true }
                    } else {
                        Text("A device key will appear after this device connects.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Device Security")
                } footer: {
                    VStack(spacing: 16) {
                        Text("Resetting the device key invalidates the current Quick Push URL immediately. Callback URLs are not affected.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 4) {
                            Image(systemName: "app.badge.fill")
                                .imageScale(.small)
                            Text("NotifyGo \(appDisplayVersion)")
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.82), in: Capsule())
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .confirmationDialog("Reset Device Key?", isPresented: $confirmsDeviceKeyReset, titleVisibility: .visible) {
                Button("Reset Key", role: .destructive) {
                    Task {
                        do {
                            try await store.rotateDeviceKey()
                        } catch {
                            store.report(error)
                        }
                    }
                }
            } message: {
                Text("The current Push URL will stop working immediately. Callback URLs are not affected.")
            }
            .alert("NotifyGo", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK", role: .cancel) { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
    }

    private var appDisplayVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func showCopyToast() {
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = "Copied to clipboard"
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeIn(duration: 0.2)) {
                toastMessage = nil
                copiedDeviceToken = false
            }
        }
    }
}

private struct CopyToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.82), in: Capsule())
            .accessibilityAddTraits(.isStaticText)
    }
}

private struct CurlExampleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let example: String
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Button {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: example]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                    copied = true
                } label: {
                    Text(example)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.success, trigger: copied)
                .accessibilityLabel(copied ? "cURL example copied" : "Copy cURL example")
                .accessibilityHint("Copies this request to the clipboard")
            }
            .contentMargins(16, for: .scrollContent)
            .navigationTitle("cURL Example")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if copied {
                    Text("Copied to clipboard")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.82), in: Capsule())
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: copied) { _, value in
                guard value else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.easeIn(duration: 0.2)) {
                        copied = false
                    }
                }
            }
        }
    }
}

struct DirectPushView: View {
    @EnvironmentObject private var store: CallbackStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Hello from NotifyGo"
    @State private var subtitle = ""
    @State private var notificationBody = "Your direct Push URL is ready."
    @State private var destinationURL = ""
    @State private var iconURL = ""
    @State private var group = ""
    @State private var sound = "default"
    @State private var level = "active"
    @State private var sending = false
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Notification") {
                    TextField("Title", text: $title)
                    TextField("Subtitle (optional)", text: $subtitle)
                    TextField("Body", text: $notificationBody, axis: .vertical).lineLimit(3...8)
                    TextField("Open URL (optional)", text: $destinationURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Icon HTTPS URL (optional)", text: $iconURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Group (optional)", text: $group)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Delivery") {
                    Picker("Sound", selection: $sound) { Text("Default").tag("default"); Text("None").tag("none") }
                    Picker("Interruption", selection: $level) {
                        Text("Active").tag("active"); Text("Time Sensitive").tag("time-sensitive"); Text("Passive").tag("passive")
                    }
                }
                if sent { Label("Notification sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(sending)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Sending…" : "Send") {
                        sending = true; sent = false
                        Task { @MainActor in
                            defer { sending = false }
                            do {
                                try await store.sendDirect(
                                    title: title,
                                    subtitle: subtitle,
                                    body: notificationBody,
                                    url: destinationURL,
                                    icon: iconURL,
                                    group: group,
                                    sound: sound,
                                    level: level
                                )
                                sent = true
                            }
                            catch { store.report(error) }
                        }
                    }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
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
                    Section {
                        if let url = callback.callbackURL {
                            Text(url).font(.footnote.monospaced()).textSelection(.enabled)
                            Button(copied ? "Copied" : "Copy URL") {
                                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: url]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                                copied = true
                            }
                        } else { Text("Reset the key to obtain a new URL.") }
                        Button("Reset key", role: .destructive) { confirmRotate = true }
                    } header: {
                        Text("Callback URL")
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
                    TextField("Subtitle (optional)", text: optionalText($rule.template.subtitle))
                    TextField("Body", text: $rule.template.body, axis: .vertical).lineLimit(2...6)
                    TextField("Open URL (optional)", text: $rule.template.url).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Icon HTTPS URL (optional)", text: optionalText($rule.template.icon)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Group (optional)", text: optionalText($rule.template.group)).textInputAutocapitalization(.never).autocorrectionDisabled()
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

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 })
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
