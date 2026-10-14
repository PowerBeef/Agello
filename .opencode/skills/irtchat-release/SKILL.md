---
name: iRTChat release
description: First-release checklist for iRTChat (TestFlight and App Store), and which asc skills to use for each step. Use when preparing a build for TestFlight or the App Store, or for App Store Connect setup.
---

# iRTChat release checklist

The roadmap's next milestone is the first release: app icon, privacy
manifest, App Store metadata, accessibility pass, and performance and battery
budgets. App Store Connect work goes through the `asc` CLI. Load
`asc-cli-usage` first, then the skill named for each step.

Anything that changes the Apple account (registering IDs, creating records,
uploading, submitting) needs the user's go-ahead first.

## Identity

| Item | Value |
| --- | --- |
| Team | `FK2D8X36G2` |
| App | `com.patricedery.irtchat` |
| Widgets extension | `com.patricedery.irtchat.widgets` |
| Share extension | `com.patricedery.irtchat.share` |
| App Group | `group.com.patricedery.irtchat` (app and share extension) |
| App capabilities | Extended Virtual Addressing, Increased Memory Limit, Background GPU (continued processing), App Groups |

## Checklist

1. **Bundle IDs and capabilities** (`asc-signing-setup`). As of 2026-10-13
   the app and share IDs are registered; **the widgets ID is not**. Register
   it and confirm the capabilities above on the app ID.
2. **App record** (`asc-app-create-ui`, which needs the Playwright browser;
   the user signs in to Apple themselves). There was no record for
   `com.patricedery.irtchat` as of 2026-10-13.
3. **Privacy.** `iRTChat/PrivacyInfo.xcprivacy` declares no tracking, no data
   collected, and the required-reason APIs (see `irtchat-litert-update` for
   the LiteRT-LM part). The App Store privacy answers must match: "Data Not
   Collected". Web search sends only the query to the chosen provider, at the
   user's request; confirm the user agrees with that classification.
4. **Model hosting.** The chat model downloads from
   `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope` (our patched copy of
   litert-community's file, Apache 2.0, with a NOTICE). Keep that repo public,
   and keep the app's licenses screen crediting Google, litert-community and the
   modification.
5. **Export compliance.** The Info.plist has no
   `ITSAppUsesNonExemptEncryption`. The app only uses HTTPS through
   URLSession, which normally qualifies as exempt. Confirm with the user, then
   set it to `NO` to skip the question on every build.
6. **App icon.** Not in the repo yet.
7. **Build and upload** (`asc-xcode-build`). Use the Release configuration;
   all three targets must sign. Then follow `asc-build-lifecycle` until the
   build finishes processing.
8. **TestFlight** (`asc-testflight-orchestration`). Testers need an iPhone
   15 Pro or later on iOS 27 (`iphone-performance-gaming-tier`) and about
   4.4 GB free.
9. **Screenshots** (`asc-screenshot-resize`, then `asc screenshots upload`).
   Take them from the device harness (`build/device-harness/attachments/`,
   from the `ui` suite), never the simulator. `asc-shots-pipeline` is
   disabled for this project.
10. **Metadata** (`asc-metadata-sync`, `asc-whats-new-writer`). Privacy is the
   core pitch: on-device, no account, no cloud. Mention the 3.7 GB model
   download.
11. **Review** (`asc-submission-health`, `asc-release-flow`).
    - Before submitting, review DuckDuckGo's terms for scraping its HTML
      results page; keep DuckDuckGo's attribution.
    - Explain the large model download and the memory entitlements in the
      review notes.
12. **After release** (`asc-crash-triage`). TestFlight crashes may come from
    LiteRT-LM's native code; symbolicate with Axiom's `xcsym` tools.
