# Engineering backlog — progress (where we left off)

Source: `docs/ENGINEERING_BACKLOG.pdf` (Ramyar, 21 Nov 2026). One task at a time, in order. Each task: inspect,
tests first, smallest safe change, Core tests + cloud app build green, merge to swift-rewrite, beta, note here.

Status: ⬜ not started · 🟡 in progress · ✅ done · ⏸ needs Ramyar's decision

| Task | What | Status | Notes |
|---|---|---|---|
| CC-001 | Production build guard (P0) | ✅ | project.yml test mode off; beta turns it on; tools/release_guard.py on every push + after release archive |
| CC-002 | PIN credential migration (P0) | ✅ | salted PBKDF2 v2, upgrade on sign-in, Reset PIN; simulator-tested |
| CC-003 | Permission enforcement audit (P0) | ✅ | store enforces refunds, cash, close day, layaways (part 1) and spends the yes for basket changes: discount, price, custom amount, removing lines, gift cards, tabs (part 2); PIN lockout |
| CC-004 | Persistence error model (P0) | ✅ | SaveHealth (Core) + SaveWatch banner; 19 database saves + phone/iCloud writes report |
| CC-005 | Transactional backup restore (P0) | ✅ | BackupValidation first; delete + insert in one save, rollback on failure; the rest only after |
| CC-006 | Payment domain state machine (P0) | 🟡 | Core Payments.swift: attempts, states, idempotency key, refunds, split summary; tests |
| CC-007 | External terminal manual tender (P0) | 🟡 | card parts record machine, confirmed-by, approval code, verified=false; shown in sale details |
| CC-008 | Provider adapter + fake provider (P0) | 🟡 | Ramyar: ALL providers (Stripe Terminal, Square, SumUp, Adyen, Tap to Pay on iPhone) behind one adapter; each goes live only with his merchant account + keys; Tap to Pay needs Apple entitlement |
| CC-009 | Payment recovery / idempotency (P0) | 🟡 | PaymentRunner: save first, timeout → unknown → status check, recoverAll on launch; FileAttemptStore |
| CC-010 | Refund integration (P0) | 🟡 | refunds go back the way the sale was paid (card first), capped per way, linked to the original card payment |
| CC-011 | Durable sync outbox (P0) | 🟡 | SyncOutbox (Core) + CloudOutbox: failed iCloud writes retried 30 s → 1 h, survives restarts |
| CC-012 | Sync conflict policy (P0) | 🟡 | sales/cash/refunds append-only per till (already); gift card double-spend found and shown |
| CC-013 | Cloud file integrity (P1) | 🟡 | incoming sales files checked (whole, never shrinking) before replacing ours; bad ones quarantined + banner |
| CC-014 | Inventory movement ledger (P1) | 🟡 | InventoryLedger: movements from counts/invoices/sales/refunds, on hand = StockMaths; Stock › Movements |
| CC-015 | Purchase orders + receiving (P1) | 🟡 | orders can arrive in parts: several invoices per order, received/outstanding per line, status |
| CC-016 | Recipe and ingredient costing (P1) | 🟡 | Core Recipes (units, waste, yield, versions, consumption); Till › Recipes editor; sale cost from the recipe |
| CC-017 | Kitchen display MVP (P1) | 🟡 | Ramyar 21 Nov: yes — restaurant kitchen screens and the rest of hospitality (tables, courses, tips, kitchen printers) |
| CC-018 | Retail operations polish (P1) | 🟡 | transfers in transit (sent → received, shortages), stocktake sessions with variance at cost |
| CC-019 | Profit reporting (P1) | 🟡 | COGS, costed net, coverage %, margin; low-margin alerts; hand-checked fixture test |
| CC-020 | Web owner dashboard/backend design (P1) | ⏸ | Design doc only; server is a paid service |
| CC-021 | Hardware test and print queue (P1) | ⬜ | Device sign-off needs real hardware |
| CC-022 | Localization/accessibility audit (P1) | ⬜ | |
| CC-023 | App Store and privacy readiness (P0) | ⬜ | Sign-off by Ramyar |
| CC-024 | Operational monitoring/support (P1) | ⬜ | |

## Log
- 21 Nov — CC-001 started. Found: `CCTestBuild: true` was committed for every build (App Store too). Now false in
  project.yml; Codemagic swift-beta sets it true; `tools/release_guard.py` checks project.yml on every push (Core tests
  job) and the archived app's Info.plist in the Release build job (`[archive]`). Checks: test mode, beta bundle ID/name,
  Google test ad IDs. Note: the old `ios-app-store` Codemagic workflow is the legacy app; a Swift App Store workflow
  must run the guard too (CC-023).
- 21 Nov — CC-002 started. `PinCredentials` (Core: format, check, upgrade, Arabic digits, own SHA-256 for old
  fingerprints) + `TillPins` (app: CommonCrypto PBKDF2-HMAC-SHA256, 100k rounds, 16-byte SecRandom salt).
  `Cashier.pin` added (optional, old files still load); `pinHash` emptied after the upgrade on the next right PIN.
  Reset PIN: touch and hold a person in Till settings. Limits: a 4-digit PIN stays guessable from a copied file
  (10,000 options) — hashing only slows it; a till app older than this can't sign in people whose PIN was upgraded,
  so update every till. Not yet: wrong-PIN lockout (do with CC-003).
- 21 Nov — CC-003 inspected (not started). Permissions (`TillPermission`: refund, discount, priceChange, customAmount,
  removeLine, cashIn, cashOut, float, noSale, closeDay, giftCard, tab, settings) are only checked in views via
  `Gate.check` (TillView, SalesViews, TillMoreViews, TillSettingsViews) and `ManagerOnly` (TillTabView). TillStore's
  mutators don't check. Plan: TillStore issues an `Approval` (permission, by, reason, at) only when `may()` or a
  manager PIN allows; every committed privileged mutation (refund, cash events, close day, gift card, layaway cancel,
  tab, settings) takes it and records actor + reason; cart-only edits (discount, removeLine, customAmount,
  priceChange) carry the approval onto the sale line. Add wrong-PIN lockout. Tests: Tests/TillPermissionTests.swift.
- 21 Nov — CC-001 ✅ (release archive built with the guard: OK). CC-002 ✅: Core PinCredentialTests and simulator
  TillPinTests (real PBKDF2 matches the RFC test value) pass. Not yet tested on a real iPhone or iPad.
- Found, pre-existing (P1): the StoreKit purchase tests (`[store]`) are broken on swift-rewrite before these changes:
  `testBuyingPacksAddsScansOnce` hangs 5 min (also on an unchanged baseline run, branch improve/store-baseline);
  `testSubscribingUnlocksAndExpiryLocks` sometimes doesn't see the expiry. Purchases aren't changed by the backlog
  so far; fix the tests before any StoreKit change (ask Ramyar before changing the purchase flow).
- 21 Nov — Ramyar's decisions: use all card companies (one adapter per provider, fake provider for tests, manual
  external-terminal tender works for all); yes to restaurant kitchen screens and hospitality.
- 21 Nov — CC-003 in progress (branch improve/2026-11-21-cc003). Core `TillApprovals` (single-use yes per
  permission, 2 min), `PinLockout` (5 free tries, then 30 s doubling to 5 min), `CashEvent.Kind.permission`.
  TillStore: `approve(_:pin:)`, `approveAsDeviceOwner`, `authorize(_:)`; refund, addCash (float, paid in/out,
  no sale), closeDay (now returns nil when refused) and layaway cancel check it, and record who said yes from the
  store, not the screen. Tests: TillAuthorityTests (Core), TillPermissionTests (simulator, `[store]` runs).
  Still to do in CC-003: sale-level permissions (discount, price change, custom amount, remove line, gift card,
  tab) are still applied on the screen only — enforce in `record()` by passing the approval with the sale lines;
  settings changes (roles, people, permissions) behind ManagerOnly only; the lockout resets if the app restarts.
- 21 Nov — WHERE WE LEFT OFF: CC-003 part 1 is on PR #61 (branch improve/2026-11-21-cc003), NOT merged. Core tests
  green; app builds; TillPermissionTests + TillPinTests pass on the simulator. The `[store]` run is red only because
  StoreKit purchase tests hang/fail against Apple's test server (testBuyingPacksAddsScansOnce always — skipped in
  this branch; testMonthlyPlan and the expiry check sometimes). Waiting for Ramyar: make purchase tests non-blocking
  until fixed, or fix them first. Then merge #61, beta, and continue CC-003 part 2 (sale-level permissions in
  `record()`, settings changes, lockout kept across restarts).
- 21 Nov — Ramyar: fix the purchase tests first (test code only). StoreTests now buy through
  `SKTestSession.buyProduct` (no purchase sheet) and wait up to 30 s for the store's own handle/refresh; the skip
  of testBuyingPacksAddsScansOnce is removed; all purchase tests block again. `Store.buy()` (the sheet itself) is
  then only checked by hand in TestFlight's sandbox.
- 21 Nov — WHERE WE LEFT OFF (purchase tests): with buyProduct the store never sees the test purchases, and
  testProductsAndTrial saw the yearly plan at 99.99 although Tests/Products.storekit says 89.99. So on the cloud
  simulator (Xcode 27 / iOS 27) the SKTestSession doesn't take hold: StoreKit answers from elsewhere (most likely
  Apple's sandbox). Next: confirm which (log `Product.displayPrice` + `AppStore.environment` in setUp); try the
  session before the host app's Store.shared starts (it loads products at launch), or an app-less StoreKit test
  target; or pin the runner to Xcode 26.x for these tests only. Ask Ramyar: is the real yearly price £89.99 or
  £99.99? PR #61 (CC-003 part 1) stays unmerged until the purchase tests pass.
- 21 Nov — Ramyar: the real yearly price is £89.99, and the plans/packs aren't in App Store Connect for the Swift
  app yet (he'll have me add them when he has a PC). Likely cause of the test trouble: the app (the test host)
  started its own StoreKit at launch, before the test session. Now `Store.start()` does nothing under XCTest, and
  StoreTests pin the session to GBR / en_GB.
- 21 Nov — purchase tests: the failing runs showed storefront GBR but "$99.99" yearly, $9.99 monthly, 7-day
  trial — none of that is in Products.storekit (ever), so StoreKit answered from Apple's sandbox (probably the live
  app's old plans, same bundle ID). Fix tried: erase the simulator before `[store]` tests (the screenshot run before
  them talks to the sandbox) and skip the launch refresh in RootView when hosting tests (`Store.hostingTests`).
- 21 Nov — fresh simulator didn't help: purchases land in the local test store but the app reads the sandbox.
  Now `storeKitConfiguration: Tests/Products.storekit` on the app's scheme (Xcode-run only). CC-003 part 2: `Gate`
  spends the store's yes for basket changes the moment they're made (`Gate.basketChanges`); changeLine uses it.
  Not yet: settings changes (roles, people, permissions) still guarded by ManagerOnly only; lockout resets on
  restart; supervisor role.
- 21 Nov — WHERE WE LEFT OFF: the scheme's storeKitConfiguration didn't help either (5th attempt). In every run
  the app reads yearly $99.99 / monthly $9.99 / 7-day trial for ipc_yearly / ipc_monthlyy — real App Store Connect
  data for this bundle ID (the live app), not Products.storekit — while test purchases go to the local test store.
  CC-003 parts 1+2 are complete on PR #61; Core tests green; till and PIN simulator tests (4) pass; only StoreTests
  fail. Waiting for Ramyar's choice on the purchase tests before merging. Ideas not yet tried: a separate test
  target without the app as host; StoreKit tests in Xcode Cloud; checking the plans in App Store Connect.
- 23 Nov — Ramyar approved merging with only the StoreKit purchase tests failing (they need the products in App
  Store Connect; product IDs are now chargecheck_*, PR #62). CC-003 ✅ merged (PR #61). Remaining for later: settings
  changes still behind ManagerOnly only; supervisor role; lockout resets on restart.
- 23 Nov — CC-004: Core `SaveHealth` (a failure stays until that same thing saves; worst first: database, phone,
  iCloud). App `SaveWatch` + `SaveBanner` at the top of every tab; `ModelContext.saveOrReport()` replaces all 19
  `try? context.save()`; AppFiles/CloudFolder writes, the till's JSON, accounts, records, team files and credit
  photos report failures. Still silent on purpose: deleting old backup copies, crash-report files.
- 23 Nov — CC-005: found restore deleted everything and SAVED before adding the backup (a failed add = data
  lost). Now: Core `BackupValidation` refuses newer-format, empty, damaged money (NaN/∞) or ID-less files; the safety copy
  is still made first (Settings); delete + insert in ONE save, `context.rollback()` if it fails; payments, orders,
  budgets, stock counts only after. `AppData.RestoreResult` tells the screen what happened. Not covered yet: the
  other stores' own files (Accounts/Orders/Budgets/Till) aren't rolled back if one of THEM fails — they report via
  SaveWatch instead (CC-013 file integrity).
- 23 Nov — Money in whole pence, slice 1 (Ramyar: "go ahead", pence): `Pence` (Int) + `Sequence.pennySum` in Core;
  51 money totals in Overview, ReportMaths, SupplierAccounts, Insights, SupplierProfile, Till, DueDates,
  StatementCheck, MoneyInsights, DueReminders now add in whole pence (a NaN makes the total NaN, never dropped).
  Per-invoice maths (PayBreakdown) already rounds each step to the penny. Next slices: stored values as pence
  (needs a data migration), PayBreakdown internals, till sale totals.
- 23 Nov — Plan step 5 (Phase 3 preview): Home "Today" card at the top once the till is in use — takings, sales,
  refunds, cash, card (+ other) since the last close (same as the end-of-day report, `TillStore.current`) and
  items running low (shortest first, links to Stock). Core `TodaySummary` + tests. Hidden for staff. Not yet:
  profit (needs reliable costs, CC-019), charts, quick actions beyond the existing scan and till buttons.
- 23 Nov — Ramyar: do all the steps without stopping. CC-006: Core `PaymentAttempt` (created → pending →
  approved/declined/cancelled/failed; timeout → unknown, never a new key; repeats ignored; contradicting final
  answers refused + needsReview; refunds ≤ paid, repeated refund IDs once), `PaymentSummary` for split totals
  (no new card request while one is waiting/unknown). CC-007: SalePayment gains confirmedBy / terminal / verified;
  the till's card and split payments record them; approval code field; sale details show them in orange. Not yet:
  the till doesn't run sales through PaymentAttempt (CC-008/009 wire it with the provider adapter).
- 23 Nov — CC-008/009: Core `PaymentProvider` protocol (no SDKs), `PaymentRunner` (saves the attempt before asking;
  timeout/offline → unknown; `recover` asks status with the same key, never charges again; `recoverAll` for launch;
  refunds capped), `FakePaymentProvider` (approve/decline/cancel/timeout/timeout-but-charged/offline, one charge
  per key), tests for all. App: `App/Payments/CardPayments.swift` — catalog (Tap to Pay, Stripe Terminal, Square,
  SumUp, Adyen: all "not connected", each needs Ramyar's account/keys), `FileAttemptStore` (atomic, protected),
  More › Card payments screen. Not yet (needs a real provider account): the till's live card checkout through the
  runner, and calling recoverAll at launch — both wait for the first connected provider.
- 23 Nov — CC-010: found a card + cash sale's refund was all CASH from the drawer. Now `SaleMaths.refundTenders`
  sends money back the way it was paid: gift/points/accounts in proportion, then card first, cash, other, each
  capped at what it paid minus earlier refunds (the store passes them in); card parts keep the original approval
  code, verified false, confirmedBy = the cashier doing it. Tests: RefundTenderTests. Still: refunds through a
  connected card company use `PaymentRunner.refund` once one is connected; two tills refunding the same sale while
  offline is CC-012.
- 23 Nov — CC-011: Core `SyncOutbox` (backoff 30 s doubling to 1 h, one entry per file, survives restarts);
  `CloudOutbox.send` replaces the till's CloudFolder.write calls; `retryDue` on launch and every minute (sends the
  latest local copy). Health: the CC-004 iCloud banner stays until it goes. CC-012: confirmed sales, cash and
  refunds are append-only per till (each till writes only its own files; merge keeps each sale once). New
  `Overspends.find`: a gift card spent past its balance by two offline tills is listed (Gift cards › Spent twice)
  with sale, till and amount; both sales kept. Not yet: customer store credit / loyalty points overspend, conflict
  UX for products/settings/counts (latest-wins today).
- 23 Nov — CC-013: found other tills' sales files from iCloud were copied over the local copy unchecked (a half
  download could hide a till's sales). Core `FileCheck.sales` (must decode, must still hold every sale we had) and
  `FileCheck.json`; TillStore keeps the good copy, puts the bad one in Documents/Quarantine and shows the iCloud
  banner. Already in place: iCloud placeholders are downloaded and reads are coordinated (CloudFolder.readAll); write
  results are checked (CC-004 + CC-011 outbox). Not yet: the same check on settings/cash/products files; a schema
  version field in the files.
- 23 Nov — CC-014: Core `InventoryLedger.movements` (counted, delivered, sold, refunded; one per source line, so a
  sale or invoice seen twice counts once; duplicates and pre-count history skipped) and `onHand`, proven equal to
  `StockMaths.levels` on 200 random days. Stock › touch and hold › Movements shows the list. Not yet: manual
  adjustments with a reason (stock in / write-off) and transfers between shops as their own movement kinds.
- 23 Nov — CC-015: `PurchaseOrder.moreInvoices` (old orders load; `invoiceIDs` = all), `OrderMaths.receipt` (per line
  ordered/received/outstanding/extra over all deliveries; missing lines deliver nothing, short lines qty − short;
  status notYet/part/received/more). Orders: part-received orders stay in Waiting; details show what's still to come
  and "Match the next delivery's invoice"; invoice variances per delivery unchanged (`compare`). Not yet: pack ↔ unit
  conversion when the order and invoice count differently; cost-price updates from received goods.
- 23 Nov — CC-016: Core `Recipes.swift` — RecipeUnit (g/kg, ml/l, each; no cross-kind), Ingredient (pack size/unit,
  waste %), Recipe (portions, version, from), cost per portion in pence (unpriced ingredients listed, not guessed),
  `version(of:at:)` so old sales keep their version, `consumption` of ingredients from sales (refunds give back).
  App: TillStore keeps recipes per till (append-only versions, merged by ID; saving needs Settings permission);
  Till › Recipes and costing (list with cost and margin, editor); the till costs a sold item from its current recipe
  when every ingredient can be priced. Not yet: ingredient stock deduction in the Stock screen (consumption is
  computed, not yet shown/subtracted), sale-line recipe version stamp (the cost is stamped already).
- 23 Nov — CC-017: Core `Kitchen.swift` — tickets per station from category routing, add-on tickets with only
  new items, status from append-only events (forward-only, explicit recall; same answer in any order; repeats once),
  open list per station, printer text. App `App/Kitchen/`: KitchenStore (per-device file in Kitchen/, merged with
  other devices via iCloud, two days kept), KitchenView (station picker, cards with age, Start → Ready → Collected,
  hold for recall/cancel, refresh every 5 s, screen stays on), settings (on/off, category → station). Till sends
  each completed sale when on. Not yet: tables and open tabs per table, sending before payment (order first, pay
  later), auto-print to a kitchen printer, tips/service charge.
- 23 Nov — CC-019: SalesSummary gains `cogs`, `costedNet`, `coverage` (% of net sales with a known cost);
  `MarginAlerts.find` (items under 30% before VAT at today's cost, losses first). Sales and profit shows net sales,
  cost of goods, "profit covers X% of sales" when not all costed, and a Low margins list. ProfitReportTests
  reconcile a hand-worked day (refund included). Not yet: supplier price-rise alerts tied to margins (Insights has
  price rises separately), date-range export of the profit report.
- 23 Nov — CC-018: Core `Retail.swift` — StockTransfer (leaves when sent, arrives when received with the real
  amount; merge: arrived wins), Stocktake (expected vs counted, variances at cost, net). TillStore: `move` now
  creates a transfer (no instant arrival), `receive`, `commit` (all counts at once); Transfers file per till.
  Stock: "On the way" (tap to receive), Stocktake screen. Already there: variants, scale barcodes, refunds.
  Not yet: exchanges as one transaction (refund + new sale), scale configuration profiles.
