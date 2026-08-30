import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var confirmingUnlink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Gemini API Key")
                    .font(.callout)

                if model.hasAPIKey {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("A key is linked (stored in your Keychain).")
                        Spacer()
                        Button("Unlink…", role: .destructive) {
                            confirmingUnlink = true
                        }
                        .disabled(model.isRunning)
                    }
                    .frame(width: 380, alignment: .leading)
                    Text("To use a different key, unlink this one first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    keyInstructions
                    SecureField("Paste your Gemini API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 380)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.callout)
                TextField("Model ID", text: model.$modelID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 380)
                Text("Change this if Google renames or retires the model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if !model.hasAPIKey {
                    Button("Save") {
                        save()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Button("Test Key") {
                    testKey()
                }
                .disabled(isTesting || !model.hasAPIKey)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(statusIsError ? .red : .green)
                    .textSelection(.enabled)
            }

            Text("Note: every scanned PDF is uploaded to Google's Gemini API for analysis.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates…") {
                    Updater.shared.checkForUpdates()
                }
                .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 440)
        .confirmationDialog(
            "Unlink the saved API key?",
            isPresented: $confirmingUnlink
        ) {
            Button("Unlink Key", role: .destructive) {
                unlink()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The key is removed from your Keychain. You'll need to paste a key again before the next scan.")
        }
    }

    private var keyInstructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BillRenamer needs a free Google Gemini API key to read your documents. Getting one takes about two minutes:")
                .font(.callout)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Open Google AI Studio (button below) and sign in with any Google account.")
                Text("2. Click \"Create API key\" and, if asked, let it create a new project.")
                Text("3. Copy the key (it starts with \"AIza…\") and paste it below, then click Save.")
                Text("4. Click Test Key to confirm it works.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Open Google AI Studio…") {
                NSWorkspace.shared.open(URL(string: "https://aistudio.google.com/apikey")!)
            }
            Text("The free tier is enough for normal use. If Test Key reports error 403, the key's Google project doesn't have the Gemini API enabled yet — the error message includes the link to enable it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 380, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        if Keychain.saveAPIKey(key) {
            model.hasAPIKey = true
            apiKey = ""
            statusMessage = "Key saved to Keychain."
            statusIsError = false
        } else {
            statusMessage = "Could not save key to Keychain."
            statusIsError = true
        }
    }

    private func unlink() {
        if Keychain.deleteAPIKey() {
            model.hasAPIKey = false
            statusMessage = "Key unlinked."
            statusIsError = false
        } else {
            statusMessage = "Could not remove the key from Keychain."
            statusIsError = true
        }
    }

    private func testKey() {
        guard let key = Keychain.loadAPIKey() else {
            statusMessage = "No key linked."
            statusIsError = true
            return
        }
        isTesting = true
        statusMessage = ""
        let client = GeminiClient(apiKey: key, model: model.modelID)
        Task {
            do {
                try await client.testKey()
                statusMessage = "Key works."
                statusIsError = false
            } catch {
                statusMessage = "Key test failed: \(error.localizedDescription)"
                statusIsError = true
            }
            isTesting = false
        }
    }
}
