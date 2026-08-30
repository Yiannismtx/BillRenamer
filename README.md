# BillRenamer

Native macOS app (SwiftUI, macOS 13+) that renames business/accounting PDFs to
`YYYYMMDD_IssuerName_TYPE_DocumentNumber.pdf`
(e.g. `20260830_Vodafone_INV_55484.pdf`) using Anthropic's Claude API.

TYPE is one of: `INV` (invoices/bills/expenses), `PKL` (packing list),
`CNT` (contracts/agreements), `PAY` (payments), `CRE` (credit notes),
`TAX` (taxes), `LET` (letters, mainly to banks), `IMP` (import/supplier
invoices). Files named in the previous `YYYYMMDD_TYPE_Issuer_Number.pdf` or
`YYYY-MM-DD Issuer TYPE Number.pdf` schemes are converted locally without an
API call; older formats (without a type code) are rescanned and upgraded.

## Build

```
./build.sh
```

Produces `BillRenamer.app` in the project root (Swift Package Manager build,
ad-hoc code-signed). Requires Xcode.

## Use

1. Open the app; paste your Anthropic API key in the settings sheet (gear icon)
   and click **Save** (stored in the macOS Keychain, never on disk in plaintext).
   **Test Key** fires a trivial request to confirm it works.
2. **Choose Folder…**, then **Scan & Rename**.

Only top-level `.pdf` files are considered. Files already matching the
`YYYYMMDD_…_TYPE_….pdf` pattern are skipped without an API call. Everything else
is sent to Claude for identification; unrecognized documents and API errors
are logged and skipped, never renamed. Name collisions get a ` (2)`, ` (3)`
suffix. Files are renamed in place.

## Releasing an update

Two ways, both end with every installed copy auto-updating:

- **From GitHub (any collaborator):** add a What's New entry for the new
  version at the top of `ReleaseNotes.entries` in
  `Sources/BillRenamer/WhatsNewSheet.swift`, push it, then go to
  **Actions → Release → Run workflow** and enter the version (e.g. `1.8.0`).
  Requires the `SPARKLE_PRIVATE_KEY` repository secret to be set.
- **Locally (Mac with the Sparkle key in its Keychain):** add the What's New
  entry, then run `./release.sh 1.8.0`.

## Sharing the app

The API key lives in the local user's macOS Keychain, not in the app bundle.
Anyone you share `BillRenamer.app` with must paste in their own key, created at
https://console.anthropic.com/settings/keys (separate from any claude.ai chat
subscription — billed per API usage). Settings shows whether a key is linked;
unlink it there to switch keys.

## Privacy & cost note

Every scanned PDF that isn't already renamed is uploaded to Anthropic's Claude
API for analysis. Each request costs a (small) amount against your API usage.

## Notes / trade-offs

- **Model**: defaults to `claude-sonnet-5`. If Anthropic retires it, change
  the Model field in settings — no rebuild needed.
- **Non-recursive**: subfolders are not scanned (v1).
- **Rate limits**: requests run sequentially with a 0.5 s delay between files.
