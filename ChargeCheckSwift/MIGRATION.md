# ChargeCheck – moving to native Swift

The first version of ChargeCheck is a web app (HTML/JavaScript) inside an iPhone
shell. It is being rewritten in Apple's own language, **Swift + SwiftUI**, in stages.
The old version (on `main`) stays untouched and keeps working until the Swift one
is ready and Ramyar says to switch.

- Swift code: `ChargeCheckSwift/` on the `swift-rewrite` branch
- Same bundle ID (`com.rjapps.invoicepricechecker`), app name and App Store products
- Needs iOS 17 or later (for SwiftData)
- Cloud check: GitHub Actions (`.github/workflows/swift-check.yml`) runs the tests and
  builds the app on every push to `swift-rewrite`. Short logs are kept on the `ci-logs` branch.
  It never uploads to the App Store.

## Stages

- [x] **1. Project skeleton + cloud build**
  - [x] `Core/` – pure Swift logic with unit tests (matching, money, backups, categories)
  - [x] `App/` – SwiftUI app with the four tabs, built in the cloud from `project.yml` (XcodeGen)
  - [x] Privacy manifest, app icon, Files-app folder kept
- [x] **2. Price list**
  - [x] Saved with SwiftData
  - [x] Add, edit, swipe to delete, search, grouped by category
  - [x] Paste a price list
  - [x] Sort into categories (preview, untick, apply)
  - [x] Backup and restore through the Files app (same file format as the old app)
  - [x] First launch brings over prices and reports from the old app automatically
  - [x] Light / dark / automatic and 8 colours
  - [ ] Import Excel / CSV
  - [ ] Special prices per supplier (kept in the data, no screen yet)
- [x] **3. Scanning + OCR + price matching**
  - [x] Document camera (VisionKit, several pages), photos, PDFs and files, type by hand
  - [x] Apple's text reader (Vision), rows rebuilt by position, every invoice read twice
  - [x] Invoice reader logic ported to `Core/` – tests check it gives the same answers as the old app
        (735 lines, 271 names, 41 invoices, 40 merges; rebuild them with `tools/make-parser-fixtures.js`)
  - [x] Result screen: overcharge, things to check, edit a line, choose the matching item,
        missing/returned items, add new items to the price list, printed-total check
  - [x] Saved to Reports once every line is checked; the same invoice is never saved twice
  - [x] Learns the user's name corrections and how each supplier writes an item
  - [x] Sample invoice (read for real by the cloud check on every change)
  - [ ] Lower my price automatically when a checked invoice is cheaper (old app did this)
  - [ ] Photo quality hints (dark / blurry), exact text from PDFs that contain text
  - [ ] Arabic text (needs Ramyar's decision; Kurdish Sorani is not supported by Apple's reader)
- [ ] **4. Subscriptions + free version with ads**  ← next
  - [ ] StoreKit 2: `ipc_yearly`, `ipc_monthlyy` (7-day trial), packs `ipc_scans_3/10/30`, restore
  - [ ] Google Mobile Ads (same ad unit IDs), one rewarded ad = one scan, consent + tracking prompt
  - [ ] Paywall as a closable sheet
- [ ] **5. Reports, PDF export + backup**
  - [ ] Reports: choose invoices to pay, mark as paid, copy breakdown (basic totals are done)
  - [ ] PDF / spreadsheet for the accountant, price-list PDF, credit request PDF (in the chosen colour)
  - [ ] Automatic backup, iCloud Drive folder, copies of invoices
  - [ ] Monthly reminder
- [ ] **6. Polish**
  - [ ] Price history chart, sample invoice, rating prompt, shops
  - [ ] Codemagic workflow to sign and send the Swift build to TestFlight
  - [ ] Ask Ramyar before switching the App Store build to the Swift version

## Rules

- Never upload the Swift build to TestFlight / the App Store until Ramyar says yes.
- Do not change prices, products, trial length, ad frequency or AdMob IDs without asking.
- No phone number anywhere. Contact is email only.
