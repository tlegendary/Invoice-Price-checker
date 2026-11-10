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
- [ ] **3. Scanning + OCR + price matching**  ← next
  - [ ] Document camera (VisionKit) and photo / PDF import
  - [ ] Apple's text reader (Vision), rows rebuilt by position, read twice
  - [ ] Port the invoice parser and name clean-up from the old app into `Core/` with tests
  - [ ] Result screen: overcharges, missing items, add missing items to the price list
  - [ ] Arabic text (Vision supports it; Kurdish Sorani is not supported by Apple's reader)
- [ ] **4. Subscriptions + free version with ads**
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
