import SwiftUI

/// Placeholder until step 3 adds importing and the library grid.
struct VaultHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Your Vault Is Empty",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Importing photos and videos comes in the next step.")
            )
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Lock", systemImage: "lock") {
                        model.lock()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        showingSettings = true
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }
}
