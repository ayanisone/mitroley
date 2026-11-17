# Sharing mitroley and sending updates

mitroley. Copyright © 2026 Ayan Mitra. All rights reserved. See `LICENSE`: nobody may copy, redistribute
or sell it without written permission, so share it from a **private** GitHub repository and invite people to it.

## First time: put it on GitHub

1. On github.com, create a new **private** repository (no README, no licence, no .gitignore).
2. In this folder:

```bash
git remote add origin https://github.com/YOUR-NAME/mitroley.git
```

```bash
git push -u origin main
```

3. Repository › Settings › Collaborators › Add people, for everyone who should have it.

What goes up: the source, `build.sh`, `release.sh`, the docs. What stays on your Mac: built apps, your
sessions and their audio, your API keys (they live in `~/Library/Application Support/mitroley/keys.json`,
never in this folder).

## How someone else gets it

They need a Mac with macOS 15 or later.

**From source (always works).** Install the Xcode Command Line Tools (`xcode-select --install`), then:

```bash
git clone https://github.com/YOUR-NAME/mitroley.git && cd mitroley && ./build.sh
```

```bash
open build/mitroley.app
```

**From a release zip.** They download `mitroley-x.y.z.zip` from the repository's Releases page and unzip it.
The app is not signed with an Apple Developer ID, so the first launch is blocked: they open it once, then go to
System Settings › Privacy & Security and press "Open Anyway". To remove that step you need an Apple Developer
account (99 USD a year) to sign and notarize the app.

Either way they add their own keys in Settings (⌘,): ElevenLabs for generating sound, Anthropic for the
Claude panel. Your keys are not shared.

## Sending an update

```bash
git add -A && git commit -m "What changed"
```

```bash
./release.sh 0.2.0
```

That sets the version, builds, makes `build/mitroley-0.2.0.zip` and tags `v0.2.0`. Then either
`./release.sh 0.2.0 --publish` (needs GitHub's `gh` tool: `brew install gh`, `gh auth login`), or push the
tag and attach the zip to a new release on github.com by hand.

People who built from source update with:

```bash
git pull && ./build.sh
```

People on a zip download the new one. The app does not update itself.
