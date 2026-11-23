# Screen checklist (UI/UX blueprint → the real app)

Living list, updated as screens land. ✅ exists · 🟡 partial · ⬜ missing · — not planned.
iPhone keeps five tabs: **Home · Invoices · Suppliers · Till (or Reports) · More**. The blueprint's other areas
live inside these, so nobody faces 80 screens at once.

| Blueprint area | Where it is in the app | State |
|---|---|---|
| Home: today, quick actions, alerts | Home: Today card, scan / till buttons, money tiles, Needs attention | ✅ (profit + charts later) |
| Sell: register, receipts, cash, returns | Till tab: sale, split payments, refunds card-first, cash in/out, close day, layaways | ✅ |
| Sell: orders on account, exchanges | Till: customer accounts; exchanges | 🟡 |
| Products: list, prices, categories | More › Price list, Sort categories, price history | ✅ |
| Products: barcode labels | — | ⬜ |
| Stock: levels, low stock, movements | Till › Stock, Stock › Movements, Home low-stock | ✅ |
| Stock: counts, transfers between shops | Stock › Stocktake, In transit | ✅ |
| Purchasing: suppliers, orders, receiving | Suppliers tab, Make an order, deliveries in parts | ✅ |
| Invoices: capture, check, matching, discrepancies | Invoices tab, invoice detail, credit notes, statements | ✅ |
| Customers: profiles, history, loyalty | Till › customers, gift cards | 🟡 (loyalty screen) |
| Reports: sales, margins, stock, payments, VAT | Reports, Till › Sales (profit, low margins) | ✅ |
| Payments: card machines, reconciliation | More › Card payments | 🟡 (live providers need merchant accounts) |
| Security: roles, PINs, approvals, audit | Staff PINs, manager approval, History of changes | ✅ (supervisor role later) |
| Hospitality: kitchen screen, recipes | More › Kitchen, Cost per dish | ✅ |
| Hospitality: tables, tabs, tips, modifiers | — | ⬜ |
| Branches, sync, backup | Shops, iCloud sharing, save warnings, backup + restore | ✅ |
| First-run guide for a new cashier | — | ⬜ |

## Shared building blocks (App/Views/DesignSystem.swift)
- `DS` sizes (gap, padding, corner) — use instead of new numbers.
- `NoticeBanner` — warnings/problems: coloured icon and tinted row, text stays black/white for contrast.
- `StatusChip` — how something went (OK / overcharged / waiting) in one look.
- `PlanTag` — Pro/Pack tag, quiet (accent tint), not purple/blue.
- `FigureTile` — Home money tiles: labels on two lines, never cut off, read as one item by VoiceOver.

Colour rules: red = money lost or data at risk; amber = check soon; green = fine/saved; the shop's accent for
everything else. Charts only where they answer a question.
