#!/usr/bin/env python3
"""Turns the raw App Store screenshots (from the cloud job "store") into the pictures for the App Store page:
1320 x 2868 (iPhone 6.9"), a headline and a line of text over the brand green, the app's screen in a phone frame.

    python3 frame-store-shots.py RAW_FOLDER OUT_FOLDER LATIN_BOLD LATIN_MEDIUM ARABIC_BOLD ARABIC_MEDIUM

Needs Pillow with Raqm (Arabic is shaped and written right to left). The Arabic fonts must also contain Latin letters
("ChargeCheck", "PDF"): Noto Sans Arabic's arabic and latin parts merged with fontTools work.
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1320, 2868
DARK, MAIN, BRIGHT = (11, 59, 46), (20, 104, 79), (95, 208, 162)

# order on the App Store page: screen name -> headline and line, per language
CAPTIONS = {
    "1-scan": {
        "en": ("Catch every overcharge", "Scan an invoice and see what you were overcharged, line by line"),
        "ar": ("اكتشف كل زيادة في السعر", "امسح الفاتورة واعرف كم دفعت زيادة، سطرًا بسطر"),
        "de": ("Jede Überberechnung erkennen", "Rechnung scannen und Zeile für Zeile sehen, was zu viel war"),
        "fr": ("Repérez chaque surfacturation", "Scannez une facture et voyez ce qui a été surfacturé, ligne par ligne"),
    },
    "2-home": {
        "en": ("Your business at a glance", "What you owe, what you've spent and what ChargeCheck caught"),
        "ar": ("عملك في لمحة", "ما تدين به وما أنفقته وما اكتشفه ChargeCheck"),
        "de": ("Dein Geschäft auf einen Blick", "Was du schuldest, was du ausgibst und was ChargeCheck findet"),
        "fr": ("Votre commerce en un coup d'œil", "Ce que vous devez, ce que vous dépensez et ce que ChargeCheck repère"),
    },
    "3-suppliers": {
        "en": ("Know what you owe", "Every supplier's balance, payments and due dates"),
        "ar": ("اعرف ما عليك", "رصيد كل مورّد ودفعاته ومواعيد استحقاقه"),
        "de": ("Wissen, was du schuldest", "Salden, Zahlungen und Fälligkeiten jedes Lieferanten"),
        "fr": ("Sachez ce que vous devez", "Soldes, paiements et échéances de chaque fournisseur"),
    },
    "5-credit": {
        "en": ("Get your money back", "Credit requests in one tap – PDF, WhatsApp or email"),
        "ar": ("استرجع أموالك", "طلب إشعار دائن بلمسة واحدة – PDF أو واتساب أو بريد"),
        "de": ("Hol dir dein Geld zurück", "Gutschriftanfragen mit einem Tipp – PDF, WhatsApp oder E-Mail"),
        "fr": ("Récupérez votre argent", "Demandes d'avoir en un geste – PDF, WhatsApp ou e-mail"),
    },
    "6-price": {
        "en": ("Spot price rises", "See what every item cost, invoice after invoice"),
        "ar": ("اكتشف ارتفاع الأسعار", "شاهد سعر كل صنف فاتورة بعد فاتورة"),
        "de": ("Preiserhöhungen erkennen", "Was jeder Artikel gekostet hat, Rechnung für Rechnung"),
        "fr": ("Repérez les hausses de prix", "Ce que chaque article a coûté, facture après facture"),
    },
    "7-shop": {
        "en": ("All your shops in one app", "See one shop or all of them – everything follows"),
        "ar": ("كل متاجرك في تطبيق واحد", "اعرض متجرًا واحدًا أو جميعها – كل شيء يتبع اختيارك"),
        "de": ("Alle Filialen in einer App", "Eine Filiale oder alle – alles folgt deiner Wahl"),
        "fr": ("Tous vos magasins dans une app", "Un magasin ou tous – tout suit votre choix"),
    },
    "8-reports": {
        "en": ("Reports for your accountant", "PDF and CSV for any period, per shop or all together"),
        "ar": ("تقارير لمحاسبك", "PDF وCSV لأي فترة، لكل متجر أو للجميع"),
        "de": ("Berichte für den Steuerberater", "PDF und CSV für jeden Zeitraum, je Filiale oder gesamt"),
        "fr": ("Des rapports pour votre comptable", "PDF et CSV sur toute période, par magasin ou au total"),
    },
}


def gradient():
    """Brand green, lighter at the top where the headline is, darker towards the bottom."""
    image = Image.new("RGB", (W, H), DARK)
    draw = ImageDraw.Draw(image)
    for y in range(H):
        t = (y / H) ** 0.8
        draw.line([(0, y), (W, y)], fill=tuple(int(MAIN[i] + (DARK[i] - MAIN[i]) * t) for i in range(3)))
    return image


def wrap(draw, text, font, width, rtl):
    words, lines, line = text.split(" "), [], ""
    for word in words:
        trial = (line + " " + word).strip()
        if draw.textlength(trial, font=font, direction="rtl" if rtl else None) <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def text_block(draw, text, font, top, width, colour, rtl, gap):
    y = top
    for line in wrap(draw, text, font, width, rtl):
        kwargs = {"direction": "rtl", "language": "ar"} if rtl else {}
        length = draw.textlength(line, font=font, **kwargs)
        draw.text(((W - length) / 2, y), line, font=font, fill=colour, **kwargs)
        y += font.size + gap
    return y


def frame(raw_path, out_path, title, line, fonts, rtl):
    canvas = gradient()
    draw = ImageDraw.Draw(canvas)
    bold, medium = fonts
    y = text_block(draw, title, bold, 140, W - 160, (255, 255, 255), rtl, 18)
    y = text_block(draw, line, medium, y + 18, W - 220, (214, 240, 229), rtl, 14)

    screen = Image.open(raw_path).convert("RGB")
    width = 1000
    screen = screen.resize((width, int(screen.height * width / screen.width)), Image.LANCZOS)
    bezel, radius = 26, 118
    phone_w, phone_h = screen.width + bezel * 2, screen.height + bezel * 2
    # the phone starts just under the text (and runs off the bottom if the text is long)
    left, top = (W - phone_w) // 2, max(int(y) + 90, 520)

    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((left + 10, top + 40, left + phone_w + 10, top + phone_h + 40), radius, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(45))
    canvas.paste((4, 30, 22), (0, 0), shadow)

    ImageDraw.Draw(canvas).rounded_rectangle((left, top, left + phone_w, top + phone_h), radius, fill=(18, 20, 22))
    mask = Image.new("L", screen.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen.width, screen.height), radius - bezel, fill=255)
    canvas.paste(screen, (left + bezel, top + bezel), mask)
    canvas.save(out_path, "PNG", optimize=True)


def main(raw, out, latin_bold, latin_medium, arabic_bold, arabic_medium):
    os.makedirs(out, exist_ok=True)
    layout = ImageFont.Layout.RAQM
    latin = (ImageFont.truetype(latin_bold, 92, layout_engine=layout), ImageFont.truetype(latin_medium, 50, layout_engine=layout))
    arabic = (ImageFont.truetype(arabic_bold, 92, layout_engine=layout), ImageFont.truetype(arabic_medium, 52, layout_engine=layout))
    made = 0
    for lang in ("en", "ar", "de", "fr"):
        for number, (screen, texts) in enumerate(CAPTIONS.items(), start=1):
            raw_path = os.path.join(raw, f"{lang}-{screen}.png")
            if not os.path.exists(raw_path):
                print("missing", raw_path)
                continue
            title, line = texts[lang]
            frame(raw_path, os.path.join(out, f"{lang}-{number:02d}-{screen[2:]}.png"), title, line,
                  arabic if lang == "ar" else latin, lang == "ar")
            made += 1
    print("made", made)


if __name__ == "__main__":
    main(*sys.argv[1:7])
