import SwiftUI
import VaultCore

/// The Albums tab: every album as a card, like Photos.
struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    let library: LibraryModel
    let onImport: (UUID?) -> Void
    let onShowSettings: () -> Void

    @State private var naming = false
    @State private var newName = ""
    @State private var renamingAlbum: Album?
    @State private var renameText = ""
    @State private var deletingAlbum: Album?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        Group {
            if library.albums.isEmpty {
                ContentUnavailableView {
                    Label("No Albums", systemImage: "rectangle.stack")
                } description: {
                    Text("Albums organize the vault without making copies. An item can be in several albums.")
                } actions: {
                    Button("New Album") { startNaming() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(library.albums) { album in
                            NavigationLink(value: album.id) {
                                AlbumCard(album: album, library: library)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") {
                                    renameText = album.name
                                    renamingAlbum = album
                                }
                                Button("Delete Album", systemImage: "trash", role: .destructive) {
                                    deletingAlbum = album
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: UUID.self) { id in
            ItemGridScreen(library: library, scope: .album(id), onImport: onImport)
        }
        .safeAreaInset(edge: .bottom) { ProgressBanner(library: library) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Lock", systemImage: "lock") { model.lock() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("New Album", systemImage: "plus") { startNaming() }
                Button("Settings", systemImage: "gearshape") { onShowSettings() }
            }
        }
        .alert("New Album", isPresented: $naming) {
            TextField("Name", text: $newName)
                .autocorrectionDisabled() // keeps album names out of the keyboard's learned words
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newName
                Task { await library.createAlbum(named: name) }
            }
        }
        .alert("Rename Album", isPresented: presence(of: $renamingAlbum), presenting: renamingAlbum) { album in
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = renameText
                Task { await library.renameAlbum(album.id, to: name) }
            }
        }
        .confirmationDialog(
            "Delete this album?",
            isPresented: presence(of: $deletingAlbum),
            titleVisibility: .visible,
            presenting: deletingAlbum
        ) { album in
            Button("Delete “\(album.name)”", role: .destructive) {
                Task { await library.deleteAlbum(album.id) }
            }
        } message: { _ in
            Text("The photos and videos in it stay in your library.")
        }
    }

    private func startNaming() {
        newName = ""
        naming = true
    }
}

struct AlbumCard: View {
    let album: Album
    let library: LibraryModel
    @State private var cover: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let cover {
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(album.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(album.itemIDs.count, format: .number)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: library.coverItem(for: album)?.id) {
            if let item = library.coverItem(for: album) {
                cover = await library.thumbnail(for: item)
            } else {
                cover = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(album.name), \(album.itemIDs.count) items")
        .accessibilityAddTraits(.isButton)
    }
}

/// Picks an album to add items to, or creates one.
struct AlbumPickerSheet: View {
    let library: LibraryModel
    let excluding: UUID?
    let onChoose: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newName = ""
                    naming = true
                } label: {
                    Label("New Album…", systemImage: "plus")
                }
                ForEach(library.albums.filter { $0.id != excluding }) { album in
                    Button {
                        onChoose(album.id)
                        dismiss()
                    } label: {
                        AlbumRow(album: album, library: library)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New Album", isPresented: $naming) {
                TextField("Name", text: $newName)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newName
                    Task {
                        if let album = await library.createAlbum(named: name) {
                            onChoose(album.id)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

private struct AlbumRow: View {
    let album: Album
    let library: LibraryModel
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 52, height: 52)
                .overlay {
                    if let cover {
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(album.name)
                Text(album.itemIDs.count, format: .number)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .task(id: library.coverItem(for: album)?.id) {
            if let item = library.coverItem(for: album) {
                cover = await library.thumbnail(for: item)
            }
        }
    }
}

/// Picks items already in the vault to add to an album.
struct VaultItemPickerSheet: View {
    let library: LibraryModel
    let albumID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []

    var body: some View {
        NavigationStack {
            LibraryGridView(
                items: library.items,
                library: library,
                isSelecting: true,
                selection: $selection
            ) { _ in }
            .navigationTitle(selection.isEmpty ? "Choose Items" : "\(selection.count) Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let ids = selection
                        dismiss()
                        Task { await library.add(ids, toAlbum: albumID) }
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .onAppear {
                // Start with what's already in the album unselected; adding
                // something twice is a no-op anyway.
                selection = []
            }
        }
    }
}
