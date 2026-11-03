---
title: Install AirSQL
nav_order: 2
---

# Install AirSQL

AirSQL needs macOS 13.1 or later, on Apple silicon or Intel. It is free, and it needs no account.

## With Homebrew

```sh
brew install --cask kleash/tap/airsql
```

Later, `brew upgrade --cask airsql` updates it.

## From the download

1. Download **AirSQL-X.Y.Z.zip** from the [latest release](https://github.com/kleash/airsql/releases/latest).
2. Open the zip, then drag **AirSQL** to your **Applications** folder.
3. Open AirSQL. Apple has checked it (it is notarized), so it opens like any app.

To check the download first, see [Check a download](privacy-security.md#check-a-download).

## Remove AirSQL

Drag AirSQL from Applications to the Bin (with Homebrew: `brew uninstall --cask airsql`). Your connections and settings
stay in `~/Library/Application Support/AirSQL`, and saved passwords in your Keychain (the item named
`com.kleash.airsql` in Keychain Access), until you delete them. `brew uninstall --zap --cask airsql` deletes the
settings too.
