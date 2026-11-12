# ChargeCheck – moving to native Swift

The first version of ChargeCheck is a web app (HTML/JavaScript) inside an iPhone
shell. It is being rewritten in Apple's own language, **Swift + SwiftUI**, in stages.
The old version (on `main`) stays untouched and keeps working until the Swift one
is ready and Ramyar says to switch.

- Swift code: `ChargeCheckSwift/` on the `swift-rewrite` branch
- Same bundle ID (`com.rjapps.invoicepricechecker`), app name and App Store products
- Needs iOS 17 or later (for SwiftData)
- Cloud check: GitHub Actions (`.github/workflows/swift-check.yml`) runs the tests and
  builds the app on every push to `swift-rewrite` and to `improve/…` branches. Short logs are kept on the `ci-logs` branch.
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
  - [x] Import CSV (stage 6) · [ ] Excel (.xlsx) files
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
  - [x] Lower my price automatically when a checked invoice is cheaper (done in stage 6)
  - [x] Photo quality hints: when nothing could be read, says if the photo was too dark or blurry (11 Nov 2026)
  - [ ] Exact text from PDFs that contain text (instead of reading a picture of the page)
  - [ ] Arabic text (needs Ramyar's decision; Kurdish Sorani is not supported by Apple's reader)
- [x] **4. Subscriptions + free version with ads**
  - [x] StoreKit 2: `ipc_yearly`, `ipc_monthlyy` (7-day trial), packs `ipc_scans_3/10/30`, restore purchases
  - [x] Plans screen as a closable sheet (terms, privacy, restore); closing it carries on with the free version
  - [x] Free version: one rewarded ad watched to the end = one scan; a closed or failed ad gives no scan
  - [x] Google Mobile Ads 13.11.0 (same version and ad unit as the old app), consent form, Apple's tracking question
  - [x] Subscribers never start the ads code
  - [x] Unused scans carry over from the old app and travel in backups (not back onto the same phone)
  - [x] Test mode (`CCTestBuild` in `project.yml`): test ads + "use the free version" switch. **Turn off before App Review.**
  - [x] Purchase tests against Apple's StoreKit test server (`Tests/StoreTests.swift`). They are slow in the cloud,
        so they only run when a commit message contains `[store]`.
        Seen passing: products + trial, monthly, yearly unlock + expiry, pack bought and counted once.
        The pack test is sometimes very slow to start on a cold simulator.
  - [ ] Not tested yet: real ads and real purchases on a phone (needs a TestFlight build)
- [x] **5. Reports, PDF export + backup**
  - [x] Reports: "To pay" per supplier, choose invoices (all ticked to begin with), mark as paid + undo, copy breakdown
  - [x] One invoice: lines, paid switch, original photo/PDF, credit request PDF, delete
  - [x] PDF / spreadsheet (CSV) for the accountant by period, price-list PDF, credit request PDF (in the chosen colour)
  - [x] Automatic backup (Files app › ChargeCheck, last 14 days), iCloud Drive folder, copies of invoices (phone / ask / off)
  - [x] Monthly reminder
  - [ ] Not tested yet on a real phone: iCloud folder, notifications, the share sheet (simulator checked: screens, PDFs, backup files)
- [ ] **6. Polish**  ← in progress
  - [x] Price history chart on each item (what suppliers charged over time against the agreed price)
  - [x] Shops: add / rename / remove, new invoices filed under the ticked shop, Reports can show one shop
  - [x] Lower an agreed price when a fully checked invoice is cheaper (with Undo, can be turned off)
  - [x] "Ignore differences up to" setting, rating prompt after a few saved invoices
  - [x] Open a spreadsheet (CSV) or text file as a price list
  - [x] Backups now also carry shops, the tolerance and the invoice-copies choice
  - [x] Codemagic workflow `swift-beta` (in `codemagic.yaml`): builds the Swift app as a separate **ChargeCheck Beta** app
        (bundle ID `com.rjapps.invoicepricechecker.beta`) and sends it to TestFlight. It only runs when
        `ChargeCheckSwift/.beta-build` changes. The live app's bundle ID and workflow are unchanged.
  - [x] Beta bundle ID registered, "ChargeCheck Beta" app created, first build uploaded to TestFlight (10 Nov 2026).
        To send a new build: change `ChargeCheckSwift/.beta-build` and push.
  - [ ] Note: the beta app has no in-app purchase products of its own, so the plans won't load there. Use the test-mode switch.
  - [ ] Try on a real phone: camera scanner, real ads and purchases, iCloud folder, notifications
  - [ ] Ask Ramyar before switching the App Store build to the Swift version

## Apple Intelligence check (added 11 Nov 2026, Ramyar's request)
- `App/Reading/SmartCheck.swift`: after the photo is read, the on-device Apple Intelligence model (iOS 26, FoundationModels)
  fixes misread names, picks the matching price-list item from a short list of choices, and flags lines that aren't products.
- It never changes quantities or prices. A name Ramyar corrected by hand is never sent. Settings has an on/off switch.
- Only on phones with Apple Intelligence (iPhone 15 Pro or newer, switched on). Otherwise the normal reader is used.

## Languages and currencies (added 11 Nov 2026)
- App screens in English, Kurdish Sorani (ckb), Arabic (ar), German (de), French (fr): `App/Localizable.xcstrings`.
  Text outside views goes through `L()` (app) and `CoreText` (core). Arabic and Kurdish are right-to-left.
- Invoices read in English, German, French, Arabic, Kurdish (Settings › Language and money). Kurdish uses Apple's Arabic reader
  (no Kurdish reader exists yet). Arabic-Indic digits, "1.234,56" and dinar amounts are understood.
- Currencies: £, €, $, IQD. Changing currency does not convert saved prices.
- Still to do: right-to-left layout inside the PDFs; Ramyar to check the Kurdish wording.

## Supplier accounts, trusted suppliers, widget, better reading (added 11 Nov 2026)
- Suppliers tab: balance = starting balance + invoices (amount to pay) − payments − credit notes − invoices marked paid
  before payments existed. Payments towards the balance pay the oldest invoices first ("Still to pay").
  Ticked invoices ("Pay invoices one by one", and Reports › Mark as paid) record one payment tied to them.
  Core: `SupplierAccounts.swift` (tested). App: `Store/Accounts.swift` (payments.json in Application Support, in backups).
- Trusted suppliers: scanning reads the total only (`InvoiceDraft.totalOnly`, `HistoryEntry.totalOnly`), no price check.
- Weekly payment reminder (Suppliers › Weekly payment day).
- Widget (`Widget/`): reads `widget.json` from the app group. Live app group: group.com.rjapps.invoicepricechecker,
  beta: group.com.rjapps.invoicepricechecker.beta. Codemagic leaves the widget out until `ChargeCheckSwift/.widget-ready` exists
  (the App Group must first be made on developer.apple.com and ticked on the app's and the widget's App IDs).
  Before the live release: do the same for com.rjapps.invoicepricechecker and com.rjapps.invoicepricechecker.widget.
- PDFs made by a computer are read from their own text (exact). iOS 26: Apple's table reader is tried and used when its
  lines fit the printed total better. Invoices can be opened from WhatsApp, Mail or Files ("Open in ChargeCheck").

## Improvements from /improve-system (11 Nov 2026)
- [x] To pay: "Including VAT / Before VAT" switch (shops that aren't VAT registered), split shown, breakdown follows it
- [x] Credits per invoice: asked for → received, reminder after 14 days, totals on Reports (old app's data format)
- [x] Optional lock with Face ID / Touch ID / passcode (Settings). The lock is its own window, so it also covers open sheets
- [x] Faster scans: both reads of the photo and the table reader run at the same time; Apple Intelligence only checks
      lines that need it (no clear match, reads differed, or a misread-looking name)
- [x] Settings › How invoices are read: read each photo once (faster) or twice; Apple Intelligence switch,
      shown off and never used on an iPhone that can't run it
- [x] Item names in any alphabet match: Arabic / Kurdish letter variants and digits, accents (é, ü, ß), Arabic "ال"
- [x] Siri / Spotlight / Shortcuts: "Check an invoice" opens the camera scanner
- [x] Photo tips when nothing could be read (too dark / blurry); scan given back if no product lines at all
- [x] Subscription checked again whenever the app comes back to the front
- [ ] Try on a real phone: Face ID lock, Siri phrase, credit reminder notification

## Before going live – must remove
- "Test: add 5 free scans" button (Settings, test builds only; `Store.addTestScans`). Added 11 Nov 2026 at Ramyar's request for his own testing.
- Switch `CCTestBuild` to false (also hides the test-mode switch and uses real ads).

## Left out on purpose
- Licence keys: not needed in the Swift app (Ramyar, 11 Nov 2026). App Store plans, scan packs and ads only.

## Working together (two Claude chats work on this app)

Ramyar runs two chats on this code. They can't see each other, so this section is how they stay in step.
**Read it before starting, and update "Now working on" when you start and finish.**

- **Features chat**: new features (payments, suppliers, delivery check, credit notes, tips, summaries).
- **Review chat** (`/improve-system`): reviews, bug fixes, speed, reading/matching accuracy, settings for how invoices are read,
  and **sending beta builds**.

Rules for both:
1. **Only the review chat sends beta builds** (changes `ChargeCheckSwift/.beta-build`). The features chat tells Ramyar
   "ready for a build" instead. This stops a build picking up half-finished work.
2. **Never push to `swift-rewrite` while its cloud check is red or still running from your own last push.** Push work that
   builds; fix a red check before anything else.
3. **Work on your own branch** (`feature/...` or `improve/...`), bring in the latest `swift-rewrite` (merge it into your
   branch) before asking Ramyar to merge, and keep changes small.
4. **Stay out of the other chat's files where you can.** If you must change them, say so in "Now working on".
5. **`Localizable.xcstrings`**: only add keys, keep them sorted, never reformat the file. On a conflict keep both sides' keys.
6. The rules at the bottom of this file apply to both chats.

### The plan (12 Nov 2026) – who does what

Tick an item when it is merged and the cloud check is green. Don't start an item on the other chat's list.

**Review chat** (reading, speed, accuracy, getting ready for the App Store)
- [x] R1. Settings › How invoices are read: read each photo once or twice, Apple Intelligence on/off (pull request #7, built)
- [x] R2. Pack-size warning: flag a line when the size on the invoice differs from the matched item ("5kg" vs "10kg"),
      so a smaller pack at the same price is caught as an overcharge
- [x] R9. Learn the names suppliers use: a new name for an item the app is sure about is saved with the item
      (Settings switch; `PriceTools.newNames`) – Ramyar's request, 12 Nov
- [ ] R3. Fast with big price lists: prepare the price list once per scan instead of once per line; keep search quick at 2,000+ items
- [ ] R4. Excel (.xlsx) price-list import, next to the CSV import
- [ ] R5. Free scan when no ad can load (for example up to 3 a day) – **only after Ramyar says yes**
- [ ] R6. Arabic invoices: test real ones, fix what the reader gets wrong; right-to-left layout check of every screen
- [ ] R7. Accessibility: large text and VoiceOver labels on Check, Reports and the paywall
- [ ] R8. App Store release checklist: test mode off, test button removed, product IDs checked against App Store Connect,
      privacy label text, new screenshots, Arabic listing text – **switching the live app needs Ramyar's yes**

**Features chat** (new things the app can do)
- [ ] F1. Keep the cloud check green after the payments / delivery check / credit notes work
- [ ] F2. Special prices per supplier: a screen to see and edit them (the data is already there)
- [ ] F3. Price-rise alerts: "this supplier put X up by 8% since last time", with a list of recent rises per supplier
- [ ] F4. Compare shops: spend, overcharges and credits per shop side by side (Ramyar has many shops)
- [ ] F5. Supplier statement check: scan a monthly statement and tick it off against the invoices in Reports
- [ ] F6. Accountant pack: one export per month with the PDF report plus a CSV of every invoice and payment
- [ ] F7. First-run guide: three short screens showing scan → check → what to pay, with the sample invoice
- [ ] F8. Home-screen widget: amount to pay and credits still owed

### Now working on
- Review chat (12 Nov 2026): R1, R2 and name learning are merged and in beta build 11. Next: R3 (fast with big price lists).
  Sends the beta builds.
- Features chat (12 Nov 2026): on F4 (branch `feature/f4-compare-shops`, built on F3's). Adds one "Compare shops" link
  to `ReportsView.swift`. F1 = PR #9, F2 = #15, F3 = #16. Ramyar: features chat does F3–F5 only, then waits; the review
  chat has F6–F8.

### Later (features chat, after F1–F8, only when Ramyar asks)
- Staff phones share the shops' data through iCloud (owner invites staff). Needs Ramyar's Apple setup: iCloud container
  `iCloud.com.rjapps.invoicepricechecker.beta` on the beta App ID.
- Receipt photos and supplier payments in every backup (backup file + iCloud folder).
- Payment reminders per supplier ("pay Apex every Friday").
- On hold (Ramyar): staff clock in/out with an NFC tag.
- The widget (F8) needs the App Group on developer.apple.com first: `group.com.rjapps.invoicepricechecker.beta`, ticked on
  the beta App ID and on a widget App ID `com.rjapps.invoicepricechecker.beta.widget`. Then create `ChargeCheckSwift/.widget-ready`.

## Rules

- ChargeCheck Beta (TestFlight) builds: go ahead without asking (Ramyar, 11 Nov 2026).
- Never send the Swift version to the App Store (the live app) until Ramyar says yes.
- Do not change prices, products, trial length, ad frequency or AdMob IDs without asking.
- No phone number anywhere. Contact is email only.
