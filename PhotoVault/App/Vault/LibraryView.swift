import PhotosUI
import SwiftUI
import VaultCore

/// The unlocked vault: a Library tab and an Albums tab, like Photos.
/// Owns the photo picker and the vault-wide alerts.
struct LibraryView: View {
    private enum LibraryTab: Hashable {
        case library, albums
    }

    let library: LibraryModel
    @State private var tab = LibraryTab.library
    @State private var showingPicker = false
    @State private var importTarget: UUID?
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showingSettings = false

    var body: some View {
        @Bindable var library = library
        TabView(selection: $tab) {
            NavigationStack {
                ItemGridScreen(library: library, scope: .library, onImport: { beginImport(into: $0) }) {
                    showingSettings = true
                }
            }
            .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
            .tag(LibraryTab.library)

            NavigationStack {
                AlbumsView(library: library, onImport: { beginImport(into: $0) }) {
                    showingSettings = true
                }
            }
            .tabItem { Label("Albums", systemImage: "rectangle.stack") }
            .tag(LibraryTab.albums)
        }
        // The system photo picker runs outside the app: PhotoVault gets only
        // the items you select and needs no access to your library to do this.
        .photosPicker(
            isPresented: $showingPicker,
            selection: $pickerSelection,
            maxSelectionCount: nil,
            selectionBehavior: .ordered,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        )
        .onChange(of: pickerSelection) { _, picked in
            guard !picked.isEmpty else { return }
            library.startImport(picked, intoAlbum: importTarget)
            pickerSelection = []
        }
        .confirmationDialog(
            deletePrompt,
            isPresented: $library.isOfferingOriginalDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete from Photos", role: .destructive) {
                Task { await library.deleteOriginalsFromPhotos() }
            }
            Button("Keep in Photos", role: .cancel) { library.keepOriginals() }
        } message: {
            Text("The vault has its own encrypted copies. Deleted originals stay in Photos' Recently Deleted album for 30 days. PhotoVault will ask for full access to your library, which it uses only to delete them.")
        }
        .alert(library.cleanupMessage ?? "", isPresented: presence(of: $library.cleanupMessage)) {
            Button("OK", role: .cancel) {}
        }
        .alert(library.importSummary ?? "", isPresented: presence(of: $library.importSummary)) {
            Button("OK", role: .cancel) {}
        }
        .alert(library.exportSummary ?? "", isPresented: presence(of: $library.exportSummary)) {
            Button("OK", role: .cancel) {}
        }
        .alert(library.operationError ?? "", isPresented: presence(of: $library.operationError)) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    private func beginImport(into album: UUID?) {
        importTarget = album
        showingPicker = true
    }

    private var deletePrompt: String {
        let count = library.originalsToDelete.count
        return count == 1 ? "Delete the original from Photos?" : "Delete the \(count) originals from Photos?"
    }
}
