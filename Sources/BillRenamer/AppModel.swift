import Foundation
import SwiftUI

enum FileStatus: Equatable {
    case pending                 // will be scanned
    case excluded                // user removed it from the scan
    case alreadyRenamed          // matches the target pattern, no API call
    case processing              // request in flight
    case renamed(String)         // new filename
    case notRecognized
    case error(String)

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .excluded: return .secondary
        case .alreadyRenamed: return .gray
        case .processing: return .blue
        case .renamed: return .green
        case .notRecognized: return .yellow
        case .error: return .red
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "clock"
        case .excluded: return "slash.circle"
        case .alreadyRenamed: return "minus.circle.fill"
        case .processing: return "arrow.triangle.2.circlepath"
        case .renamed: return "checkmark.circle.fill"
        case .notRecognized: return "questionmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var detail: String? {
        switch self {
        case .pending: return nil
        case .excluded: return "Excluded from scan"
        case .alreadyRenamed: return "Already renamed"
        case .processing: return "Analyzing…"
        case .renamed(let newName): return "→ \(newName)"
        case .notRecognized: return "Not recognized as a supported document type"
        case .error(let message): return message
        }
    }
}

struct FileItem: Identifiable {
    let id = UUID()
    var url: URL
    var status: FileStatus

    var name: String { url.lastPathComponent }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var folderURL: URL?
    @Published var files: [FileItem] = []
    @Published var isRunning = false
    @Published var hasAPIKey = false
    @Published var showSettings = false

    @Published var renamedCount = 0
    @Published var alreadyDoneCount = 0
    @Published var notRecognizedCount = 0
    @Published var errorCount = 0

    @AppStorage("geminiModel") var modelID = "gemini-3.1-flash-lite"

    /// Files the user chose to scan even though their name already matches
    /// the renamed pattern. Survives the refresh that runs before a scan.
    private var forcedURLs: Set<URL> = []

    static let documentTypes: Set<String> = ["INV", "PKL", "CNT", "PAY", "CRE", "TAX", "LET", "IMP"]

    // YYYYMMDD_<issuer...>_<TYPE>_<number>[ (n)].pdf
    // Older schemes don't match, so those files get migrated or rescanned.
    private static let alreadyRenamedRegex = try! NSRegularExpression(
        pattern: #"^\d{8}_.+_(INV|PKL|CNT|PAY|CRE|TAX|LET|IMP)_[^_]+(\s\(\d+\))?\.pdf$"#,
        options: [.caseInsensitive]
    )
    // Earlier schemes that already carry all four fields are rearranged
    // locally — no API call:
    // 1.5.0: "YYYYMMDD_TYPE_Issuer_Number.pdf"
    private static let v150FormatRegex = try! NSRegularExpression(
        pattern: #"^(\d{8})_(INV|PKL|CNT|PAY|CRE|TAX|LET|IMP)_(.+)_([^_\s]+)(\s\(\d+\))?\.pdf$"#,
        options: [.caseInsensitive]
    )
    // 1.4.0: "YYYY-MM-DD Issuer TYPE Number.pdf"
    private static let v140FormatRegex = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2}) (.+) (INV|PKL|CNT|PAY|CRE|TAX|LET|IMP) (\S+?)(\s\(\d+\))?\.pdf$"#,
        options: [.caseInsensitive]
    )
    private static let dateRegex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    var pendingCount: Int {
        files.filter { $0.status == .pending }.count
    }

    init() {
        hasAPIKey = Keychain.loadAPIKey() != nil
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folderURL = url
            refreshFileList()
        }
    }

    /// Lists the folder's top-level PDFs, marking already-renamed ones.
    /// Keeps exclusions for files that are still present.
    func refreshFileList() {
        guard let folder = folderURL, !isRunning else { return }
        resetCounts()

        let previouslyExcluded = Set(
            files.filter { $0.status == .excluded }.map { $0.url }
        )

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        files = contents
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let status: FileStatus
                if previouslyExcluded.contains(url) {
                    status = .excluded
                } else if Self.matches(Self.alreadyRenamedRegex, url.lastPathComponent),
                          !forcedURLs.contains(url) {
                    status = .alreadyRenamed
                } else {
                    status = .pending
                }
                return FileItem(url: url, status: status)
            }
    }

    func toggleExcluded(_ item: FileItem) {
        guard !isRunning,
              let index = files.firstIndex(where: { $0.id == item.id })
        else { return }
        switch files[index].status {
        case .pending:
            // A force-queued already-renamed file goes back to its natural
            // state instead of "excluded".
            if forcedURLs.contains(files[index].url) {
                forcedURLs.remove(files[index].url)
                files[index].status = .alreadyRenamed
            } else {
                files[index].status = .excluded
            }
        case .excluded:
            files[index].status = .pending
        default:
            break // finished rows aren't toggleable
        }
    }

    /// Queues an already-renamed file for scanning anyway.
    func scanAnyway(_ item: FileItem) {
        guard !isRunning,
              let index = files.firstIndex(where: { $0.id == item.id }),
              files[index].status == .alreadyRenamed
        else { return }
        forcedURLs.insert(files[index].url)
        files[index].status = .pending
    }

    func scanAndRename() {
        guard let folder = folderURL, !isRunning else { return }
        guard let apiKey = Keychain.loadAPIKey() else {
            showSettings = true
            return
        }
        // Re-list in case the folder changed since it was chosen,
        // then reset earlier results to pending.
        refreshFileList()
        guard files.contains(where: { $0.status == .pending }) else { return }

        isRunning = true
        resetCounts()
        alreadyDoneCount = files.filter { $0.status == .alreadyRenamed }.count

        let client = GeminiClient(apiKey: apiKey, model: modelID)
        Task {
            await self.processPendingFiles(in: folder, client: client)
            self.isRunning = false
        }
    }

    private func resetCounts() {
        renamedCount = 0
        alreadyDoneCount = 0
        notRecognizedCount = 0
        errorCount = 0
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private func processPendingFiles(in folder: URL, client: GeminiClient) async {
        let fm = FileManager.default
        let pendingIDs = files.filter { $0.status == .pending }.map { $0.id }

        for (index, id) in pendingIDs.enumerated() {
            guard let i = files.firstIndex(where: { $0.id == id }) else { continue }
            let url = files[i].url
            let name = url.lastPathComponent
            forcedURLs.remove(url)
            setStatus(id, .processing)

            // Previous scheme: rearrange the existing fields locally.
            if let migrated = Self.migratedName(from: name) {
                let newName = Self.uniqueName(base: migrated, in: folder, currentName: name)
                do {
                    let newURL = folder.appendingPathComponent(newName)
                    try fm.moveItem(at: url, to: newURL)
                    renamedCount += 1
                    if let i = files.firstIndex(where: { $0.id == id }) {
                        files[i].url = newURL
                    }
                    setStatus(id, .renamed(newName))
                } catch {
                    errorCount += 1
                    setStatus(id, .error("Rename failed: \(error.localizedDescription)"))
                }
                continue
            }

            let pdfData: Data
            do {
                pdfData = try Data(contentsOf: url)
            } catch {
                errorCount += 1
                setStatus(id, .error("Could not read file: \(error.localizedDescription)"))
                continue
            }

            let extraction: BillingExtraction
            do {
                extraction = try await client.extractBillingFields(pdfData: pdfData)
            } catch {
                errorCount += 1
                setStatus(id, .error(error.localizedDescription))
                continue
            }

            let issuer = Self.stripLegalSuffixes(Self.sanitize(extraction.issuer_name))
            let number = Self.sanitize(extraction.document_number)
            let date = extraction.document_date.trimmingCharacters(in: .whitespaces)
            let type = extraction.document_type.trimmingCharacters(in: .whitespaces).uppercased()

            guard extraction.is_recognized_document,
                  !issuer.isEmpty, !number.isEmpty,
                  Self.documentTypes.contains(type),
                  Self.matches(Self.dateRegex, date)
            else {
                notRecognizedCount += 1
                setStatus(id, .notRecognized)
                continue
            }

            // All of this user's bills are from 2024 onward — a year outside
            // that range means the model misread the (day-first) date, so
            // flag it instead of renaming wrongly.
            let currentYear = Calendar.current.component(.year, from: Date())
            if let year = Int(date.prefix(4)), !(2024...(currentYear + 1)).contains(year) {
                errorCount += 1
                setStatus(id, .error("Suspicious date \"\(date)\" (expected year 2024–\(currentYear + 1)) — likely a misread date, not renamed"))
                continue
            }

            let compactDate = date.replacingOccurrences(of: "-", with: "")
            let newName = Self.uniqueName(base: "\(compactDate)_\(issuer)_\(type)_\(number)", in: folder, currentName: name)
            if newName == name {
                alreadyDoneCount += 1
                setStatus(id, .alreadyRenamed)
                continue
            }

            do {
                let newURL = folder.appendingPathComponent(newName)
                try fm.moveItem(at: url, to: newURL)
                renamedCount += 1
                if let i = files.firstIndex(where: { $0.id == id }) {
                    files[i].url = newURL
                }
                setStatus(id, .renamed(newName))
            } catch {
                errorCount += 1
                setStatus(id, .error("Rename failed: \(error.localizedDescription)"))
            }

            // Light throttle to stay clear of free-tier rate limits.
            if index < pendingIDs.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func setStatus(_ id: UUID, _ status: FileStatus) {
        if let index = files.firstIndex(where: { $0.id == id }) {
            files[index].status = status
        }
    }

    /// Rebuilds a name from an earlier scheme in the current format
    /// (YYYYMMDD_Issuer_TYPE_Number), or nil if it isn't in one.
    private static func migratedName(from name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        func group(_ match: NSTextCheckingResult, _ i: Int) -> String {
            guard let r = Range(match.range(at: i), in: name) else { return "" }
            return String(name[r])
        }
        // 1.5.0: YYYYMMDD_TYPE_Issuer_Number → swap type and issuer.
        if let m = v150FormatRegex.firstMatch(in: name, range: range) {
            return "\(group(m, 1))_\(group(m, 3))_\(group(m, 2).uppercased())_\(group(m, 4))"
        }
        // 1.4.0: YYYY-MM-DD Issuer TYPE Number.
        if let m = v140FormatRegex.firstMatch(in: name, range: range) {
            let date = group(m, 1) + group(m, 2) + group(m, 3)
            let issuer = group(m, 4).replacingOccurrences(of: "_", with: " ")
            let number = group(m, 6).replacingOccurrences(of: "_", with: " ")
            return "\(date)_\(issuer)_\(group(m, 5).uppercased())_\(number)"
        }
        return nil
    }

    private static func sanitize(_ s: String) -> String {
        // Underscore is the field separator in the filename, so it's
        // forbidden inside field values too.
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|_")
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
        "s.r.l.", "co", "co.", "corp", "corp.", "tm", "aade",
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
}
