# App Store release checklist (CC-023)

Checked 23 Nov 2026 against the code. ✅ done in code · ⏳ needs doing · 👤 needs Ramyar (sign-off at the end).

## Build and settings
- ✅ Test mode (test ads, test-as-free, unlock-everything) is off in releases; `tools/release_guard.py` fails any
  release archive that has it, the beta bundle ID/name, or Google's test ad IDs (CC-001).
- ✅ `ITSAppUsesNonExemptEncryption: false` (only Apple's standard encryption: HTTPS, file protection, CommonCrypto
  for PINs) — no export compliance documents needed.
- ⏳ Version: the live app is **1.0**; the Swift release must be higher (suggest **2.0**, build numbers from 1). 👤
- ⏳ A Codemagic App Store workflow for the Swift app (today only the beta workflow builds it; `ios-app-store` is the
  legacy app). It must run `tools/release_guard.py` on the archive. 👤 (never submit without Ramyar's yes)
- ✅ Bundle ID unchanged from the live app (same listing, same reviews, same subscribers once created).

## Privacy
- ✅ `PrivacyInfo.xcprivacy`: no tracking by the app's own code, no data collected by the app; required-reason APIs
  declared: UserDefaults (CA92.1), file timestamps (C617.1). No other required-reason APIs found in the code.
- ✅ Permission texts: camera (invoices, barcodes), Face ID (lock), Bluetooth and local network (printers, customer
  display), tracking (ads, free version only).
- ⏳ App Store privacy label (filled in App Store Connect): Google Mobile Ads collects **Device ID, advertising data,
  product interaction, diagnostics**; "used to track you: Device ID" only for free users who allow tracking. Invoices,
  prices and sales stay on the device and the owner's iCloud: **not collected**. 👤
- ✅ Privacy policy and support pages: tlegendary.github.io/privacy.html and /support.html. Contact email only, no
  phone number anywhere.

## Money
- ⏳ In-app purchases in App Store Connect (the IDs the app now expects): `chargecheck_yearly` £89.99 and
  `chargecheck_monthly` £8.99 (1-week free trial each, one group), `chargecheck_scans_3/10/30` £0.99/£2.99/£6.99.
  Each needs a review screenshot of the paywall. 👤
- ⏳ Paid Apps agreement, bank and tax forms active in App Store Connect › Business. 👤
- ✅ Apple is the merchant of record for in-app purchases: Apple collects and pays VAT on them.
- ⏳ Card payments: none live. Each card company (Stripe, Square, SumUp, Adyen) ships its own SDK and privacy
  manifest when connected; Tap to Pay needs Apple's entitlement. Re-check this list then.
- ⏳ StoreKit purchase tests only pass once the products exist (see BACKLOG_PROGRESS.md).

## Review notes for Apple
- ⏳ Explain the till/POS and that card payments are taken on the shop's own card machine (no card data in the app);
  give a demo account path if review needs one (the app works offline without sign-in).

## Sign-off
- 👤 Ramyar: ____________________  date: ____________
