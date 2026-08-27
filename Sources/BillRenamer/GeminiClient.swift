import Foundation

struct BillingExtraction: Decodable {
    let is_billing_document: Bool
    let issuer_name: String
    let document_date: String
    let document_number: String
}

enum GeminiError: LocalizedError {
    case httpError(Int, String)
    case emptyResponse
    case unparseableJSON

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "API error \(code): \(body)"
        case .emptyResponse:
            return "Empty response from API"
        case .unparseableJSON:
            return "Could not parse model output as JSON"
        }
    }
}

struct GeminiClient {
    let apiKey: String
    let model: String

    private static let extractionPrompt = """
    You are analyzing a single billing document (invoice, utility bill, or
    statement) that may be in any language. Respond with ONLY a JSON object,
    no markdown, no commentary, matching exactly this schema:

    {
      "is_billing_document": boolean,
      "issuer_name": string,       // the company/organization that issued this bill,
                                     as its short common BRAND name only, in
                                     Latin/ASCII characters (transliterate if the
                                     original is in another script). Drop legal
                                     suffixes and corporate forms such as
                                     "SA", "S.A.", "A.E.", "AE", "Ltd", "LLC",
                                     "Inc", "PLC", "GmbH", "EPE", "OE", drop
                                     administrative/agency labels and department
                                     abbreviations such as "TM", "AADE", "DOY",
                                     and drop generic words like "Group",
                                     "Hellas", "Telecommunications" unless they
                                     are part of the everyday brand name. The
                                     result must be ONLY the clean brand name in
                                     Latin characters, never Greek script.
                                     e.g. "Vodafone SA" -> "Vodafone",
                                     "DEI A.E." -> "DEI", "EYDAP SA" -> "EYDAP"
      "document_date": string,    // the document's issue date, format YYYY-MM-DD
                                     (use the issue/statement date, NOT the payment
                                     due date)
      "document_number": string   // the primary account/statement/invoice number
                                     printed on the document (prefer an account or
                                     statement number over a payment/transaction
                                     reference number if both are present)
    }

    If this is not a billing document, or you cannot confidently determine all
    three fields, set "is_billing_document" to false and leave the other fields
    as empty strings.
    """

    private var endpoint: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    private func makeRequest(body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Key goes in a header, not the URL, so it never lands in logs.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func responseText(_ data: Data) throws -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { throw GeminiError.emptyResponse }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw GeminiError.emptyResponse }
        return text
    }

    private func send(body: [String: Any]) async throws -> String {
        let request = try makeRequest(body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw GeminiError.httpError(http.statusCode, snippet)
        }
        return try responseText(data)
    }

    func extractBillingFields(pdfData: Data) async throws -> BillingExtraction {
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": Self.extractionPrompt],
                    ["inline_data": [
                        "mime_type": "application/pdf",
                        "data": pdfData.base64EncodedString(),
                    ]],
                ]
            ]],
            "generationConfig": ["temperature": 0],
        ]
        var text = try await send(body: body)
        // Strip accidental markdown code fences.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(BillingExtraction.self, from: data)
        else { throw GeminiError.unparseableJSON }
        return extraction
    }

    /// Trivial request to confirm the key works. A 2xx status is enough —
    /// with a tiny token cap the model may produce no visible text.
    func testKey() async throws {
        let body: [String: Any] = [
            "contents": [["parts": [["text": "ok"]]]],
            "generationConfig": ["temperature": 0, "maxOutputTokens": 5],
        ]
        let request = try makeRequest(body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw GeminiError.httpError(http.statusCode, snippet)
        }
    }
}
