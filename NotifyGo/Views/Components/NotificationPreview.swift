import SwiftUI

struct NotificationPreview: View {
    let endpoint: NotificationEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: endpoint.symbolName)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(endpoint.accent.color.gradient, in: RoundedRectangle(cornerRadius: 7))
                Text("NOTIFYGO")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("now").font(.caption).foregroundStyle(.secondary)
            }
            Text(endpoint.defaultTitle.isEmpty ? "Notification title" : endpoint.defaultTitle)
                .font(.headline)
            Text(endpoint.defaultBody.isEmpty ? "Notification body" : endpoint.defaultBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notification preview. \(endpoint.defaultTitle). \(endpoint.defaultBody)")
    }
}
