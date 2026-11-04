import AzurePimCore
import SwiftUI

enum Countdown {
    static func short(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 300 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }

    static func long(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60
        if total < 300 { return String(format: "%d:%02d left", total / 60, total % 60) }
        return hours > 0 ? "\(hours) h \(String(format: "%02d", minutes)) left" : "\(minutes) min left"
    }

    static func spoken(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "unknown" }
        let minutes = max(0, Int(seconds) / 60)
        return minutes >= 60 ? "\(minutes / 60) hours \(minutes % 60) minutes" : "\(minutes) minutes"
    }

    static func color(_ seconds: TimeInterval?) -> Color {
        guard let seconds else { return .primary }
        if seconds <= 300 { return .red }
        if seconds <= 900 { return .orange }
        return .primary
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

enum SourceIcon {
    static func name(_ source: RoleSource) -> String {
        switch source {
        case .azureResource: "cloud"
        case .entraRole: "person.badge.key"
        case .pimGroup: "person.3"
        }
    }
}

struct EligibleRow: View {
    @Environment(RoleStore.self) private var store
    let role: EligibleRole
    let isActive: Bool
    let isPending: Bool
    let activate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: SourceIcon.name(role.source)).frame(width: 18).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.roleName).lineLimit(1)
                    Text(role.scopeName + (role.memberType == .group ? " · via group" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if store.busy.contains(role.id) {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Text("Active").font(.caption).foregroundStyle(.green)
                } else if isPending {
                    Label("Pending", systemImage: "clock").font(.caption).foregroundStyle(.orange)
                        .help("Waiting for approval — see History")
                } else {
                    Button("Activate", action: activate).controlSize(.small)
                }
            }
            .frame(minHeight: 32)
            if let error = store.rowErrors[role.id] {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ActiveRow: View {
    @Environment(RoleStore.self) private var store
    let assignment: ActiveAssignment
    @State private var confirming = false

    /// Azure refuses deactivation within 5 minutes of activation (BackendSchema › business rules).
    private var tooRecent: Bool { Date.now.timeIntervalSince(assignment.startAt) < 300 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: SourceIcon.name(assignment.source)).frame(width: 18).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(assignment.roleName).lineLimit(1)
                    Text(assignment.scopeName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let end = assignment.endAt {
                    let remaining = end.timeIntervalSince(store.now)
                    Text(Countdown.long(remaining))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(remaining <= 900 ? Countdown.color(remaining) : .secondary)
                }
                if store.busy.contains(assignment.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        confirming = true
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(tooRecent)
                    .help(tooRecent ? "Can't deactivate within 5 minutes of activation" : "Deactivate")
                    .popover(isPresented: $confirming) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Deactivate \(assignment.roleName)?").font(.headline)
                            Text(assignment.scopeName).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Spacer()
                                Button("Cancel") { confirming = false }
                                Button("Deactivate", role: .destructive) {
                                    confirming = false
                                    Task { await store.deactivate(assignment) }
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(14)
                        .frame(width: 260)
                    }
                }
            }
            .frame(minHeight: 32)
            if let error = store.rowErrors[assignment.id] {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}

/// A permanent (non-PIM) role assignment: read-only, no countdown, no action.
struct PermanentRow: View {
    let assignment: ActiveAssignment
    let showAccount: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: SourceIcon.name(assignment.source)).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(assignment.roleName).lineLimit(1)
                Text(showAccount ? "\(assignment.scopeName) · \(assignment.account?.upn ?? "")" : assignment.scopeName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "lock").imageScale(.small).foregroundStyle(.tertiary)
                .help("Permanent assignment, managed by your administrator")
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(assignment.roleName), \(assignment.scopeName), permanent")
    }
}
