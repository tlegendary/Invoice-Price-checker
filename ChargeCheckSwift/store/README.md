# App Store page

- `metadata/<language>/` – the App Store texts (en-GB, ar-SA, de-DE, fr-FR), one file per field, within Apple's
  limits (name and subtitle 30, promotional text 170, keywords 100, description 4,000 characters). Same layout as
  fastlane `deliver`, so they can be uploaded through the App Store Connect API from Codemagic.
- Screenshots: commit message `[shots]` runs the "App Store screenshots" cloud job (raw screens in `store/` on the
  `ci-logs` branch), then `tools/frame-store-shots.py` adds the headline and phone frame (1320 × 2868, iPhone 6.9").
- Only say what the app really does. Check the description again whenever a feature changes or is removed.
- The app's primary App Store language may be English (UK) or English (US): use the folder that matches it.
