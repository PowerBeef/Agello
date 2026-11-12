---
name: agello-release
description: First-release checklist for Agello (TestFlight and App Store), and which asc skills to use for each step. Use when preparing a build for TestFlight or the App Store, or for App Store Connect setup.
---

# Agello release checklist

This checklist is for when the user decides Agello is ready for the store.
That call is the user's: don't schedule a release, put one on the roadmap, or
start these steps unprompted. App Store Connect work goes through the `asc` CLI. Load
`asc:asc-cli-usage` first, then the skill named for each step.

Anything that changes the Apple account (registering IDs, creating records,
uploading, submitting) needs the user's go-ahead first.

## Identity

| Item | Value |
| --- | --- |
| Team | `FK2D8X36G2` |
| App | `com.patricedery.agello` |
| Widgets extension | `com.patricedery.agello.widgets` |
| Share extension | `com.patricedery.agello.share` |
| App Group | `group.com.patricedery.agello` (app and share extension) |
| App capabilities | Extended Virtual Addressing, Increased Memory Limit, Background GPU (continued processing), App Groups |

## Checklist

1. **Bundle IDs and capabilities** (`asc:asc-signing-setup`). The app was
   renamed from iRTChat on 2026-10-14; its old `com.patricedery.irtchat` IDs
   are unused and can be removed from the portal. The first device build on
   2026-10-14 registered the app, share and widgets IDs, the App Group and
   the app's capabilities through automatic signing (development only);
   confirm them in the portal before the first distribution build.
2. **App record** (`asc:asc-app-create-ui`, driven through Claude in Chrome in
   the user's own visible Chrome; the user signs in to Apple themselves).
   There was no record for the app (under either name) as of 2026-10-14.
3. **Privacy.** `Agello/PrivacyInfo.xcprivacy` declares no tracking, no data
   collected, and the required-reason APIs (see `agello-litert-update` for
   the LiteRT-LM part). The App Store privacy answers must match: "Data Not
   Collected". Web search sends only the query to the chosen provider, at the
   user's request; confirm the user agrees with that classification.
4. **Model hosting.** The chat model downloads from
   `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope` (our patched copy of
   litert-community's file, Apache 2.0, with a NOTICE). Keep that repo public,
   and keep the app's licenses screen crediting Google, litert-community and the
   modification.
5. **Export compliance.** Done: `AgelloiOS/Info.plist` sets
   `ITSAppUsesNonExemptEncryption` to false (the app only uses HTTPS through
   URLSession, which qualifies as exempt). Revisit it if the app ever adds
   its own cryptography.
6. **App icon.** `Agello/Assets.xcassets/AppIcon.appiconset`: one 1024 image
   plus dark and tinted variants (added 2026-10-14). App Store Connect takes
   the 1024 marketing icon from the build.
7. **Build and upload** (`asc:asc-xcode-build`). Use the Release configuration;
   all three targets must sign. Then follow `asc:asc-build-lifecycle` until the
   build finishes processing.
8. **TestFlight** (`asc:asc-testflight-orchestration`). Testers need an iPhone
   with 12 GB of memory (iPhone 17 Pro and Pro Max, iPhone Air, or later) on
   iOS 27 and about 4.4 GB free. The App Store can't enforce that: there's no
   capability key for memory, and `iphone-performance-gaming-tier` is for
   games (dropped 2026-11-12). Any iPhone on iOS 27 can install the app; below
   12 GB it opens on `UnsupportedDeviceView` and downloads nothing. Say 12 GB
   in the store text and the review notes (a reviewer's iPhone may have 8 GB).
   Requirements can be relaxed in an update, never tightened.
9. **Screenshots** (`asc:asc-screenshot-resize`, then `asc screenshots upload`).
   Take them with `scripts/device-harness.sh screenshots`
   (`build/device-harness/attachments/screenshots/`), never the simulator. `asc:asc-shots-pipeline` is
   denied in `.claude/settings.json` for that reason.
10. **Metadata** (`asc:asc-metadata-sync`, `asc:asc-whats-new-writer`). Privacy is the
   core pitch: on-device, no account, no cloud. Mention the 3.7 GB model
   download.
11. **Review** (`asc:asc-submission-health`, `asc:asc-release-flow`).
    - Before submitting, review DuckDuckGo's terms for scraping its HTML
      results page; keep DuckDuckGo's attribution.
    - Explain the large model download and the memory entitlements in the
      review notes.
12. **After release** (`asc:asc-crash-triage`). TestFlight crashes may come from
    LiteRT-LM's native code. Symbolicate one report with `/axiom:analyze-crash`,
    or triage a batch with the `axiom:triage-analyzer` agent.
