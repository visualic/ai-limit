# Notes for AI agents

Read this before building or changing anything. It is short on purpose.

## Installing it for someone

```bash
./Scripts/install.sh
```

That covers everything scriptable: prerequisite checks, build, signing, install
to `/Applications`, launch. **Do not** try to go further than it does.

Two steps genuinely require a human and cannot be automated:

1. `xcode-select --install` opens a macOS installer dialog. If the script stops
   here, tell the user to run it and click through — do not try to work around it.
2. Claude and Qwen need a one-time macOS Keychain approval. The dialog comes from
   `securityd`, cannot be clicked programmatically, and **is never shown at all
   while the display is asleep** — a fact worth stating plainly rather than
   retrying. OpenAI and Cursor need no approval; they read plain local files.

If you find yourself retrying a hung Keychain read, stop and ask the user to
wake the screen and approve it.

## Verifying a change

```bash
swift build                     # must be warning-free
.build/debug/AILimit --selftest # 120 cases, no network, no credentials needed
.build/debug/AILimit --check    # queries the real providers, prints results
```

`--selftest` is the fast, hermetic check — prefer it. It pins the language
internally, so it does not depend on the machine's locale.

`--check` is non-interactive on purpose: it never raises a Keychain prompt, so a
provider may report `SETUP` even when the installed app works. That is expected,
not a regression.

## Things that look like bugs and are not

- **A provider showing `SETUP` in `--check` but working in the app.** The app has
  been granted Keychain access; the CLI binary is a different signature.
- **The menu bar icon narrowing.** It draws one column per *configured* provider.
  Fewer columns means fewer providers set up — or switched off under Settings →
  Services, which also stops them being fetched — not a layout fault.
- **Cursor showing no bar on a Free plan.** Free reports `plan.limit: 0`; drawing
  a 0% bar would imply headroom that does not exist.

## Constraints worth knowing before you edit

- **Never let a credential read block.** Every Keychain and browser-cookie read
  runs off the Swift concurrency cooperative pool with a hard timeout, and
  background refreshes disallow interaction outright. Blocking one cooperative
  thread on a dialog previously froze the entire refresh. See `Keychain.bounded`.
- **Ad-hoc signing breaks Keychain grants.** The ACL is keyed on the code
  signature, so an ad-hoc build is a new app on every rebuild.
  `Scripts/package_app.sh` prefers a real certificate for this reason.
- **All user-facing strings live in `Sources/AILimit/Localization.swift`** as a
  type carrying both Korean and English. There is no string catalogue and no
  `.lproj`; adding UI copy means writing both languages, by construction.
- **Screenshots in `docs/` are generated**, not captured: `--screenshot` renders
  the real views offscreen. Regenerate them after UI changes rather than taking
  a screen capture, which needs an awake display and fails silently otherwise.
- Sample data used for screenshots is fabricated deliberately — these images
  ship in a public repository and must never contain real usage.

## Repository shape

| Path | What |
|---|---|
| `Sources/AILimit/Providers/` | one file per service, plus `UsageProvider` |
| `Sources/AILimit/UI/` | popover and settings |
| `Sources/AILimit/Localization.swift` | every user-facing string |
| `Sources/AILimit/DevTools.swift` | `--selftest`, previews, screenshots (`#if DEBUG`) |
| `Scripts/` | `install.sh`, `package_app.sh`, `release.sh`, `run.sh` |
