import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fileList
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
            .disabled(model.folderURL == nil || model.isRunning || model.pendingCount == 0)

            if model.folderURL != nil {
                Button {
                    model.refreshFileList()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
                .help("Refresh file list")
            }

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

    private var fileList: some View {
        List(model.files) { item in
            FileRow(item: item)
                .environmentObject(model)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if model.folderURL == nil {
                Text("Choose a folder of billing PDFs to see its files here.\nEach unrecognized PDF is sent to Google's Gemini API for identification.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
            } else if model.files.isEmpty {
                Text("No PDF files in this folder.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private var summaryBar: some View {
        Text("To scan: \(model.pendingCount) · Renamed: \(model.renamedCount) · Already done: \(model.alreadyDoneCount) · Not recognized: \(model.notRecognizedCount) · Errors: \(model.errorCount)")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

private struct FileRow: View {
    @EnvironmentObject var model: AppModel
    let item: FileItem
    @State private var hovering = false

    private var isExcluded: Bool { item.status == .excluded }
    private var isToggleable: Bool {
        item.status == .pending || item.status == .excluded
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if item.status == .processing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16)
            } else {
                Image(systemName: item.status.symbol)
                    .foregroundStyle(item.status.color)
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(.body, design: .monospaced))
                    .strikethrough(isExcluded)
                    .foregroundStyle(isExcluded ? .secondary : .primary)
                    .textSelection(.enabled)
                if let detail = item.status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(item.status.color)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            if isToggleable && (hovering || isExcluded) {
                Button {
                    model.toggleExcluded(item)
                } label: {
                    Image(systemName: isExcluded ? "plus.circle" : "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
                .help(isExcluded ? "Include in scan" : "Remove from scan")
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
        .contextMenu {
            if isToggleable {
                Button(isExcluded ? "Include in Scan" : "Remove from Scan") {
                    model.toggleExcluded(item)
                }
                .disabled(model.isRunning)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("Open") {
                NSWorkspace.shared.open(item.url)
            }
        }
    }
}
