# ADR-001 — Web owner dashboard and backend (CC-020)

Status: **proposed — needs Ramyar's approval** (no server, account or paid service is set up by this document).
Date: 23 Nov 2026.

## Decision in one line
Move shop data from iCloud Drive files to **CloudKit** (Apple's database, free at a shop's scale) behind the
app's existing store interfaces, and build the web owner dashboard on **CloudKit JS** (read-only first). No own
server until a feature truly needs one (card company webhooks, online store sync).

## Why
| Option | Cost | Multi-user & permissions | Web access | Effort |
|---|---|---|---|---|
| Keep iCloud Drive files (today) | Free | Weak: whoever has the folder can read/write every file | None | — |
| **CloudKit (recommended)** | Free tier covers a shop; Apple account per person | Shared zones per business; owner invites staff; records not files | CloudKit JS from a static web page | Medium |
| Own backend (e.g. Postgres + API) | Monthly hosting, a domain, someone to run it | Full control | Full | High, ongoing |
| Firebase / Supabase | Free tier, then paid; data leaves Apple | Good | Good | Medium; adds a dependency |

## Shape
- **Tenant = business.** One CloudKit shared zone per business; each shop is a `Location` record in it.
- **People and roles.** CloudKit share participants (owner, manager, staff) plus a `Member` record holding the
  ChargeCheck role (owner / manager / supervisor / cashier) and which locations they can see. The app enforces it
  (as the till store does today, CC-003); CloudKit's share permission is the outer wall (read-only vs read-write).
- **Events, not edits.** Sales, refunds, cash events, payments, stock movements, kitchen events and transfers are
  already append-only (CC-011/012/014/017/018): they become CloudKit records with the same IDs, so syncing twice is
  harmless. Settings, prices and recipes keep versioned records (latest wins, history kept).
- **Read models for the web.** Daily summaries per location (takings, cash/card, refunds, profit with coverage,
  owed to suppliers) written by the app when the day is closed, so the dashboard never needs to recompute.
- **Files.** Invoice photos and PDFs as CloudKit assets, private to the business zone.
- **Webhooks.** Card companies (CC-008) and online stores need a public URL: a small serverless function (Cloudflare
  Workers or AWS Lambda) only when the first one is connected — a paid commitment to approve then.
- **Migrations.** Each record type carries `schema`; the app reads old versions and writes the newest. Moving from
  iCloud Drive: the app uploads its existing files once, then reads CloudKit; files stay as a backup for 90 days.
- **iOS transport interface.** Stores already sit behind `CloudFolder` / `CloudOutbox`; a `CloudKitTransport` with the
  same send/retry/health contract replaces them, so screens don't change. CloudTeam (today's sharing) is not assumed
  to be active.

## Threat model (STRIDE, short)
| Threat | Example | Mitigation |
|---|---|---|
| Spoofing | Someone uses a lost staff phone | Face ID / passcode on the app, staff PIN at the till (CC-002), owner removes the participant from the share |
| Tampering | Editing a sale after the fact | Sales and money events are append-only; corrections are new records; audit log |
| Repudiation | "I didn't give that refund" | Every refund, cash event and approval records who did it and who approved (CC-003) |
| Information disclosure | One shop seeing another business's data | One zone per business; locations filtered by role; web uses the owner's Apple sign-in, no shared keys |
| Denial of service | iCloud down, offline tills | Offline first: local copy + outbox with retries (CC-011); tills keep selling |
| Elevation of privilege | A cashier editing settings | Role checks in the store (CC-003) and read-only share for staff where possible |

Card numbers never touch ChargeCheck: card companies' SDKs handle them (CC-008).

## Needs your decision
1. Approve CloudKit as the direction (free, Apple-only; web works in any browser after Apple sign-in).
2. Later, when the first card company or online store is connected: approve a small paid serverless function.
