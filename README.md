# BillRenamer

Native macOS app (SwiftUI, macOS 13+) that renames business/accounting PDFs to
`YYYYMMDD_TYPE_IssuerName_DocumentNumber.pdf`
(e.g. `20260830_INV_Vodafone_55484.pdf`) using the Gemini API.

TYPE is one of: `INV` (invoices/bills/expenses), `PKL` (packing list),
`CNT` (contracts/agreements), `PAY` (payments), `CRE` (credit notes),
`TAX` (taxes), `LET` (letters, mainly to banks), `IMP` (import/supplier
invoices). Files named in the previous `YYYY-MM-DD Issuer TYPE Number.pdf`
scheme are converted locally without an API call; older formats (without a
type code) are rescanned and upgraded.

## Build

```
./build.sh
```

Produces `BillRenamer.app` in the project root (Swift Package Manager build,
ad-hoc code-signed). Requires Xcode.

## Use

1. Open the app; paste your Gemini API key in the settings sheet (gear icon)
   and click **Save** (stored in the macOS Keychain, never on disk in plaintext).
   **Test Key** fires a trivial request to confirm it works.
2. **Choose Folder…**, then **Scan & Rename**.

Only top-level `.pdf` files are considered. Files already matching the
`YYYYMMDD_TYPE_…_….pdf` pattern are skipped without an API call. Everything else
is sent to Gemini for identification; unrecognized documents and API errors
are logged and skipped, never renamed. Name collisions get a ` (2)`, ` (3)`
suffix. Files are renamed in place.

## Sharing the app

The API key lives in the local user's macOS Keychain, not in the app bundle.
Anyone you share `BillRenamer.app` with must paste in their own key (free at
https://aistudio.google.com/apikey). Settings shows whether a key is linked;
unlink it there to switch keys.

## Privacy & cost note

Every scanned PDF that isn't already renamed is uploaded to Google's Gemini
API for analysis. Each request costs a (small) amount against your API quota.

## Notes / trade-offs

- **Model**: defaults to `gemini-3.1-flash-lite` (verified current as of
  Aug 2026). If Google renames it, change the Model field in settings — no
  rebuild needed.
- **Non-recursive**: subfolders are not scanned (v1).
- **Rate limits**: requests run sequentially with a 0.5 s delay between files.
