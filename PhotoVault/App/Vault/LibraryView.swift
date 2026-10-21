import PhotosUI
import SwiftUI
import VaultCore

/// The vault's library: every item in a grid, oldest at the top and newest at
/// the bottom, like Photos. Tap an item to open the full-screen viewer.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let library: LibraryModel
    @State private var showingPicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showingSettings = false
    @State private var viewerStart: VaultItem?

    var body: some View {
        @Bindable var library = library
        NavigationStack {
            Group {
                if library.items.isEmpty && library.importProgress == nil {
                    emptyState
                } else {
                    LibraryGridView(items: library.items, library: library) { item in
                        viewerStart = item
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Lock", systemImage: "lock") { model.lock() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Add", systemImage: "plus") { showingPicker = true }
                        .disabled(library.importProgress != nil)
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
                if !library.items.isEmpty {
                    ToolbarItem(placement: .status) {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let progress = library.importProgress {
                    ImportProgressBar(progress: progress) { library.cancelImport() }
                }
            }
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
            library.startImport(picked)
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
        .alert(library.cleanupMessage ?? "", isPresented: isPresenting($library.cleanupMessage)) {
            Button("OK", role: .cancel) {}
        }
        .alert(library.importSummary ?? "", isPresented: isPresenting($library.importSummary)) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .fullScreenCover(item: $viewerStart) { start in
            MediaViewer(library: library, items: library.items, startID: start.id)
        }
    }

    private var summary: String {
        let photos = library.photoCount == 1 ? "1 Photo" : "\(library.photoCount) Photos"
        let videos = library.videoCount == 1 ? "1 Video" : "\(library.videoCount) Videos"
        return "\(photos), \(videos)"
    }

    private var deletePrompt: String {
        let count = library.originalsToDelete.count
        return count == 1 ? "Delete the original from Photos?" : "Delete the \(count) originals from Photos?"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your Vault Is Empty", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Add photos and videos from your library. They're encrypted and stay on this iPhone.")
        } actions: {
            Button("Add Photos & Videos") { showingPicker = true }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Presents an alert while an optional message is set, and clears it on dismiss.
    private func isPresenting(_ message: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )
    }
}

private struct ImportProgressBar: View {
    let progress: ImportProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
            Text("Adding \(progress.completed) of \(progress.total)")
                .font(.footnote.monospacedDigit())
                .fixedSize()
            Button("Cancel", action: onCancel)
                .font(.footnote)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
