# ChargeCheck – moving to native Swift

> **Read `STANDARDS.md` first.** It is Ramyar's master product, engineering and quality standard (14 Nov 2026) and applies to every change.

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

## Audit fixes (14 Nov 2026, Ramyar approved; audit report in his Claude Docs)
- **Shops kept apart.** One shop choice for the whole app (`LiveSettings.shop`, saved as `shops.view`; "" = All shops),
  switched from the top bar of Home, Invoices, Suppliers and Reports or in More › Your shops. Home, invoice lists,
  suppliers and balances, payments, due dates, price rises, monthly summary, exports and the widget all follow it.
  Choosing a shop also files new invoices under it. Payments now have `shopId`; ticked-invoice payments take their
  invoices' shop. Payments recorded before this (no shop, not tied to one shop's invoices) only count under All shops,
  and Suppliers says so. Compare shops still shows every shop. Core: `ShopFilter` (tested).
- **Changes show straight away.** `Money.format` calls `Money.willFormat`, which the app points at
  `LiveSettings.moneyStamp` (Observation), so every screen showing an amount redraws when the currency or a supplier's
  currency changes. The shop choice works the same way.
- **Duplicate invoices are asked about, never replaced silently.** `AppData.possibleDuplicate` + "Already in your
  invoices?" on the invoice: same invoice (updates the saved one) or "billed twice" (both kept, the second has
  `duplicateOf` and shows under Home › Needs attention › Billed twice until paid or the warning is removed).
  Invoices of two different shops are never treated as the same invoice.
- **Undo paid keeps history.** `SupplierAccounts.undoPaid` takes back exactly what was paid per invoice at the time
  (`invoiceAmounts`, saved with new ticked-invoice payments); every payment as it was goes to Recently deleted.
- **Storage safety.** If the saved data can't be opened (`AppStorageSetup.failed`) the app says so at once, and no
  automatic backup, iCloud folder copy, restore or staff sync runs, so temporary data never replaces real data.
  Restoring a backup first keeps `Backups/Before-restore-….json` (last 5).
- **Currency.** Chosen once and kept (`Regional.settleCurrency`): a phone that already had ChargeCheck data starts in
  pounds, a new install from the iPhone's region; changing the region no longer changes it. Changing it in Settings
  asks first when there is data. "Ignore differences up to" offers choices that suit the currency (IQD: 1, 250, 500,
  1,000). New invoices and payments save their currency (`currency`). The printed-total check allows VAT rounding on
  long invoices and whole dinars (`InvoiceMaths.totalAllowance`).
- Not done on purpose: a SwiftData `VersionedSchema`. The stored models haven't changed, and adding one without a
  real-phone upgrade test could stop existing data opening. Add it together with the first real model change.
- **Staff sharing taken out (Ramyar, 14 Nov 2026: "not needed").** `CloudTeam.enabled = false`, the Staff row is gone
  from More, the plans screen no longer offers it, and the iCloud/push entitlements are out of `project.yml` (the app no
  longer asks for iCloud). A phone that had started or joined sharing in an earlier beta just stops; its data stays on
  the phone and nothing in iCloud is touched. The code (`Sharing/`, `Core/TeamSync.swift`) is kept in case it comes back
  as a properly designed feature.
- **Cheaper prices are suggested, not applied (Ramyar, 14 Nov 2026).** When a fully checked invoice is cheaper than
  an agreed price, "Cheaper on this invoice" asks "Update my price" / "Keep my price"; nothing changes until Update.
  Settings: "Suggest a lower price when an invoice is cheaper" (same `prices.autoLower` setting, on by default).
- **Half pennies round up every time (Ramyar, 14 Nov 2026).** `Money.round2` used to lose a penny on about 1 in 22
  half-penny amounts (0.25 kg × £16.74 = £4.185 gave £4.18) and rounded minus amounts differently from plus amounts.
  Now a value within a hair of a half penny is rounded away from zero; everything else rounds as before; no "-0".
  Checked against whole-number maths: every half penny to £2,000, ~770,000 weighed lines and line totals (core tests
  `MoneyRoundingTests`). Saved invoices keep their amounts; the duplicate check allows a penny so an invoice saved
  before this still matches. Still `Double`, not `Decimal` – moving to exact decimals remains on the roadmap.
- **Each shop its own items and prices; the app works out an invoice's shop (Ramyar, 14 Nov 2026).** Shops can be
  different trades (food, a pharmacy). One price list; each item can be tagged with the shops that buy it
  (`PriceItem.shops`, nil = every shop, so all older items are in every shop) and given a shop's own price
  (`shopPrices`). Prices › the item › Shops. Prices follows the shop being viewed; new items (typed, pasted, or added
  from an invoice) belong to that shop. Each invoice is checked against its shop's price (`PriceBook(items, shop:)`,
  supplier's own price still first). After reading, `ShopDetect.guess` uses shop-only items on the invoice and where
  the supplier's earlier invoices went: sure → filed under that shop with "Its items are on the price list of …";
  unsure or Settings › "Invoices for another shop: Ask me first" → "Which shop is this for?" and nothing is saved
  until answered. The invoice has a Shop picker. Stored without a database change: an item's shops and shop prices
  ride in `StoredPrice.supplierPrices` (old form kept for items without shops). Core tests: `ShopPriceTests`.
- **Select several (14 Nov 2026):** Checked invoices (Select) and Prices (••• › Select items): tick rows or Select all,
  then Delete (to Recently deleted) or Move to shop. Moving invoices also moves payments made for exactly those invoices
  (`Accounts.moveInvoices`). Price items can be moved to one shop, added to another, or set to all shops.
  Also (Ramyar couldn't find it, beta 27): "Select" in the header of Invoices › Checked invoices (opens the list in
  select mode) and of a supplier's Still to pay / Paid invoices. "Move to shop" is always shown; with no shops (or
  one) it offers "Add your shops" (Your shops in a sheet). The Invoices tab's recent list now follows the chosen shop.
- **App Store screenshots:** commit message `[shots]` runs the "App Store screenshots" job: largest iPhone, realistic
  data from `tools/make-store-data.py` (dates relative to today), clean status bar, en/ar/de/fr; pictures land in
  `store/` on the ci-logs branch. `-storeShots YES` hides the sample-invoice note.
- **Scan from Home asks where from (14 Nov 2026):** Camera, Camera roll or Files (PDF or photo). Home sets
  `CheckSession.scanRequest` (`ScanSource`) and switches to Invoices, which opens that picker through `gated {}`.
- **Fixed: tapping a checked invoice on the Invoices tab did nothing.** Its path was `[String]`, which silently drops
  `ReportLink`; it is a `NavigationPath` now.
- **No separate business name any more.** The Settings field is gone; reports, credit requests and PDFs are named by
  `Shops.reportName(shopId)`: the invoice's shop, else the shop being viewed, else the filing shop, else the old saved
  business name.

## Before going live – must remove
- "Test: add 5 free scans" button (Settings, test builds only; `Store.addTestScans`). Added 11 Nov 2026 at Ramyar's request for his own testing.
- Switch `CCTestBuild` to false (also hides the test-mode switch and uses real ads).

## Left out on purpose
- Licence keys: not needed in the Swift app (Ramyar, 11 Nov 2026). App Store plans, scan packs and ads only.

## Working together (two Claude chats work on this app)

> **From 12 Nov 2026 (evening): ONE chat only.** Ramyar stopped the review chat. The former features chat now does everything:
> features, fixes, reviews and beta builds. The two-chat rules below are kept for history. What still applies: push only work
> that passes the cloud check, never touch `main` (the live app) without Ramyar's yes, `Localizable.xcstrings` add-only.
> The review chat's open items (R3–R8, F6–F8) are now this chat's.

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
7. **Merging (Ramyar, 12 Nov 2026):** the review chat may merge pull requests into `swift-rewrite` without asking when the
   cloud check on the latest commit is green. Never into `main` (the live app) without Ramyar's yes each time.

### The plan (12 Nov 2026) – who does what

Tick an item when it is merged and the cloud check is green. Don't start an item on the other chat's list.

**Review chat** (reading, speed, accuracy, getting ready for the App Store)
- [x] R1. Settings › How invoices are read: read each photo once or twice, Apple Intelligence on/off (pull request #7, built)
- [x] R2. Pack-size warning: flag a line when the size on the invoice differs from the matched item ("5kg" vs "10kg"),
      so a smaller pack at the same price is caught as an overcharge
- [x] R9. Learn the names suppliers use: a new name for an item the app is sure about is saved with the item
      (Settings switch; `PriceTools.newNames`) – Ramyar's request, 12 Nov
- [x] R3. Fast with big price lists: prepare the price list once per scan instead of once per line; keep search quick at 2,000+ items
- [ ] R4. Excel (.xlsx) price-list import, next to the CSV import
- [ ] R5. Free scan when no ad can load (for example up to 3 a day) – **only after Ramyar says yes**
- [ ] R6. Arabic invoices: test real ones, fix what the reader gets wrong; right-to-left layout check of every screen
- [ ] R7. Accessibility: large text and VoiceOver labels on Check, Reports and the paywall
- [ ] R8. App Store release checklist: test mode off, test button removed, product IDs checked against App Store Connect,
      privacy label text, new screenshots, Arabic listing text – **switching the live app needs Ramyar's yes**

**Features chat** (new things the app can do)
- [x] F1. Keep the cloud check green after the payments / delivery check / credit notes work
- [x] F2. Special prices per supplier: a screen to see and edit them (the data is already there)
- [x] F3. Price-rise alerts: "this supplier put X up by 8% since last time", with a list of recent rises per supplier
- [x] F4. Compare shops: spend, overcharges and credits per shop side by side (Ramyar has many shops)
- [x] F5. Supplier statement check: scan a monthly statement and tick it off against the invoices in Reports
- [ ] F6. Accountant pack: one export per month with the PDF report plus a CSV of every invoice and payment
- [ ] F7. First-run guide: three short screens showing scan → check → what to pay, with the sample invoice
- [ ] F8. Home-screen widget: amount to pay and credits still owed

### Now working on
- Single chat (14 Nov 2026), Ramyar's review list: five tabs (Home · Invoices · Suppliers · Reports · More), Home overview
  (owed, spent, caught, money leaks, money protected, needs attention), search everything, Pay within + due dates,
  Recently deleted (30 days) + history of changes, supplier profiles + score + supplier report PDF, right-to-left PDFs,
  unsure lines shaded amber with the printed text and the overcharge sum, a currency per supplier (never added to your own).
- Next (Ramyar said yes, 14 Nov): Free / Scan packs / Pro split. Free = check with one ad per scan, last 30 days.
  Any pack bought = no ads, full history, PDFs/exports, delivery + statement check. Pro = unlimited + money leaks,
  price rises, cheaper elsewhere, scores, due dates/pay run, several shops, staff, widget, Apple Intelligence, history.
  Locked items stay visible with a Pro tag. Existing subscribers keep everything.

### Apple setup done (Ramyar, 12 Nov 2026)
On developer.apple.com: App Group `group.com.rjapps.invoicepricechecker.beta` and iCloud container
`iCloud.com.rjapps.invoicepricechecker.beta` are ticked on the ChargeCheck Beta App ID, and the widget App ID
`com.rjapps.invoicepricechecker.beta.widget` has the same App Group. The widget (F8, review chat) can now be switched on by
creating `ChargeCheckSwift/.widget-ready`; Codemagic then builds and signs it.

### Staff phones (features chat, 12 Nov 2026)
- **(Out of date – it is switched on again, see "Audit fixes" above.) Switched off since beta 16 (`CloudTeam.enabled = false`).** The launch crash turned out NOT to be the sync engine (see "Now
  working on": SwiftData + iCloud entitlement). Sharing itself is still untested on a phone. Before turning it back on: add the
  push entitlement (`aps-environment`) and `remote-notification` background mode (Ramyar ticks Push Notifications on the beta
  App ID first), and the CloudKit record type `Item` must exist in Production. The start guard (`team.starting`) stays.
- The owner turns on sharing in Settings › Staff; the whole business (reports, prices, payments, business name, shops, trusted
  suppliers) goes into a zone "Business" in the owner's private iCloud and is shared with staff (zone-wide `CKShare`).
  Staff join through the invite link (`TeamSceneDelegate`). `CKSyncEngine` sends and fetches; each record holds the same
  JSON as the backup file (`Core/TeamSync.swift`, tested). Syncs when the app opens, on pull-to-refresh, and after changes.
- Staff phones send only reports; they hide the Prices tab, payments, special prices, the trusted switch and the
  owner-only Settings sections. Joining or leaving clears the staff phone's own data (never iCloud's).
- Safety: a phone whose data suddenly looks empty never passes that on as deleting everyone's records.
- TestFlight builds are signed for distribution, so they use the **Production** iCloud (corrected 12 Nov; "Development" can't
  be used). Production doesn't create record types by itself: in the CloudKit Console (icloud.developer.apple.com), container
  `iCloud.com.rjapps.invoicepricechecker.beta`, Development: add record type `Item` with fields `kind` (String) and `data`
  (Bytes), then "Deploy Schema Changes" to Production. Until then sharing shows an iCloud error and nothing syncs.
  Same again for the live container before the live release.
- **If a beta build fails at signing because of iCloud:** create `ChargeCheckSwift/.no-icloud` (Codemagic then leaves the
  iCloud lines out) and tell the features chat.
- Not tested on real phones yet; the cloud check can't use iCloud. First test: Ramyar's phone + one staff phone.

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

## Suggest other names; swipe to pay or delete an invoice (beta 28)
- Price item editor › Other names on invoices › "Suggest other names": likely supplier spellings (no pack size,
  product code on its own, common shorthand such as qtr/pdr/chkn/veg), tap one or "Add all". Core `NameIdeas`;
  a name is never offered if it could also be read as another item (same rule as the matcher, shorthand read
  as the full word), so it can't cause new "which item?" questions. Matching ignores word order already.
  `Matcher.aliasFits` is the one shared rule. No data change: names go into the existing aliases.
- Every invoice list (Invoices tab, All checked invoices, a supplier's Still to pay / Paid): swipe right to pay
  (asks once with the amount, then `Accounts.markPaid`), on a paid one swipe right for "Unpaid"
  (`markUnpaid`); swipe left to delete (Recently deleted keeps it 30 days).

## Automatic iCloud backup, compressed photos (beta 29)
- iCloud Drive › ChargeCheck is used automatically (no folder to pick) when the phone is signed in to iCloud:
  `AutoCloud` finds the app's ubiquity container off the main thread. A folder the user picked still wins.
  Settings › iCloud backup › "Save to iCloud automatically" can turn it off.
- Entitlements (project.yml, lines tagged `# icloud`): iCloud container + ubiquity container, service CloudDocuments
  only (no CloudKit: the SwiftData store stays local, `cloudKitDatabase: .none`). NSUbiquitousContainers names the
  folder "ChargeCheck". Beta uses iCloud.com.rjapps.invoicepricechecker.beta (codemagic sed).
- Codemagic step "iCloud Drive in the beta profile?": if the profile has no container, the `# icloud` lines are
  dropped and the beta is built without automatic iCloud (no failed build). LIVE APP: the live App ID needs the
  iCloud capability with container iCloud.com.rjapps.invoicepricechecker before release.
- New invoice copies: long side 1800 px, JPEG 0.6 (was 2200 px, 0.85), about a quarter of the size; multi-page
  PDFs hold the compressed pages. Older copies on the phone are not touched; their cloud copy is compressed if
  over 700 KB (`CloudCopies.catchUp`, 40 per backup, remembers what was sent per folder).
- Cloud keeps 30 daily backups (`CloudFolder.trim`). New or reinstalled phone with nothing saved: offers once to
  restore the iCloud backup (RootView). Invoices tab warns when not backed up to iCloud, or no backup there for 7 days.

## Credits written off, payment reminders, whole-list names, Xero/QuickBooks, PDF price lists, cost per dish (beta 29)
- `CreditInfo.writtenOff` ("writtenOff"): a credit the supplier refused. Not owed, not counted as won back.
  Credits owed › swipe "Write off"; on the invoice "They won't credit it"; undo with "Still owed after all".
  Money protected › "Credits you asked for": received / still owed / written off (main currency only).
  Older app versions see the status as neither owed nor received.
- Settings › "Payments due reminders" (off by default, asks for notifications): 9 am on each day something is due,
  next 14 days, planned again on every change (`DueReminders.plan` in core, `DueReminder` in Files.swift).
- Prices › More › "Suggest other names": `NameSuggestionsView`, up to 4 per item, all ticked, same safety rule.
- Reports › Export › "For your accounting software": `AccountingExport.xeroBills` (Xero's exact bill import
  columns, DD/MM/YYYY, tax exclusive, expense account default 310) and `quickBooksBills`. Each invoice as issued
  (net + VAT); what was caught goes in the description; invoices billed twice are left out.
- Paste a price list › "Open a price list (PDF, CSV or text)": a PDF's text (PDFKit) goes into the existing parser
  for review. A scanned PDF (no text) says so.
- Cost per dish (More › Cost per dish, and Prices › More): `Dish`/`DishPart`/`DishMaths`/`PackGuess` in core,
  `DishStore` keeps them in UserDefaults "dishes.v1". Backups carry `dishes` (older backups/apps ignore it).
  Cost = agreed price (shop's own, else supplier's own, else standard) ÷ pack × uses; food cost % of price without VAT.
  Free for everyone for now: whether it is part of Pro is Ramyar's call.

