import SwiftUI
import VaultCore

/// A grid of items, either the whole library or one album, with selection
/// and its actions: Save to Photos, Add to Album, Remove from Album, Delete.
struct ItemGridScreen: View {
    enum Scope: Hashable {
        case library
        case album(UUID)
    }

    @Environment(AppModel.self) private var model
    let library: LibraryModel
    let scope: Scope
    /// Opens the photo picker; the argument is the album to add imports to.
    let onImport: (UUID?) -> Void
    var onShowSettings: (() -> Void)?

    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var viewerStart: VaultItem?
    @State private var confirmingDelete = false
    @State private var confirmingSave = false
    @State private var choosingAlbum = false
    @State private var choosingFromVault = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingAlbumDeletion = false
    @Environment(\.dismiss) private var dismiss

    private var albumID: UUID? {
        if case .album(let id) = scope { return id }
        return nil
    }

    private var items: [VaultItem] {
        albumID.map { library.items(inAlbum: $0) } ?? library.items
    }

    private var title: String {
        guard let albumID else { return "Library" }
        return library.album(albumID)?.name ?? "Album"
    }

    var body: some View {
        content
            .navigationTitle(isSelecting ? selectionTitle : title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isSelecting)
            .toolbar { toolbarContent }
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if !isSelecting { ProgressBanner(library: library) }
            }
            .onChange(of: items.map(\.id)) { _, ids in
                // Drop selections whose items were deleted.
                selection.formIntersection(ids)
            }
            .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(selection.count == 1 ? "Delete Item" : "Delete \(selection.count) Items", role: .destructive) {
                    let ids = selection
                    finishSelecting()
                    Task { await library.delete(ids) }
                }
            } message: {
                Text("They're removed from the vault and from every album. This can't be undone.")
            }
            .confirmationDialog("Save to Photos?", isPresented: $confirmingSave, titleVisibility: .visible) {
                Button("Save") { save(removingLocation: false) }
                Button("Save Without Location") { save(removingLocation: true) }
            } message: {
                Text(SaveToPhotos.explanation)
            }
            .sheet(isPresented: $choosingAlbum) {
                AlbumPickerSheet(library: library, excluding: albumID) { album in
                    let ids = selection
                    finishSelecting()
                    Task { await library.add(ids, toAlbum: album) }
                }
            }
            .sheet(isPresented: $choosingFromVault) {
                if let albumID {
                    VaultItemPickerSheet(library: library, albumID: albumID)
                }
            }
            .alert("Rename Album", isPresented: $renaming) {
                TextField("Name", text: $newName)
                    .autocorrectionDisabled() // keeps album names out of the keyboard's learned words
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let albumID {
                        let name = newName
                        Task { await library.renameAlbum(albumID, to: name) }
                    }
                }
            }
            .confirmationDialog("Delete this album?", isPresented: $confirmingAlbumDeletion, titleVisibility: .visible) {
                Button("Delete Album", role: .destructive) {
                    if let albumID {
                        dismiss()
                        Task { await library.deleteAlbum(albumID) }
                    }
                }
            } message: {
                Text("The photos and videos in it stay in your library.")
            }
            .fullScreenCover(item: $viewerStart) { start in
                MediaViewer(library: library, items: items, startID: start.id, albumID: albumID)
            }
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty && library.importProgress == nil {
            emptyState
        } else {
            LibraryGridView(
                items: items,
                library: library,
                footer: footer,
                isSelecting: isSelecting,
                selection: $selection
            ) { item in
                viewerStart = item
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if albumID == nil {
            ContentUnavailableView {
                Label("Your Vault Is Empty", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Add photos and videos from your library. They're encrypted and stay on this iPhone.")
            } actions: {
                Button("Add Photos & Videos") { onImport(nil) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("This Album Is Empty", systemImage: "rectangle.stack")
            } description: {
                Text("Add items already in the vault, or import new ones from Photos.")
            } actions: {
                Button("Choose from Vault") { choosingFromVault = true }
                    .buttonStyle(.borderedProminent)
                Button("Import from Photos") { onImport(albumID) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let allSelected = !items.isEmpty && selection.count == items.count
                Button(allSelected ? "Deselect All" : "Select All") {
                    selection = allSelected ? [] : Set(items.map(\.id))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { finishSelecting() }
                    .fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Save to Photos", systemImage: "square.and.arrow.down") { confirmingSave = true }
                    .disabled(selection.isEmpty || library.exportProgress != nil)
                Spacer()
                Button("Add to Album", systemImage: "rectangle.stack.badge.plus") { choosingAlbum = true }
                    .disabled(selection.isEmpty)
                if let albumID {
                    Spacer()
                    Button("Remove from Album", systemImage: "rectangle.stack.badge.minus") {
                        let ids = selection
                        finishSelecting()
                        Task { await library.remove(ids, fromAlbum: albumID) }
                    }
                    .disabled(selection.isEmpty)
                }
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    .disabled(selection.isEmpty)
            }
        } else {
            if albumID == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Lock", systemImage: "lock") { model.lock() }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !items.isEmpty {
                    Button("Select") { isSelecting = true }
                }
                if let albumID {
                    Menu("Add", systemImage: "plus") {
                        Button("Choose from Vault", systemImage: "photo.on.rectangle") { choosingFromVault = true }
                        Button("Import from Photos", systemImage: "photo.badge.plus") { onImport(albumID) }
                    }
                    .disabled(library.importProgress != nil)
                    Menu("Album", systemImage: "ellipsis.circle") {
                        Button("Rename Album", systemImage: "pencil") {
                            newName = title
                            renaming = true
                        }
                        Button("Delete Album", systemImage: "trash", role: .destructive) { confirmingAlbumDeletion = true }
                    }
                } else {
                    Button("Add", systemImage: "plus") { onImport(nil) }
                        .disabled(library.importProgress != nil)
                }
                if let onShowSettings {
                    Button("Settings", systemImage: "gearshape") { onShowSettings() }
                }
            }
        }
    }

    private var selectionTitle: String {
        switch selection.count {
        case 0: return "Select Items"
        case 1: return "1 Item Selected"
        default: return "\(selection.count) Items Selected"
        }
    }

    private var deleteTitle: String {
        selection.count == 1 ? "Delete this item?" : "Delete \(selection.count) items?"
    }

    private var footer: String {
        let photos = items.lazy.filter { $0.kind == .photo }.count
        let videos = items.count - photos
        return "\(photos == 1 ? "1 Photo" : "\(photos) Photos"), \(videos == 1 ? "1 Video" : "\(videos) Videos")"
    }

    private func save(removingLocation: Bool) {
        let ids = selection
        finishSelecting()
        library.saveToPhotos(ids, removingLocation: removingLocation)
    }

    private func finishSelecting() {
        isSelecting = false
        selection = []
    }
}

enum SaveToPhotos {
    static let explanation = "Copies are added to your Photos library, outside the vault's encryption, and to iCloud if iCloud Photos is on. The vault keeps its own copies."
}

/// Import and export progress, shown above the bottom edge.
struct ProgressBanner: View {
    let library: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            if let progress = library.importProgress {
                row(
                    text: "Adding \(progress.completed) of \(progress.total)",
                    completed: progress.completed,
                    total: progress.total,
                    onCancel: { library.cancelImport() }
                )
            }
            if let progress = library.exportProgress {
                row(text: "Saving \(progress.completed) of \(progress.total) to Photos", completed: progress.completed, total: progress.total, onCancel: nil)
            }
        }
    }

    private func row(text: String, completed: Int, total: Int, onCancel: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
            Text(text)
                .font(.footnote.monospacedDigit())
                .fixedSize()
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .font(.footnote)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Presents an alert while an optional value is set, and clears it on dismiss.
func presence<Value>(of value: Binding<Value?>) -> Binding<Bool> {
    Binding(
        get: { value.wrappedValue != nil },
        set: { if !$0 { value.wrappedValue = nil } }
    )
}
