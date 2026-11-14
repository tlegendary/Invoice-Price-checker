# App Store page

- `metadata/<language>/` – the App Store texts (en-GB, ar-SA, de-DE, fr-FR), one file per field, within Apple's
  limits (name and subtitle 30, promotional text 170, keywords 100, description 4,000 characters). Same layout as
  fastlane `deliver`, so they can be uploaded through the App Store Connect API from Codemagic.
- Screenshots: commit message `[shots]` runs the "App Store screenshots" cloud job (raw screens and video clips in
  `store/` on the `ci-logs` branch), then `tools/frame-store-shots.py` adds the headline and phone frame
  (1320 × 2868, iPhone 6.9"; captions for every language are in that script). Arabic needs a font with Latin letters
  too: Noto Sans Arabic's arabic and latin parts (npm `@fontsource/noto-sans-arabic`) merged with fontTools.
- Preview video: `tools/make-preview.py` joins the English clips into 886 × 1920, 30 fps H.264 with silent stereo
  AAC, about 24 s (Apple allows 15–30 s). Real footage only: launch screens cut, the reading wait sped up 3×.
- Only say what the app really does. Check the description again whenever a feature changes or is removed.
- The app's primary App Store language may be English (UK) or English (US): use the folder that matches it.
