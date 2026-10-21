import PhotosUI
import SwiftUI
import VaultCore

/// The vault's library: every item in a grid, oldest at the top and newest at
/// the bottom, like Photos. Step 4 adds the full-screen viewer and player.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let library: LibraryModel
    @State private var showingPicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showingSettings = false

    var body: some View {
        @Bindable var library = library
        NavigationStack {
            Group {
                if library.items.isEmpty && library.importProgress == nil {
                    emptyState
                } else {
                    LibraryGrid(library: library)
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

private struct LibraryGrid: View {
    let library: LibraryModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(library.items) { item in
                    ThumbnailCell(item: item, library: library)
                }
            }
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 16)
        }
        .defaultScrollAnchor(.bottom)
    }

    private var summary: String {
        let photos = library.photoCount == 1 ? "1 Photo" : "\(library.photoCount) Photos"
        let videos = library.videoCount == 1 ? "1 Video" : "\(library.videoCount) Videos"
        return "\(photos), \(videos)"
    }
}

private struct ThumbnailCell: View {
    let item: VaultItem
    let library: LibraryModel
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .video, let duration = item.duration {
                    Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .task(id: item.id) {
                image = await library.thumbnail(for: item)
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isImage)
    }

    private var accessibilityText: String {
        let date = item.sortDate.formatted(date: .abbreviated, time: .omitted)
        return item.kind == .video ? "Video, \(date)" : "Photo, \(date)"
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
