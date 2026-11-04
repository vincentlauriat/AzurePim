import AzurePimCore
import SwiftData
import SwiftUI

/// Favorites Window (AppFlow, T4.2): create, rename, reorder, delete; per-role duration and justification.
struct FavoritesView: View {
    @Environment(\.modelContext) private var context
    @Environment(RoleStore.self) private var store
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    @State private var selection: Favorite.ID?
    @State private var confirmingDelete: Favorite?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(favorites) { favorite in
                    HStack(spacing: 10) {
                        Image(systemName: "star.fill").foregroundStyle(Theme.violet)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(favorite.name).font(.system(size: 13, weight: .medium))
                            Text(favorite.items.count == 1 ? "1 role" : "\(favorite.items.count) roles")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(favorite.id)
                }
                .onMove(perform: move)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
            .onDeleteCommand { confirmingDelete = favorites.first { $0.id == selection } }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    Button(action: add) { Label("New favorite", systemImage: "plus").labelStyle(.iconOnly) }.help("New favorite")
                    Button {
                        confirmingDelete = favorites.first { $0.id == selection }
                    } label: {
                        Label("Delete favorite", systemImage: "minus").labelStyle(.iconOnly)
                    }
                    .disabled(selection == nil)
                    .help("Delete favorite")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }

            Group {
                if let favorite = favorites.first(where: { $0.id == selection }) {
                    FavoriteEditor(favorite: favorite, others: favorites.filter { $0.id != favorite.id }.map(\.name))
                        .id(favorite.id)
                } else {
                    ContentUnavailableView("No favorite selected", systemImage: "star",
                                           description: Text("A favorite activates several roles in one click."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Delete “\(confirmingDelete?.name ?? "")”?", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let favorite = confirmingDelete {
                    context.delete(favorite)
                    try? context.save()
                    selection = nil
                }
                confirmingDelete = nil
            }
        }
        .navigationTitle("Favorites")
    }

    private func add() {
        var name = "New favorite"
        var index = 2
        while case .failure = Validation.favoriteName(name, existing: favorites.map(\.name)) {
            name = "New favorite \(index)"
            index += 1
        }
        let favorite = Favorite(name: name, items: [], sortOrder: (favorites.map(\.sortOrder).max() ?? -1) + 1)
        context.insert(favorite)
        try? context.save()
        selection = favorite.id
    }

    private func move(from source: IndexSet, to destination: Int) {
        var list = favorites
        list.move(fromOffsets: source, toOffset: destination)
        for (index, favorite) in list.enumerated() { favorite.sortOrder = index }
        try? context.save()
    }
}

private struct FavoriteEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(RoleStore.self) private var store
    @Query(sort: \EligibleRole.roleName) private var roles: [EligibleRole]
    @Bindable var favorite: Favorite
    let others: [String]
    @State private var name = ""
    @State private var nameError: String?

    var body: some View {
        Form {
            Section {
                // Saved on Return or when the editor closes: the deep link should not change at every keystroke.
                TextField("Name", text: $name)
                    .onSubmit(rename)
                if let nameError { Text(nameError).font(.caption).foregroundStyle(.red) }
                let encoded = favorite.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                Text("Deep link: azurepim://activate?favorite=\(encoded)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Roles") {
                if favorite.items.isEmpty {
                    Text("Add at least one role.").foregroundStyle(.secondary)
                }
                ForEach(favorite.items, id: \.eligibleRoleId) { item in
                    itemRow(item: item)
                }
                Menu("Add role") {
                    ForEach(roles.filter { role in !favorite.items.contains { $0.eligibleRoleId == role.id } }) { role in
                        Button("\(role.roleName) — \(role.scopeName)") {
                            favorite.items.append(FavoriteItem(eligibleRoleId: role.id, duration: role.maxDuration ?? "PT8H"))
                            try? context.save()
                        }
                    }
                }
                .fixedSize()
            }
            Section {
                HStack {
                    Button("Run now") { Task { await store.run(favorite, fromPanel: false) } }
                        .disabled(favorite.items.isEmpty || store.runningFavorites.contains(favorite.id))
                    if store.runningFavorites.contains(favorite.id) { ProgressView().controlSize(.small) }
                    if let toast = store.favoriteToast, toast.favoriteId == favorite.id {
                        Text(toast.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = favorite.name }
        .onDisappear(perform: rename)
    }

    @ViewBuilder private func itemRow(item: FavoriteItem) -> some View {
        let role = roles.first { $0.id == item.eligibleRoleId }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(role?.roleName ?? "No longer eligible").foregroundStyle(role == nil ? .secondary : .primary)
                    Text(role?.scopeName ?? item.eligibleRoleId).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Picker("Duration", selection: durationBinding(item.eligibleRoleId)) {
                    ForEach(presets(role), id: \.self) { value in Text(label(value)).tag(value) }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    favorite.items.removeAll { $0.eligibleRoleId == item.eligibleRoleId }
                    try? context.save()
                } label: {
                    Label("Remove from favorite", systemImage: "minus.circle").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Remove from favorite")
            }
            TextField("Justification", text: justificationBinding(item.eligibleRoleId),
                      prompt: Text(role?.lastJustification ?? "Uses the last justification of this role"))
                .font(.callout)
            if role?.requiresTicket == true {
                Text("Needs a ticket number: activate it from the panel instead.").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func presets(_ role: EligibleRole?) -> [String] {
        let max = role?.maxDuration.flatMap(ISODuration.seconds) ?? 8 * 3600
        return ([1, 2, 4, 8].map { Double($0) * 3600 }.filter { $0 < max } + [max]).map(ISODuration.string)
    }

    private func label(_ iso: String) -> String {
        guard let seconds = ISODuration.seconds(iso) else { return iso }
        return seconds >= 3600 ? "\(Int(seconds / 3600)) h" : "\(Int(seconds / 60)) min"
    }

    /// Bindings resolve the item by role id at each access: an index could point to a neighbour after a removal.
    private func durationBinding(_ roleId: String) -> Binding<String> {
        Binding(get: { favorite.items.first { $0.eligibleRoleId == roleId }?.duration ?? "PT8H" },
                set: { value in
                    guard let index = favorite.items.firstIndex(where: { $0.eligibleRoleId == roleId }) else { return }
                    favorite.items[index].duration = value
                    try? context.save()
                })
    }

    private func justificationBinding(_ roleId: String) -> Binding<String> {
        Binding(get: { favorite.items.first { $0.eligibleRoleId == roleId }?.justification ?? "" },
                set: { value in
                    guard let index = favorite.items.firstIndex(where: { $0.eligibleRoleId == roleId }) else { return }
                    favorite.items[index].justification = value.isEmpty ? nil : String(value.prefix(500))
                    try? context.save()
                })
    }

    private func rename() {
        switch Validation.favoriteName(name, existing: others) {
        case .success(let valid):
            nameError = nil
            if valid != favorite.name {
                favorite.name = valid
                try? context.save()
            }
        case .failure(let failure):
            nameError = failure.userMessage + " — kept “\(favorite.name)”."
        }
    }
}
