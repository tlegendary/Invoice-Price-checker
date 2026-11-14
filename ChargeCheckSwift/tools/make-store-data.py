#!/usr/bin/env python3
"""Writes a realistic ChargeCheck backup for the App Store screenshots (cloud check job "store").

Two takeaway shops, five suppliers, invoices from the last six weeks with real overcharges, a short delivery,
credits and payments. Every amount is worked out from the lines with the app's own rules (pennies rounded half up),
so totals, overcharges and balances always agree with each other. Dates are relative to today, so "this month"
always has invoices in it.

    python3 make-store-data.py OUTPUT.json
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP


def pennies(value):
    return float(Decimal(str(value)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


NORTHGATE = "Northgate Wholesale Ltd"
PRIME = "Prime Meats Direct"
BAKERY = "City Bakery Supplies"
VEG = "FreshVeg Market"
DRINKS = "Coastline Drinks"
HIGH, MARKET = "s-high", "s-market"

# id: (category, name, agreed price, usual supplier, VAT %, how suppliers write it)
ITEMS = {
    "wings": ("Meat & Poultry", "Chicken Wings 10kg", 14.99, PRIME, 0, "CHICKEN WINGS 10KG"),
    "breast": ("Meat & Poultry", "Chicken Breast Fillets 9kg", 47.50, PRIME, 0, "CHICKEN BREAST FILLETS 9KG"),
    "doner": ("Meat & Poultry", "Lamb Doner Cone 15kg", 62.00, PRIME, 0, "LAMB DONER CONE 15KG"),
    "burgers": ("Meat & Poultry", "Beef Burgers 48x4oz", 24.99, PRIME, 0, "BEEF BURGERS 48X4OZ"),
    "buns": ("Bakery", "Burger Buns 4x12", 7.29, BAKERY, 0, "BURGER BUNS 4X12"),
    "pitta": ("Bakery", "Pitta Bread 6x10", 6.50, BAKERY, 0, "PITTA BREAD 6X10"),
    "wraps": ("Bakery", "Tortilla Wraps 12in x18", 14.99, BAKERY, 0, "TORTILLA WRAPS 12\" X18"),
    "oil": ("Oils & Sauces", "Vegetable Oil 20L", 24.99, NORTHGATE, 0, "VEGETABLE OIL 20L"),
    "mayo": ("Oils & Sauces", "Mayonnaise 10L", 19.99, NORTHGATE, 0, "MAYONNAISE 10L"),
    "garlic": ("Oils & Sauces", "Garlic Sauce 5L", 12.49, NORTHGATE, 0, "GARLIC SAUCE 5L"),
    "mozz": ("Dairy", "Mozzarella 2kg", 11.99, NORTHGATE, 0, "MOZZARELLA GRATED 2KG"),
    "chips": ("Frozen", "Chips 4x2.5kg", 15.49, NORTHGATE, 0, "CHIPS 9MM 4X2.5KG"),
    "boxes": ("Packaging", "Pizza Boxes 12in x100", 16.99, NORTHGATE, 20, "PIZZA BOXES 12\" X100"),
    "burgerbox": ("Packaging", "Burger Boxes x500", 21.99, NORTHGATE, 20, "BURGER BOXES X500"),
    "onions": ("Fruit & Veg", "Onions 25kg", 13.50, VEG, 0, "ONIONS 25KG"),
    "lettuce": ("Fruit & Veg", "Iceberg Lettuce x12", 9.80, VEG, 0, "ICEBERG LETTUCE X12"),
    "tomatoes": ("Fruit & Veg", "Tomatoes 6kg", 8.40, VEG, 0, "TOMATOES 6KG"),
    "cola": ("Drinks", "Cola Cans 24x330ml", 7.99, DRINKS, 20, "COLA CANS 24X330ML"),
    "water": ("Drinks", "Spring Water 500ml x24", 3.50, DRINKS, 0, "SPRING WATER 500ML X24"),
}

# (days ago, supplier, invoice no., shop, [(item, qty, unit charged, qty short)], paid?, credit)
INVOICES = [
    (1, NORTHGATE, "NW-20417", HIGH, [("oil", 3, 26.49, 0), ("mayo", 2, 19.99, 0), ("chips", 6, 15.49, 0),
                                      ("mozz", 4, 12.49, 0), ("boxes", 2, 16.99, 0)], False, None),
    (2, PRIME, "PM-8812", HIGH, [("wings", 4, 15.99, 0), ("breast", 2, 47.50, 0), ("doner", 1, 62.00, 0),
                                 ("burgers", 2, 24.99, 0)], False, "requested"),
    (4, BAKERY, "CB-3391", MARKET, [("buns", 6, 7.29, 0), ("pitta", 4, 6.50, 0), ("wraps", 3, 14.99, 1)], False, None),
    (5, VEG, "FV-1022", MARKET, [("onions", 2, 13.50, 0), ("lettuce", 3, 9.80, 0), ("tomatoes", 4, 8.40, 0)], True, None),
    (7, DRINKS, "CD-5560", HIGH, [("cola", 10, 8.49, 0), ("water", 6, 3.50, 0)], False, None),
    (9, NORTHGATE, "NW-20311", MARKET, [("oil", 2, 24.99, 0), ("burgerbox", 1, 21.99, 0), ("chips", 4, 15.49, 0),
                                        ("garlic", 2, 12.49, 0)], True, None),
    (12, PRIME, "PM-8790", MARKET, [("wings", 3, 14.99, 0), ("breast", 1, 47.50, 0)], True, None),
    (19, NORTHGATE, "NW-20188", HIGH, [("oil", 3, 24.99, 0), ("mayo", 2, 19.99, 0), ("mozz", 3, 11.99, 0)], True, None),
    (24, PRIME, "PM-8701", HIGH, [("wings", 4, 14.99, 0), ("burgers", 2, 25.99, 0)], True, "received"),
    (33, DRINKS, "CD-5491", HIGH, [("cola", 10, 7.99, 0), ("water", 4, 3.50, 0)], True, None),
    (38, BAKERY, "CB-3302", HIGH, [("buns", 5, 7.29, 0), ("pitta", 3, 6.50, 0)], True, None),
]


def main(path):
    now = datetime.now(timezone.utc).replace(hour=10, minute=0, second=0, microsecond=0)
    baseline = []
    for item_id, (cat, name, price, supplier, _vat, spelling) in ITEMS.items():
        aliases = sorted({name.lower(), spelling.lower()})
        baseline.append({"id": item_id, "cat": cat, "name": name, "price": price, "supplier": supplier,
                         "aliases": aliases, "sp": []})

    history, payments = [], []
    for days, supplier, number, shop, rows, paid, credit in INVOICES:
        when = now - timedelta(days=days)
        lines, net, vat, over, over_vat, short_net = [], 0.0, 0.0, 0.0, 0.0, 0.0
        for item_id, qty, unit, short in rows:
            _cat, name, base, _sup, rate, spelling = ITEMS[item_id]
            line_net = pennies(qty * unit)
            line_over = pennies((unit - base) * qty) if unit > base + 0.0001 else 0.0
            net += line_net
            vat += pennies(line_net * rate / 100)
            over += line_over
            over_vat += pennies(line_over * rate / 100)
            short_net += pennies(short * unit)
            lines.append({"qty": qty, "desc": spelling, "unit": unit, "vat": rate, "matchId": item_id, "item": name,
                          "base": base, "over": line_over, "excluded": False, "noBase": False, "short": short})
        net, vat, over, over_vat, short_net = map(pennies, (net, vat, over, over_vat, short_net))
        total = pennies(net + vat)
        less = min(total, pennies(over + over_vat + short_net))
        to_pay = pennies(total - less)
        entry = {"id": "inv-" + number, "savedAt": when.isoformat().replace("+00:00", "Z"), "shopId": shop,
                 "supplier": supplier, "invNo": number, "date": when.strftime("%d/%m/%Y"), "net": net, "total": total,
                 "over": over, "overVat": over_vat, "excluded": short_net, "verified": True, "lines": lines,
                 "currency": "GBP"}
        if credit:
            asked = when + timedelta(hours=2)
            entry["credit"] = {"status": credit, "amount": less, "at": asked.isoformat().replace("+00:00", "Z")}
            if credit == "received":
                entry["credit"]["paidAt"] = (when + timedelta(days=6)).isoformat().replace("+00:00", "Z")
        if paid:
            paid_on = when + timedelta(days=3)
            entry["paid"] = paid_on.isoformat().replace("+00:00", "Z")
            payments.append({"id": "pay-" + number, "supplier": supplier, "amount": to_pay,
                             "date": paid_on.strftime("%Y-%m-%d"), "kind": "payment", "note": "",
                             "invoiceIDs": [entry["id"]], "method": "transfer", "reference": "",
                             "shopId": shop, "currency": "GBP", "invoiceAmounts": {entry["id"]: to_pay}})
        history.append(entry)

    backup = {
        "app": "ChargeCheck", "v": 3, "savedAt": now.isoformat().replace("+00:00", "Z"),
        "baseline": baseline, "history": history, "payments": payments,
        "settings": {"biz": "", "tol": 0.01, "mode": "auto", "color": "green", "keepCopy": "off",
                     "shops": [{"id": HIGH, "name": "High Street"}, {"id": MARKET, "name": "Market Road"}],
                     "shop": HIGH},
        "creditDays": {"northgate wholesale": 14, "prime meats direct": 7},
    }
    with open(path, "w", encoding="utf-8") as out:
        json.dump(backup, out, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main(sys.argv[1])
