# CarPlay tweaks — personal Sileo repo

One jailbreak tweak, built and published automatically by GitHub Actions:

- **[`SplitCarPlay/`](SplitCarPlay/)** — side-by-side split screen for two
  apps on the physical CarPlay display, with a draggable divider and a
  floating speed card that reads Vietmap Live's own speed/limit directly
  (`VietmapLiveHook.xm` — originally a separate companion tweak, merged in
  so there's only one package to install).

Read [`SplitCarPlay/README.md`](SplitCarPlay/README.md) for how it
actually works, what's verified vs. still needs on-device tuning, and
build/debug instructions.

## How the CI/publishing works

On every push to `main`, [`.github/workflows/build-and-publish.yml`](.github/workflows/build-and-publish.yml):

1. Spins up a macOS GitHub Actions runner (building an iOS tweak needs a
   real Theos toolchain + iOS SDK — not available on Windows/Linux without
   a lot of extra setup, so this repo relies on GitHub's macOS runners
   instead of building locally).
2. Installs [Theos](https://theos.dev/) via the
   [`waruhachi/theos-action`](https://github.com/waruhachi/theos-action)
   action, installs a patched SDK from theos/sdks' release assets (needed
   for `Preferences.framework`, which the stock Xcode SDK the runner
   otherwise resolves to doesn't ship), then runs `make package`.
3. Generates a Sileo/Zebra-compatible `Packages` index
   ([`repo-tools/make_packages.py`](repo-tools/make_packages.py) — hand-rolled
   since `dpkg-scanpackages` isn't available on macOS runners, only
   `dpkg-deb` via `brew install dpkg`) and a matching `Release` file
   ([`repo-tools/make_release.py`](repo-tools/make_release.py) — Sileo's
   source-add flow 404s without one).
4. Publishes everything in [`site/`](site/) plus the built `.deb` and the
   generated `Packages`/`Packages.gz`/`Release` to **GitHub Pages**.

## One-time repo setup (do this once after creating the GitHub repo)

1. GitHub repo → **Settings → Pages → Build and deployment → Source**:
   set to **"GitHub Actions"** (not "Deploy from a branch").
2. Push to `main` — the workflow runs automatically. Check progress under
   the **Actions** tab.
3. Once it succeeds, your Sileo repo URL is:
   `https://anhtran3199.github.io/carplay-tweaks/`
   (already filled in across `SplitCarPlay/control` and `site/index.html`
   — update those again if you ever rename the GitHub account or this
   repo).

## Add it in Sileo on your phone

Sileo → Sources → "+" → paste:
```
https://<your-github-username>.github.io/<this-repo-name>/
```
or tap a `sileo://source/https://...` link from `site/index.html` on-device
(e.g. via a Notes link, AirDrop, or hosting that page somewhere you can tap
from Safari on the phone).

## Status / what to verify before trusting this while driving

SplitCarPlay has unverified pieces clearly marked `ADAPT` in its source —
see its own README. Build succeeding does **not** mean the private API
calls inside are correct for your iOS version; it only means the code
compiles. Treat the first install as something to test carefully, not as a
finished product.
