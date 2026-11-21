# Engineering backlog — progress (where we left off)

Source: `docs/ENGINEERING_BACKLOG.pdf` (Ramyar, 21 Nov 2026). One task at a time, in order. Each task: inspect,
tests first, smallest safe change, Core tests + cloud app build green, merge to swift-rewrite, beta, note here.

Status: ⬜ not started · 🟡 in progress · ✅ done · ⏸ needs Ramyar's decision

| Task | What | Status | Notes |
|---|---|---|---|
| CC-001 | Production build guard (P0) | ✅ | project.yml test mode off; beta turns it on; tools/release_guard.py on every push + after release archive |
| CC-002 | PIN credential migration (P0) | ✅ | salted PBKDF2 v2, upgrade on sign-in, Reset PIN; simulator-tested |
| CC-003 | Permission enforcement audit (P0) | ⬜ | |
| CC-004 | Persistence error model (P0) | ⬜ | |
| CC-005 | Transactional backup restore (P0) | ⬜ | |
| CC-006 | Payment domain state machine (P0) | ⬜ | Core only, no provider |
| CC-007 | External terminal manual tender (P0) | ⬜ | |
| CC-008 | Provider adapter + fake provider (P0) | ⬜ | Real provider ⏸ (which card company) |
| CC-009 | Payment recovery / idempotency (P0) | ⬜ | |
| CC-010 | Refund integration (P0) | ⬜ | |
| CC-011 | Durable sync outbox (P0) | ⬜ | |
| CC-012 | Sync conflict policy (P0) | ⬜ | |
| CC-013 | Cloud file integrity (P1) | ⬜ | |
| CC-014 | Inventory movement ledger (P1) | ⬜ | |
| CC-015 | Purchase orders + receiving (P1) | ⬜ | |
| CC-016 | Recipe and ingredient costing (P1) | ⬜ | |
| CC-017 | Kitchen display MVP (P1) | ⏸ | Hospitality decision still open |
| CC-018 | Retail operations polish (P1) | ⬜ | |
| CC-019 | Profit reporting (P1) | ⬜ | |
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
- NEXT: CC-003 (see the CC-003 note above).
