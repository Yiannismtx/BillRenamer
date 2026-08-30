import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showHelp = false

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
        .sheet(isPresented: $model.showWhatsNew) {
            WhatsNewSheet(version: AppModel.appVersion)
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
            .help("Pick the folder containing your billing PDFs. Only the top level is scanned, not subfolders.")

            Button("Scan & Rename") {
                model.scanAndRename()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.folderURL == nil || model.isRunning || model.pendingCount == 0)
            .help("Sends each pending PDF to the Gemini API, then renames it to \"YYYYMMDD_Issuer_TYPE_Number.pdf\" (e.g. \"20260830_Vodafone_INV_55484.pdf\"). Files marked already renamed or excluded are skipped.")

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
                showHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("How BillRenamer works")
            .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                helpPopover
            }

            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings: Gemini API key and model")
        }
        .padding(12)
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How BillRenamer works")
                .font(.headline)
            Text("""
            1. Choose a folder — its top-level PDFs are listed immediately. \
            Files whose name already matches \
            "YYYYMMDD_Issuer_TYPE_Number.pdf" (e.g. "20260830_Vodafone_INV_\
            55484.pdf") are marked gray and skipped. TYPE is one of: \
            INV invoices/bills · PKL packing list · CNT contracts · \
            PAY payments · CRE credit notes · TAX taxes · LET letters · \
            IMP import invoices. Files in the previous format are converted \
            locally for free; older formats are rescanned and upgraded.

            2. Hover over a pending file and click ➖ to exclude it from the \
            scan (➕ brings it back). Right-click a gray file and pick \
            "Scan Anyway" to re-analyze it despite its name.

            3. Scan & Rename uploads each pending PDF to Google's Gemini API, \
            which reads the bill and returns the issuer, issue date, and \
            document number. The file is then renamed in place — nothing is \
            copied, moved, or deleted.

            Unrecognized files and errors are left untouched; scanning again \
            retries them. Each scanned file costs one small API request \
            against your Gemini quota.
            """)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
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
                .help(isExcluded
                    ? "Include this file in the next scan"
                    : "Remove this file from the scan — it won't be sent to the API or renamed")
            }

            if item.status == .alreadyRenamed && hovering {
                Button {
                    model.scanAnyway(item)
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
                .help("Scan anyway — re-analyze this file even though its name already matches the renamed pattern (useful if it was named wrongly)")
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
            if item.status == .alreadyRenamed {
                Button("Scan Anyway") {
                    model.scanAnyway(item)
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
