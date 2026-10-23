import SwiftUI

/// Floats over the list while several items are picked: one action for all of them.
struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let items: [VaultItem]

    private var ids: [String] { items.map(\.id) }
    private var inTrash: Bool { items.allSatisfy(\.isDeleted) }
    /// Personal items of one account can move into that account's organizations together.
    private var shareable: Bool {
        guard items.allSatisfy({ $0.organizationId == nil }), Set(items.map(\.accountId)).count == 1,
              let session = model.session(for: items[0].accountId) else { return false }
        return !session.organizations.isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(items.count) selected").font(.system(size: 12, weight: .semibold)).padding(.leading, 6)
            Spacer(minLength: 4)
            if inTrash {
                button("arrow.uturn.backward", "Restore") { model.confirmBulk(.restore, ids, then: clear) }
                button("trash.slash", "Delete Forever", role: .destructive) { model.confirmBulk(.delete, ids, then: clear) }
            } else {
                Menu {
                    Button("No Folder") { model.confirmBulk(.move(folderId: nil), ids, then: clear) }
                    Divider()
                    ForEach(model.folders) { folder in
                        Button { model.confirmBulk(.move(folderId: folder.id), ids, then: clear) } label: {
                            Text(verbatim: folder.name.replacingOccurrences(of: "/", with: " › "))
                        }
                    }
                } label: {
                    icon("folder")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help(Text("Move to Folder"))
                .accessibilityLabel(Text("Move to Folder"))
                if shareable {
                    button("building.2", "Move to Shared Vault…") { model.organizationSheet = .share(ids) }
                }
                button("archivebox", "Archive") { model.confirmBulk(.archive, ids, then: clear) }
                button("trash", "Move to Trash…", role: .destructive) { model.confirmBulk(.trash, ids, then: clear) }
            }
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16)
            button("xmark", "Clear Selection") { clear() }
        }
        .padding(.horizontal, 6).frame(height: 42)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.panelEdge))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private func clear() { withAnimation(.snappy(duration: 0.2)) { model.multiSelection = [] } }

    private func icon(_ symbol: String, role: ButtonRole? = nil) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium))
            .foregroundStyle(role == .destructive ? Color.red : .primary)
            .frame(width: 32, height: 30).contentShape(.rect)
    }

    private func button(_ symbol: String, _ help: LocalizedStringKey, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(symbol, role: role) }
            .buttonStyle(HeaderIconStyle())
            .help(Text(help))
            .accessibilityLabel(Text(help))
    }
}

/// Collections of one organization as a checklist. Shared with the edit form, which shows it inline.
struct CollectionChecklist: View {
    let collections: [Grouping]
    @Binding var chosen: Set<String>

    var body: some View {
        VStack(spacing: 2) {
            ForEach(collections) { collection in
                let on = chosen.contains(collection.id)
                Button {
                    withAnimation(.snappy(duration: 0.15)) { if on { chosen.remove(collection.id) } else { chosen.insert(collection.id) } }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .font(.system(size: 15)).foregroundStyle(on ? Color.primary : .secondary)
                        Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                        Text(verbatim: collection.name).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(on ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            if collections.isEmpty {
                Text("This shared vault has no shared folders you can add to.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Moves personal items into an organization: pick it and the collections they go in.
struct MoveToOrganizationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemIDs: [String]
    @State private var orgId: String?
    @State private var chosen: Set<String> = []
    @State private var saving = false

    private var items: [VaultItem] { model.items.filter { itemIDs.contains($0.id) } }
    private var organizations: [Grouping] {
        if let live = items.first.flatMap({ model.session(for: $0.accountId)?.organizations }) { return live }
        // Previews and `--demo` have no sessions: the model's own list is the vault's.
        let accountId = items.first?.accountId
        return model.organizations.filter { $0.accountId == nil || $0.accountId == accountId }
    }
    private var collections: [Grouping] { organizations.first { $0.id == orgId }?.children ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FormHeader(symbol: "building.2", title: "Move to Shared Vault",
                               subtitle: items.count == 1 ? "Share this item with the shared vault's members."
                                                          : "Share these items with the shared vault's members.")
                    FormCard {
                        if items.count == 1, let item = items.first {
                            HStack(spacing: 10) {
                                ItemIcon(item: item, size: 30)
                                Text(item.name).font(.system(size: 13, weight: .semibold))
                            }
                        } else {
                            Text("\(items.count) items").font(.system(size: 13, weight: .semibold))
                        }
                        FormField(label: "Shared vault") {
                            SoftMenu(options: organizations.map { (String?.some($0.id), $0.name) }, selection: $orgId,
                                     accessibilityLabel: "Shared vault")
                        }
                    }
                    FormCard(title: "Shared Folders") {
                        CollectionChecklist(collections: collections, chosen: $chosen)
                    }
                    Label("Moving is one way: the shared vault owns the items afterwards.", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                .padding(20)
            }
            .thinScroller()
            FormFooter(action: "Move", busy: saving, disabled: orgId == nil || chosen.isEmpty, cancel: { dismiss() }) {
                guard let orgId else { return }
                saving = true
                Task {
                    if await model.share(itemIDs, organizationId: orgId, collectionIds: Array(chosen)) {
                        model.multiSelection = []
                        dismiss()
                    }
                    saving = false
                }
            }
        }
        .frame(width: 480, height: 520)
        .background(Color.windowBase)
        .onAppear {
            let first = orgId ?? organizations.first?.id
            orgId = first
            chosen = presetChosen(for: first)
        }
        .onChange(of: orgId) { _, id in chosen = presetChosen(for: id) }
    }

    /// One folder to choose from: pick it, rather than asking for a click that decides nothing.
    private func presetChosen(for organizationId: String?) -> Set<String> {
        let folders = organizations.first { $0.id == organizationId }?.children ?? []
        return folders.soleWritableCollection.map { [$0] } ?? []
    }
}

/// Which collections an organization item is in.
struct CollectionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemID: String
    @State private var chosen: Set<String> = []
    @State private var saving = false

    private var item: VaultItem? { model.items.first { $0.id == itemID } }
    private var organization: Grouping? { model.organizations.first { $0.id == item?.organizationId } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FormHeader(symbol: "rectangle.stack", title: "Shared Folders",
                           subtitle: "Who in \(organization?.name ?? "") can see this item.")
                FormCard {
                    CollectionChecklist(collections: organization?.children ?? [], chosen: $chosen)
                }
            }
            .padding(20)
            FormFooter(action: "Save", busy: saving, disabled: chosen.isEmpty, cancel: { dismiss() }) {
                guard let item else { return }
                saving = true
                Task {
                    if await model.setCollections(item, collectionIds: Array(chosen)) { dismiss() }
                    saving = false
                }
            }
        }
        .frame(width: 440)
        .background(Color.windowBase)
        .onAppear { chosen = Set(item?.collectionIds ?? []) }
    }
}
