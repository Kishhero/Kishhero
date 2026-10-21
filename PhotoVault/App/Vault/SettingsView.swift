import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.shuffleKeypad) private var shuffleKeypad = false
    @State private var changingPasscode = false
    @State private var confirmingErase = false
    @State private var eraseFailed = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Button("Change Passcode") { changingPasscode = true }
                    Toggle("Shuffle Keypad", isOn: $shuffleKeypad)
                } header: {
                    Text("Passcode")
                } footer: {
                    Text("Shuffling moves the digits around every time, so nobody can learn your passcode from where your finger goes.")
                }

                Section {
                    Toggle("Erase After 10 Failed Attempts", isOn: $model.eraseAfterFailures)
                } footer: {
                    Text("After 10 wrong passcodes in a row, the vault's key is destroyed and everything in it is gone for good. Anyone holding your phone could trigger this.")
                }

                Section {
                    Button("Erase Vault…", role: .destructive) { confirmingErase = true }
                } footer: {
                    Text("Destroys every photo and video in the vault. This cannot be undone.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.refreshStatus() }
            .onChange(of: model.eraseAfterFailures) { _, enabled in
                Task { await model.saveEraseAfterFailures(enabled) }
            }
            .confirmationDialog("Erase the vault?", isPresented: $confirmingErase, titleVisibility: .visible) {
                Button("Erase Everything", role: .destructive) {
                    Task {
                        eraseFailed = !(await model.erase())
                    }
                }
            } message: {
                Text("Every photo and video in the vault is destroyed. Nobody can recover them.")
            }
            .alert("The vault couldn't be erased.", isPresented: $eraseFailed) {
                Button("OK", role: .cancel) {}
            }
            .fullScreenCover(isPresented: $changingPasscode) {
                ChangePasscodeView()
            }
        }
    }
}
