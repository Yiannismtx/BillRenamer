# BillRenamer for Windows — Build Spec

Hand this file to a coding agent as the complete brief for building the Windows
version of BillRenamer. It must behave **identically** to the macOS app
(v2.0.1, https://github.com/Yiannismtx/BillRenamer) — same filenames out, same
skips, same migrations — so the two apps can be used interchangeably on the
same folders (e.g. a shared/synced folder touched by both a Mac and a PC).
Every prompt, regex, and rule below is copied verbatim from the macOS app;
do not "improve" them, port them.

## 1. What it does

1. User picks any folder via the standard folder picker.
2. The app lists the folder's **top-level** PDFs immediately (non-recursive;
   other file types silently ignored). Files already named correctly are
   marked "already renamed"; the rest are "pending".
3. On "Scan & Rename", each pending PDF is either migrated locally (older
   naming schemes, no API call) or sent to Anthropic's Claude API for field
   extraction, then renamed **in place** to:

   ```
   YYYYMMDD_Issuer_TYPE_Number.pdf      e.g. 20260830_Vodafone_INV_55484.pdf
   ```

4. Live per-file status list + summary counts + one-click "Undo Last Scan".

## 2. Recommended stack

- **C# / .NET 8, WPF** (single window; no web tech, no Electron).
- **HttpClient** for the Claude API (mirror the raw request below exactly; no
  SDK needed, though the official `Anthropic` NuGet SDK is acceptable if it
  can express `output_config.format` json_schema + `effort`).
- **Windows Credential Manager** for API key storage (via
  `CredentialManager`/`PasswordVault` APIs) — the Windows equivalent of the
  macOS Keychain. Never write the key to disk in plaintext, never log it.
- **Velopack** for auto-updates (Windows equivalent of Sparkle) — see §10.
- Settings that aren't secrets (model ID, min year, last-seen version) go in a
  JSON settings file under `%APPDATA%\BillRenamer\` (equivalent of
  UserDefaults).

## 3. Filename rules (must match macOS exactly)

Target pattern (a file matching this is "already renamed" — skipped, no API
call). All regexes case-insensitive:

```
^\d{8}_.+_(INV|PKL|CNT|PAY|CRE|TAX|LET|IMP)_[^_]+(\s\(\d+\))?\.pdf$
```

**Local migrations** (older schemes carry all four fields — rename locally,
zero API calls). Try in this order; first match wins:

1. v1.5.0 scheme `YYYYMMDD_TYPE_Issuer_Number.pdf`:
   `^(\d{8})_(INV|PKL|CNT|PAY|CRE|TAX|LET|IMP)_(.+)_([^_\s]+)(\s\(\d+\))?\.pdf$`
   → rebuild as `{g1}_{g3}_{g2.ToUpper()}_{g4}` (swap type and issuer;
   collision suffix group is dropped — re-added by collision handling if
   needed).
2. v1.4.0 scheme `YYYY-MM-DD Issuer TYPE Number.pdf`:
   `^(\d{4})-(\d{2})-(\d{2}) (.+) (INV|PKL|CNT|PAY|CRE|TAX|LET|IMP) (\S+?)(\s\(\d+\))?\.pdf$`
   → rebuild as `{g1}{g2}{g3}_{issuer}_{g5.ToUpper()}_{number}` where issuer =
   g4 and number = g6, each with `_` replaced by a space.

If the migrated name equals the current name, count as "already done". Any
even-older scheme (e.g. `YYYYMMDD Issuer Number.pdf`, no type code) does NOT
match anything above and goes through the API like a new file.

**Sanitization** of issuer and number values from the API: replace each of
`/ \ : * ? " < > | _` with a space (underscore is the field separator, so it's
forbidden inside values; note Windows forbids most of these in filenames
anyway), then collapse all whitespace runs to single spaces and trim.

**Legal-suffix safety net** on the issuer (after sanitization): repeatedly
drop the LAST word while more than one word remains and the last word
(lowercased) is in:

```
sa, s.a, s.a., ae, a.e, a.e., ltd, ltd., llc, inc, inc., plc, gmbh, ag, bv,
b.v., nv, n.v., epe, e.p.e., oe, o.e., ike, spa, s.p.a., srl, s.r.l., co,
co., corp, corp., tm, aade
```

**Collision handling:** if `{base}.pdf` exists in the folder (and isn't the
file's own current name), try `{base} (2).pdf`, `(3)`, … until unique.

**Validation before renaming** (any failure → status "not recognized", except
the year check which is an error):
- `is_recognized_document` must be true; issuer and number non-empty after
  sanitization; type (trimmed, uppercased) must be one of the 8 codes;
  date must match `^\d{4}-\d{2}-\d{2}$`.
- Year sanity check: the date's year must be within
  `[minDocumentYear, currentYear + 1]` (minDocumentYear defaults to **2024**,
  user-adjustable 1990..currentYear in settings). Outside → red error
  "Suspicious date … likely a misread date, not renamed", file untouched.
- Filename is built from the date with dashes removed: `YYYYMMDD`.

## 4. Claude API call (copy exactly)

`POST https://api.anthropic.com/v1/messages` with headers
`x-api-key: <key>`, `anthropic-version: 2023-06-01`,
`Content-Type: application/json`. 30-second timeout. Body:

```json
{
  "model": "<modelID setting, default claude-sonnet-5>",
  "max_tokens": 8192,
  "output_config": {
    "effort": "low",
    "format": {
      "type": "json_schema",
      "schema": {
        "type": "object",
        "properties": {
          "is_recognized_document": {"type": "boolean"},
          "issuer_name": {"type": "string"},
          "document_date": {"type": "string"},
          "document_type": {"type": "string"},
          "document_number": {"type": "string"}
        },
        "required": ["is_recognized_document", "issuer_name", "document_date",
                     "document_type", "document_number"],
        "additionalProperties": false
      }
    }
  },
  "messages": [{
    "role": "user",
    "content": [
      {"type": "document",
       "source": {"type": "base64", "media_type": "application/pdf",
                  "data": "<base64 of the PDF, no newlines>"}},
      {"type": "text", "text": "<PROMPT — verbatim below>"}
    ]
  }]
}
```

The prompt text (verbatim — keep the Greek terms):

```
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
```

**Response parsing:** find the first content block with `"type": "text"` and
parse its `text` as JSON into the five fields (a `thinking` block may precede
it — never assume index 0). Empty/missing text → error "Empty response from
API".

**Errors & retry:** non-2xx → extract `error.message` from the JSON body
(fall back to the first 300 bytes), strip newlines. On status **429, 500, or
529** wait 3 s and retry **once**; then give up and mark the file as error.
One failed file never stops the batch.

**Throttle:** 500 ms delay between consecutive API files.

**Test Key:** same endpoint, body
`{"model": <modelID>, "max_tokens": 16, "messages": [{"role":"user","content":"ok"}]}` —
any 2xx counts as success (don't require response text).

## 5. UI (single window, mirror the macOS app)

- Header row: **Choose Folder…** · **Scan & Rename** (default button;
  disabled unless a folder is chosen, not running, and pending > 0) ·
  refresh button (re-list folder; keep exclusions for files still present) ·
  **Undo Last Scan** (visible only when the last scan renamed ≥1 file;
  disabled while running) · spinner while running · chosen folder path
  (truncated middle) · **?** help popover · settings gear.
- File list, one row per PDF, sorted by natural/logical name order
  (Windows: `StrCmpLogicalW`-style). Each row: status icon + color, filename
  (monospace), detail line. Statuses:
  - pending (clock, gray) — no detail
  - excluded (slash, gray, name struck through) — "Excluded from scan"
  - already renamed (minus, gray) — "Already renamed"
  - processing (spinner, blue) — "Analyzing…"
  - renamed (check, green) — "→ {newName}"
  - not recognized (question mark, yellow) — "Not recognized as a supported
    document type"
  - error (x, red) — the error message
- Row hover controls: **➖ exclude** on pending rows / **➕ include** on
  excluded rows; **↺ Scan anyway** on already-renamed rows (queues it for the
  API despite its name; the exclude button on such a force-queued row returns
  it to "already renamed" instead of excluding). Context menu: the same
  toggle, "Scan Anyway" where applicable, "Show in Explorer", "Open".
- Summary bar:
  `To scan: N · Renamed: X · Already done: Y · Not recognized: Z · Errors: W`.
- Tooltips on every control explaining what it does (copy the intent from the
  macOS app; e.g. exclude = "won't be sent to the API or renamed").
- Help popover: explains the flow, the format with example, the 8 type codes,
  local migration, rename-in-place, that every scanned PDF is uploaded to
  Anthropic's Claude API and costs a small amount per document.

**Scan behavior details:**
- Starting a scan first re-lists the folder; previous notRecognized/error
  results go back to pending (i.e. re-scanning retries them automatically).
- "Scan anyway" state must survive that re-list (track forced full paths).
- **Undo Last Scan:** record every (from, to) rename of the most recent scan
  (replaced, not accumulated, per scan); undo reverts them in reverse order,
  skipping files that were since moved/renamed/deleted, then re-lists and — if
  anything couldn't be restored — shows an alert:
  "Reverted X of Y rename(s). N file(s) couldn't be restored — they may have
  been moved, renamed, or deleted since the scan."

## 6. Settings dialog

- **Anthropic API Key**: when no key is linked, show onboarding instructions
  (get a key at https://console.anthropic.com/settings/keys — sign in, add
  billing under Settings → Billing, create a key starting `sk-ant-…`, note
  that API billing is separate from any claude.ai subscription and costs a
  fraction of a cent per document) + a button opening that URL + a password
  field + Save. When a key IS linked: green "A key is linked" indicator +
  **Unlink…** (with confirmation dialog) — to change keys you must unlink
  first. **Test Key** button (enabled only when linked) shows "Key works." or
  the error.
- **Model** text field, default `claude-sonnet-5`, with hint that
  `claude-haiku-4-5` is cheaper and `claude-opus-5` more accurate.
- **Earliest Expected Document Year** numeric stepper, default 2024, range
  1990..currentYear, with explanation (misread-date guard; lower it for older
  archives).
- Privacy note: "every scanned PDF is uploaded to Anthropic's Claude API".
- Version line + **Check for Updates…** button.
- The settings dialog opens automatically on launch when no key is stored.

## 7. What's New

Release notes live in code as an ordered list of (version, bullet list),
newest first. On launch, if a stored `lastSeenVersion` exists, differs from
the current version, and the current version has notes → show a "What's new in
BillRenamer {version}" dialog once, then store the current version. Fresh
installs just store the version (onboarding takes priority). The release
process must refuse to publish a version with no notes entry.

## 8. Key storage

Windows Credential Manager, target name `BillRenamer/anthropic-api-key`,
generic credential. Read at launch to set "key linked" state.

## 9. Repository & coexistence

Windows code lives in the same repo (https://github.com/Yiannismtx/BillRenamer)
under `windows/` as a self-contained .NET solution — do not touch the macOS
sources, `releases/` (the Mac Sparkle feed), or the existing
`.github/workflows/release.yml`. Shared behavioral rules (this file) are the
contract between the two apps: **any future change to the naming scheme,
prompt, or migrations must be made to both apps together.**

## 10. Auto-updates & distribution

Mirror the Mac approach with Windows tooling, same repo:

- **Velopack** (successor of Squirrel.Windows; NuGet `Velopack`): call
  `VelopackApp.Build().Run()` at startup, check
  `new UpdateManager(new GithubSource(...))` or a plain URL source pointed at
  `https://raw.githubusercontent.com/Yiannismtx/BillRenamer/main/releases-windows/`
  on launch; download + apply on user confirmation, mirroring Sparkle's flow.
- A separate `releases-windows/` folder in the repo holds the Velopack feed
  (`releases.win.json` + `.nupkg` packages + Setup.exe), published by a new
  GitHub Actions workflow (`windows-release.yml`, `runs-on: windows-latest`)
  triggered by workflow_dispatch with a version input: build
  (`dotnet publish -c Release -r win-x64 --self-contained`), `vpk pack`,
  commit the feed folder, push. Refuse to run without a What's New entry.
- The app is unsigned (no code-signing certificate) — SmartScreen will warn on
  first install; users click "More info → Run anyway". Document this in the
  install instructions, same spirit as the Mac's right-click-open.

## 11. Acceptance tests (run before first release)

1. A folder with `20260830_Vodafone_INV_55484.pdf` → listed gray, zero API
   calls.
2. `20260830_INV_Vodafone_55484.pdf` (v1.5.0 name) → renamed locally to
   `20260830_Vodafone_INV_55484.pdf` with no API call; Undo restores it.
3. `2026-08-30 Cosmote Fiber INV 123.pdf` (v1.4.0 name) → locally becomes
   `20260830_Cosmote Fiber_INV_123.pdf`.
4. A real Greek utility bill PDF → renamed with day-first date, Latin issuer,
   correct type code; a second scan skips it.
5. A non-billing PDF (e.g. a book chapter) → yellow "not recognized",
   untouched.
6. Collision: two different PDFs resolving to the same name → second gets
   ` (2)` suffix.
7. Invalid API key → red per-file errors, batch completes, app never crashes;
   Test Key reports the failure.
8. Rename a file to a bogus early date manually… (skip — instead: if the
   model returns a year before minDocumentYear, the file is flagged, not
   renamed; verify by temporarily setting the stepper to a future-ish year).
