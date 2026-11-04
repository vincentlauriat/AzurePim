import AzurePimCore
import SwiftUI

/// Activation Sheet (AppFlow): duration presets capped by policy, justification / ticket validation, send.
/// Shown inside the menu bar panel so the panel stays open while the user types.
struct ActivationSheet: View {
    @Environment(RoleStore.self) private var store
    let role: EligibleRole
    /// False outside the menu bar panel (Roles Window): keeps the record out of the time-to-activation median.
    var fromPanel = true
    let close: () -> Void

    @State private var hours: Double = 8
    @State private var justification = ""
    @State private var ticket = ""
    @State private var result: RequestStatus?
    @FocusState private var focused: Bool

    private var maxHours: Double {
        (role.maxDuration.flatMap(ISODuration.seconds) ?? 8 * 3600) / 3600
    }
    private var presets: [Double] { [1, 2, 4, 8].filter { $0 < maxHours } + [maxHours] }
    private var duration: String { ISODuration.string(hours * 3600) }

    private var validationError: String? {
        if case .failure = Validation.duration(duration, policyMax: role.maxDuration) { return "Duration not allowed by policy." }
        if Validation.justification(justification, required: role.requiresJustification) != nil {
            return justification.count > 500 ? "Justification is limited to 500 characters." : "Justification required by policy."
        }
        if Validation.ticketNumber(ticket, required: role.requiresTicket) != nil { return "Ticket number required by policy." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activate \(role.roleName)").font(.headline)
                Text(role.scopeName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(policyHint).font(.caption).foregroundStyle(.secondary)
            }

            Picker("Duration", selection: $hours) {
                ForEach(presets, id: \.self) { value in
                    Text(value == maxHours ? "Max (\(label(value)))" : label(value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Justification", text: $justification, prompt: Text("Why do you need this role?"), axis: .vertical)
                .lineLimit(2...4)
                .focused($focused)

            if role.requiresTicket {
                TextField("Ticket number", text: $ticket)
            }

            if let error = store.rowErrors[role.id] {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if result == .pendingApproval {
                Label("Request sent — pending approval.", systemImage: "clock").font(.caption).foregroundStyle(.orange)
            } else if let validationError, !justification.isEmpty || role.requiresTicket {
                Text(validationError).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                if store.busy.contains(role.id) { ProgressView().controlSize(.small) }
                Button(result == .pendingApproval ? "Done" : "Activate") {
                    if result == .pendingApproval { close() } else { Task { await send() } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(result != .pendingApproval && (validationError != nil || store.busy.contains(role.id)))
            }
        }
        .padding(14)
        .task {
            justification = role.lastJustification ?? ""
            await store.ensurePolicy(for: role)
            hours = min(8, maxHours)
            focused = true
        }
    }

    private var policyHint: String {
        var parts = ["Max \(label(maxHours))"]
        if role.requiresTicket { parts.append("Ticket required") }
        if role.requiresMFA { parts.append("MFA required") }
        if role.requiresApproval { parts.append("Approval required") }
        return parts.joined(separator: " · ")
    }

    private func label(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value)) h" : "\(Int(value * 60)) min"
    }

    private func send() async {
        let input = ActivationInput(duration: duration, justification: justification.trimmingCharacters(in: .whitespacesAndNewlines),
                                    ticketNumber: role.requiresTicket ? ticket : nil)
        result = await store.activate(role, input: input, fromPanel: fromPanel)
        if result == .provisioned { close() }
    }
}
