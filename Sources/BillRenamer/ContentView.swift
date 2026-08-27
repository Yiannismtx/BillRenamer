import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logList
            Divider()
            summaryBar
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet()
                .environmentObject(model)
        }
        .onAppear {
            if !model.hasAPIKey {
                model.showSettings = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Choose Folder…") {
                model.chooseFolder()
            }
            .disabled(model.isRunning)

            Button("Scan & Rename") {
                model.scanAndRename()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.folderURL == nil || model.isRunning)

            if model.isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            if let folder = model.folderURL {
                Text(folder.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(12)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(model.log) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: entry.status.symbol)
                        .foregroundStyle(entry.status.color)
                    Text(entry.message)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .id(entry.id)
            }
            .listStyle(.plain)
            .overlay {
                if model.log.isEmpty {
                    Text("Choose a folder of billing PDFs, then click Scan & Rename.\nEach unrecognized PDF is sent to Google's Gemini API for identification.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .onChange(of: model.log.count) { _ in
                if let last = model.log.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var summaryBar: some View {
        Text("Renamed: \(model.renamedCount) · Already done: \(model.alreadyDoneCount) · Not recognized: \(model.notRecognizedCount) · Errors: \(model.errorCount)")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}
