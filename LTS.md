# lts/macos26

> **Frozen (2026-10-23).** Intel Macs on macOS 26 are built from `main` now: one branch, an x86_64 build with Xcode 26
> next to the Apple Silicon one. This branch takes no more backports and no `-lts` releases; it stays for reference.
> Fixes go to `main`.

This branch is the long-term support line for **macOS 26 Tahoe on Intel Macs** (x86_64), the last macOS that runs on
them. FrameScrub's and Loupe's `lts/macos26` branches depend on this branch, not on a version tag.

- **Supported until** Apple ends security updates for macOS 26 (expected autumn 2028).
- **What lands here:** fixes, and features backported from `main` when they need nothing newer than macOS 26 and
  Swift 6.2 / Xcode 26. Changes go `main` → `lts/macos26` only (cherry-pick, label `backport:lts` or
  `backport:lts-feature` on the `main` pull request); nothing is merged back.
- **CI** builds and tests x86_64 on GitHub's macos-26 image under Rosetta with the newest Xcode 26.

The full policy is in [FrameScrub's LTS_POLICY.md](https://github.com/ampire5/FrameScrub/blob/lts/macos26/LTS_POLICY.md).
