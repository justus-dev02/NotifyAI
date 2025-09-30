import SwiftUI

struct QuickActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    init(title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    QuickActionButton(title: "Neue Aufnahme", icon: "mic.circle.fill", action: {})
}
