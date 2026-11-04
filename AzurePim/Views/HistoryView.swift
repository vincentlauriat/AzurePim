import AzurePimCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// History Window (AppFlow, T4.3 + T4.5): local records, requests pending approval, median time-to-activation, CSV export.
struct HistoryView: View {
    @Environment(RoleStore.self) private var store
    @Query(sort: \ActivationRecord.sentAt, order: .reverse) private var records: [ActivationRecord]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @State private var exporting = false
    @State private var csv = CSVDocument(text: "")
    @State private var cancelErrors: [String: String] = [:]
    @State private var canceling: Set<String> = []

    /// Pending requests not sent by AzurePim (portal, other tools): shown on top of local records.
    private var externalPending: [(Account, RemoteRequest)] {
        let local = Set(records.compactMap { $0.remoteRequestId?.lowercased() })
        return accounts.flatMap { account in
            (store.pending[account.id] ?? []).filter { !local.contains($0.id.lowercased()) }.map { (account, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary.padding(16)
            Divider()
            if records.isEmpty && externalPending.isEmpty {
                ContentUnavailableView("No request yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Activations and deactivations sent by AzurePim appear here."))
            } else {
                List {
                    ForEach(accounts.filter { store.pendingErrors[$0.id] != nil }) { account in
                        Label("Couldn't fetch pending requests: \(store.pendingErrors[account.id] ?? "")",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                    }
                    if !externalPending.isEmpty {
                        Section("Pending approval (sent elsewhere)") {
                            ForEach(externalPending, id: \.1.id) { account, request in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(request.roleName) — \(request.scopeName)")
                                        Text(request.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    cancelButton(id: request.id, source: request.source, account: account)
                                }
                            }
                        }
                    }
                    Section("Requests") {
                        ForEach(records) { record in
                            HistoryRow(record: record) {
                                if record.status == .pendingApproval, let id = record.remoteRequestId, let account = record.account {
                                    cancelButton(id: id, source: record.source, account: account)
                                }
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            Button {
                csv = CSVDocument(text: HistoryCSV.make(records))
                exporting = true
            } label: {
                Label("Export CSV…", systemImage: "square.and.arrow.up")
            }
            .disabled(records.isEmpty)
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
        .fileExporter(isPresented: $exporting, document: csv,
                      contentType: .commaSeparatedText, defaultFilename: "AzurePim history") { _ in }
        .navigationTitle("History")
    }

    private var summary: some View {
        HStack(spacing: 24) {
            stat("Median time to activate", ActivationStats.medianTimeToActivation(records).map { String(format: "%.1f s", $0) } ?? "—",
                 help: "Panel opened → role provisioned, over activations made from the panel")
            stat("Activations", "\(records.filter { $0.action != .deactivate && $0.status == .provisioned }.count)")
            stat("Pending approval", "\(records.filter { $0.status == .pendingApproval }.count + externalPending.count)")
            Spacer()
        }
    }

    private func stat(_ title: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .help(help ?? title)
    }

    @ViewBuilder private func cancelButton(id: String, source: RoleSource, account: Account) -> some View {
        if canceling.contains(id) {
            ProgressView().controlSize(.small)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Button("Cancel request") {
                    canceling.insert(id)
                    Task {
                        cancelErrors[id] = await store.cancel(requestId: id, source: source, account: account)
                        canceling.remove(id)
                    }
                }
                .controlSize(.small)
                if let error = cancelErrors[id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}

private struct HistoryRow<Trailing: View>: View {
    let record: ActivationRecord
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.action.rawValue.capitalized) \(record.roleName) — \(record.scopeName)").lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let error = record.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer()
            Text(statusText).font(.caption).foregroundStyle(color)
            trailing
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [record.sentAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = record.requestedDuration, let seconds = ISODuration.seconds(duration) {
            parts.append(seconds >= 3600 ? "\(Int(seconds / 3600)) h" : "\(Int(seconds / 60)) min")
        }
        if let time = record.timeToActivation { parts.append(String(format: "%.1f s to activate", time)) }
        if let favorite = record.viaFavorite { parts.append("★ \(favorite)") }
        if let justification = record.justification, !justification.isEmpty { parts.append("“\(justification)”") }
        if let account = record.account?.upn { parts.append(account) }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        switch record.status {
        case .pendingApproval: "Pending approval"
        default: record.status.rawValue.capitalized
        }
    }

    private var icon: String {
        switch record.status {
        case .provisioned: "checkmark.circle.fill"
        case .pendingApproval, .sent: "clock"
        case .denied, .failed: "xmark.octagon.fill"
        case .canceled: "minus.circle"
        }
    }

    private var color: Color {
        switch record.status {
        case .provisioned: .green
        case .pendingApproval, .sent: .orange
        case .denied, .failed: .red
        case .canceled: .secondary
        }
    }
}

struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
