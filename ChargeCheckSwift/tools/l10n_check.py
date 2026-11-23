#!/usr/bin/env python3
"""Fails (exit 1) when a text in the app isn't translated into every language ChargeCheck supports.

  l10n_check.py App/Localizable.xcstrings

Checks each string has an Arabic, Kurdish (Sorani), German and French translation that isn't empty and keeps the
same placeholders (%@, %lld…) as the English, so no screen shows English in the middle of Arabic or crashes on a
missing value. Strings marked "shouldTranslate": false (brand names, symbols) are skipped.
"""
import json
import re
import sys

LANGS = ["ar", "ckb", "de", "fr"]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f|lf)")


def placeholders(text):
    # "%1$@" and "%@" are the same value: compare the kinds and how many, not their numbering
    return sorted(re.sub(r"%\d+\$", "%", p) for p in PLACEHOLDER.findall(text))


def main(path):
    data = json.load(open(path, encoding="utf-8"))
    missing, wrong = [], []
    for key, entry in data.get("strings", {}).items():
        if entry.get("shouldTranslate") is False or not key.strip() or not re.search(r"[A-Za-z]{2}", key):
            continue
        locs = entry.get("localizations", {})
        for lang in LANGS:
            unit = locs.get(lang, {}).get("stringUnit", {})
            value = unit.get("value", "")
            plural = locs.get(lang, {}).get("variations")
            if not value and not plural:
                missing.append((lang, key))
            elif value and placeholders(value) != placeholders(key):
                wrong.append((lang, key, value))
    for lang, key in missing[:40]:
        print(f"MISSING {lang}: {key[:90]}")
    for lang, key, value in wrong[:40]:
        print(f"PLACEHOLDERS {lang}: {key[:60]} -> {value[:60]}")
    total = len(data.get("strings", {}))
    print(f"{total} strings; {len(missing)} missing translations, {len(wrong)} with different placeholders")
    return 1 if missing or wrong else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "App/Localizable.xcstrings"))
