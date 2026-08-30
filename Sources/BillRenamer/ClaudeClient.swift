import Foundation

struct BillingExtraction: Decodable {
    let is_recognized_document: Bool
    let issuer_name: String
    let document_date: String
    let document_type: String
    let document_number: String
}

enum ClaudeError: LocalizedError {
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

struct ClaudeClient {
    let apiKey: String
    let model: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let extractionPrompt = """
    You are analyzing a single business/accounting document (invoice, utility
    bill, statement, contract, payment confirmation, credit note, tax
    document, packing list, or business letter) that may be in any language,
    often Greek. Extract these fields:

    - issuer_name: the company/organization that issued this bill, as its
      short common BRAND name only, in Latin/ASCII characters (transliterate
      if the original is in another script). Drop legal suffixes and
      corporate forms such as "SA", "S.A.", "A.E.", "AE", "Ltd", "LLC",
      "Inc", "PLC", "GmbH", "EPE", "OE", drop administrative/agency labels
      and department abbreviations such as "TM", "AADE", "DOY", and drop
      generic words like "Group", "Hellas", "Telecommunications" unless they
      are part of the everyday brand name. The result must be ONLY the clean
      brand name in Latin characters, never Greek script.
      e.g. "Vodafone SA" -> "Vodafone", "DEI A.E." -> "DEI", "EYDAP SA" -> "EYDAP"
    - document_date: the document's issue date, format YYYY-MM-DD (use the
      issue/statement date, NOT the payment due date). IMPORTANT: dates
      printed on these documents are in European DAY-FIRST order —
      "05/03/2025" means 5 March 2025, and in "27/05/25" the 25 is the year
      2025, never the day. A two-digit year YY means 20YY. All of these
      documents were issued in 2024 or later; if the date you extracted has
      an earlier year, you have misread the date format — re-read it
      day-first.
    - document_type: EXACTLY one of these codes:
        "INV" = service invoices, invoice/delivery notes, expense invoices
                (ΤΙΜΟΛΟΓΙΑ ΠΑΡΟΧΗΣ ΥΠΗΡΕΣΙΩΝ, ΤΙΜΟΛΟΓΙΑ ΔΕΛΤΙΑ ΑΠΟΣΤΟΛΗΣ,
                ΔΑΠΑΝΕΣ), including utility bills
        "PKL" = packing list
        "CNT" = contracts, agreements (ΣΥΜΒΑΣΕΙΣ, ΣΥΜΦΩΝΗΤΙΚΑ)
        "PAY" = payments, payment confirmations, receipts of payment (ΠΛΗΡΩΜΕΣ)
        "CRE" = credit notes from creditors/suppliers (ΠΙΣΤΩΤΙΚΑ)
        "TAX" = tax documents (ΦΟΡΟΙ)
        "LET" = letters, mainly to banks (ΕΠΙΣΤΟΛΕΣ ΠΡΟΣ ΤΡΑΠΕΖΕΣ)
        "IMP" = supplier invoices for imports (ΤΙΜΟΛΟΓΙΑ ΠΡΟΜΗΘΕΥΤΩΝ, ΕΙΣΑΓΩΓΕΣ)
    - document_number: the primary account/statement/invoice number printed
      on the document (prefer an account or statement number over a
      payment/transaction reference number if both are present)

    If this is not one of the document types above, or you cannot
    confidently determine all four fields, set is_recognized_document to
    false and leave the other fields as empty strings.
    """

    private static let extractionSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "is_recognized_document": ["type": "boolean"],
            "issuer_name": ["type": "string"],
            "document_date": ["type": "string"],
            "document_type": ["type": "string"],
            "document_number": ["type": "string"],
        ],
        "required": ["is_recognized_document", "issuer_name", "document_date", "document_type", "document_number"],
        "additionalProperties": false,
    ]

    private func makeRequest(body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// output_config.format guarantees a text block with valid JSON, but a
    /// thinking block may still precede it in `content`, so find by type
    /// rather than assuming index 0.
    private func responseText(_ data: Data) throws -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
            !text.isEmpty
        else { throw ClaudeError.emptyResponse }
        return text
    }

    static func errorMessage(status: Int, data: Data) -> String {
        var message = String(data: data.prefix(300), encoding: .utf8) ?? ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let msg = error["message"] as? String {
            message = msg.replacingOccurrences(of: "\n", with: " ")
        }
        return message
    }

    private func sendOnce(body: [String: Any]) async throws -> Data {
        let request = try makeRequest(body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClaudeError.httpError(http.statusCode, Self.errorMessage(status: http.statusCode, data: data))
        }
        return data
    }

    private func send(body: [String: Any]) async throws -> String {
        do {
            return try responseText(try await sendOnce(body: body))
        } catch ClaudeError.httpError(let code, _) where [429, 500, 529].contains(code) {
            // Rate limit, server error, or overloaded: wait a moment and
            // retry once before giving up.
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return try responseText(try await sendOnce(body: body))
        }
    }

    func extractBillingFields(pdfData: Data) async throws -> BillingExtraction {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": Self.extractionSchema,
                ],
            ],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "document", "source": [
                        "type": "base64",
                        "media_type": "application/pdf",
                        "data": pdfData.base64EncodedString(),
                    ]],
                    ["type": "text", "text": Self.extractionPrompt],
                ],
            ]],
        ]
        let text = try await send(body: body)
        guard let data = text.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(BillingExtraction.self, from: data)
        else { throw ClaudeError.unparseableJSON }
        return extraction
    }

    /// Trivial request to confirm the key works.
    func testKey() async throws {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16,
            "messages": [["role": "user", "content": "ok"]],
        ]
        _ = try await sendOnce(body: body)
    }
}
