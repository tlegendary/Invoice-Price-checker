# ChargeCheck – source of the first (web-based) version

`www/index.html` is built from the files in this folder. Edit these, not `www/index.html`.

- `index.html` – the app (screens, invoice reading, matching, reports)
- `boot-appstore.js` – subscriptions, scan packs, ads and the paywall
- `build.py` – packs everything into one offline file

To rebuild: `cd web-src && npm ci && python3 build.py`

Before sending a build for App Review, set `TEST_BUILD = False` in `build.py`.

This version is being replaced by a native Swift app – see the `swift-rewrite` branch.
