import Foundation
import SwiftUI

enum FileStatus {
    case renamed
    case skippedAlreadyDone
    case skippedNotRecognized
    case error

    var color: Color {
        switch self {
        case .renamed: return .green
        case .skippedAlreadyDone: return .gray
        case .skippedNotRecognized: return .yellow
        case .error: return .red
        }
    }

    var symbol: String {
        switch self {
        case .renamed: return "checkmark.circle.fill"
        case .skippedAlreadyDone: return "minus.circle.fill"
        case .skippedNotRecognized: return "questionmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let status: FileStatus
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var folderURL: URL?
    @Published var log: [LogEntry] = []
    @Published var isRunning = false
    @Published var hasAPIKey = false
    @Published var showSettings = false

    @Published var renamedCount = 0
    @Published var alreadyDoneCount = 0
    @Published var notRecognizedCount = 0
    @Published var errorCount = 0

    @AppStorage("geminiModel") var modelID = "gemini-3.1-flash-lite"

    // YYYY-MM-DD <issuer...> <number>[ (n)].pdf
    private static let alreadyRenamedRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2} .+ \S+(\s\(\d+\))?\.pdf$"#,
        options: [.caseInsensitive]
    )
    private static let dateRegex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    init() {
        hasAPIKey = Keychain.loadAPIKey() != nil
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK {
            folderURL = panel.url
        }
    }

    func scanAndRename() {
        guard let folder = folderURL, !isRunning else { return }
        guard let apiKey = Keychain.loadAPIKey() else {
            showSettings = true
            return
        }
        isRunning = true
        log = []
        renamedCount = 0
        alreadyDoneCount = 0
        notRecognizedCount = 0
        errorCount = 0

        let client = GeminiClient(apiKey: apiKey, model: modelID)
        Task {
            await self.processFolder(folder, client: client)
            self.isRunning = false
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private func processFolder(_ folder: URL, client: GeminiClient) async {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            addLog(.error, "Could not read folder: \(error.localizedDescription)")
            return
        }

        let pdfs = contents
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        if pdfs.isEmpty {
            addLog(.skippedNotRecognized, "No PDF files found in this folder.")
            return
        }

        for (index, url) in pdfs.enumerated() {
            let name = url.lastPathComponent

            if Self.matches(Self.alreadyRenamedRegex, name) {
                alreadyDoneCount += 1
                addLog(.skippedAlreadyDone, "\(name) — already renamed")
                continue
            }

            let pdfData: Data
            do {
                pdfData = try Data(contentsOf: url)
            } catch {
                errorCount += 1
                addLog(.error, "\(name) — could not read file: \(error.localizedDescription)")
                continue
            }

            let extraction: BillingExtraction
            do {
                extraction = try await client.extractBillingFields(pdfData: pdfData)
            } catch {
                errorCount += 1
                addLog(.error, "\(name) — \(error.localizedDescription)")
                continue
            }

            let issuer = Self.stripLegalSuffixes(Self.sanitize(extraction.issuer_name))
            let number = Self.sanitize(extraction.document_number)
            let date = extraction.document_date.trimmingCharacters(in: .whitespaces)

            guard extraction.is_billing_document,
                  !issuer.isEmpty, !number.isEmpty,
                  Self.matches(Self.dateRegex, date)
            else {
                notRecognizedCount += 1
                addLog(.skippedNotRecognized, "\(name) — not recognized as a billing document")
                continue
            }

            let newName = Self.uniqueName(base: "\(date) \(issuer) \(number)", in: folder, currentName: name)
            if newName == name {
                alreadyDoneCount += 1
                addLog(.skippedAlreadyDone, "\(name) — already has the correct name")
                continue
            }

            do {
                try fm.moveItem(at: url, to: folder.appendingPathComponent(newName))
                renamedCount += 1
                addLog(.renamed, "\(name) → \(newName)")
            } catch {
                errorCount += 1
                addLog(.error, "\(name) — rename failed: \(error.localizedDescription)")
            }

            // Light throttle to stay clear of free-tier rate limits.
            if index < pdfs.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private static func sanitize(_ s: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.unicodeScalars
            .map { forbidden.contains($0) ? " " : String($0) }
            .joined()
        return cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // Safety net if the model still returns a legal corporate form,
    // e.g. "Vodafone SA" -> "Vodafone". Never strips the whole name.
    private static let legalSuffixes: Set<String> = [
        "sa", "s.a", "s.a.", "ae", "a.e", "a.e.", "ltd", "ltd.", "llc",
        "inc", "inc.", "plc", "gmbh", "ag", "bv", "b.v.", "nv", "n.v.",
        "epe", "e.p.e.", "oe", "o.e.", "ike", "spa", "s.p.a.", "srl",
        "s.r.l.", "co", "co.", "corp", "corp.",
    ]

    private static func stripLegalSuffixes(_ name: String) -> String {
        var words = name.components(separatedBy: " ")
        while words.count > 1, legalSuffixes.contains(words.last!.lowercased()) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    private static func uniqueName(base: String, in folder: URL, currentName: String) -> String {
        let fm = FileManager.default
        var candidate = "\(base).pdf"
        var counter = 2
        while candidate != currentName,
              fm.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(base) (\(counter)).pdf"
            counter += 1
        }
        return candidate
    }

    private func addLog(_ status: FileStatus, _ message: String) {
        log.append(LogEntry(status: status, message: message))
    }
}
