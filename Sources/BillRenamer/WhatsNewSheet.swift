import SwiftUI

/// Release notes shown once after each update. Keep the newest version
/// first — release.sh refuses to publish a version that has no entry here.
enum ReleaseNotes {
    static let entries: [(version: String, notes: [String])] = [
        ("1.7.0", [
            "New \"What's New\" page — appears once after every update, like this one.",
            "File names now put the issuer before the type: YYYYMMDD_Issuer_TYPE_Number.pdf, e.g. 20260830_Vodafone_INV_55484.pdf.",
            "Files named by older versions are converted to the new format on your next scan — instantly and without using the API, when possible.",
        ]),
    ]

    static func notes(for version: String) -> [String] {
        entries.first(where: { $0.version == version })?.notes ?? []
    }
}

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.yellow)
                Text("What's new in BillRenamer \(version)")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(ReleaseNotes.notes(for: version), id: \.self) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }

            HStack {
                Spacer()
                Button("Continue") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
