---
name: agello-release
description: First-release checklist for Agello (TestFlight and App Store), and which asc skills to use for each step. Use when preparing a build for TestFlight or the App Store, or for App Store Connect setup.
---

# Agello release checklist

This checklist is for when the user decides Agello is ready for the store.
That call is the user's: don't schedule a release, put one on the roadmap, or
start these steps unprompted. App Store Connect work goes through `/opt/homebrew/bin/asc`
(outside the terminal sandbox, `BypassSandbox: true`). Load `asc-cli-usage`
first, then the skill named for each step.

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
| App capabilities | Extended Virtual Addressing, Increased Memory Limit, Background GPU (`continued-processing` + `continued-processing.inference`), App Groups, WeatherKit (the App ID needs it under Capabilities and App Services) |

## Checklist

1. **Bundle IDs and capabilities** (`asc-signing-setup`). The app was
   renamed from iRTChat on 2026-10-14; its old `com.patricedery.irtchat` IDs
   are unused and can be removed from the portal. The first device build on
   2026-10-14 registered the app, share and widgets IDs, the App Group and
   the app's capabilities through automatic signing (development only);
   confirm them in the portal before the first distribution build.
2. **App record** (`asc-app-create-ui`, driven via Antigravity's `browser`
   subagent or the user's visible browser; the user signs in to Apple
   themselves). There was no record for the app (under either name) as of
   2026-10-14.
3. **Privacy.** `Agello/PrivacyInfo.xcprivacy` and
   `AgelloShare/PrivacyInfo.xcprivacy` (`C617.1`) declare no tracking, no data
   collected, and the required-reason APIs (see `agello-litert-update` for
   the LiteRT-LM part). The App Store privacy answers must match: "Data Not
   Collected". At the user's request, web search sends its queries to the
   sources the planner picks, Apple Weather a place's coordinates and Apple
   Maps the user's area for "near me" questions, and it downloads the pages it
   found (`docs/privacy.md`); nothing goes to the developer. Confirm the user
   agrees with that classification.
4. **Model hosting.** Both model repos are Apache 2.0 with `LICENSE` and
   `NOTICE` files:
   - Chat model: `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope` (our patched
     v2 128K copy of litert-community's E4B file, `gemma-4-E4B-it-agello-v2.litertlm`).
   - Embedding model: `PowerBeef02/embeddinggemma-2-text-270m-coreai-ane`
     (revision `41026d1c`, our 4-bucket asymmetric INT4 Core AI ANE conversion
     of litert-community's EmbeddingGemma 2).
   Keep both repos public, and keep the app's licenses screen (`NOTICE` /
   `Agello/Resources/NOTICE.txt`) crediting Google, litert-community and the
   modifications.
5. **Export compliance.** Done: `AgelloiOS/Info.plist` sets
   `ITSAppUsesNonExemptEncryption` to false (the app only uses HTTPS through
   URLSession, which qualifies as exempt). Revisit it if the app ever adds
   its own cryptography.
6. **App icon.** `Agello/Assets.xcassets/AppIcon.appiconset`: one 1024 image
   plus dark and tinted variants (added 2026-10-14). App Store Connect takes
   the 1024 marketing icon from the build.
7. **Build and upload** (`asc-xcode-build`). Use the Release configuration;
   all three targets must sign. Then follow `asc-build-lifecycle` until the
   build finishes processing.
8. **TestFlight** (`asc-testflight-orchestration`). Testers need an iPhone
   with 12 GB of memory (iPhone 17 Pro and Pro Max, iPhone Air, or later) on
   iOS 27 and about 6.9 GB free: the app starts a download only when the file,
   the engine cache its first load writes and a 0.5 GB margin fit
   (`ModelStore.requiredBytes`), 6.7 GB for E4B (3.69 + 2.5 + 0.5), and
   EmbeddingGemma, which follows, needs its 128 MB Core AI ANE archive and
   unpacked bundle (~0.26 GB headroom during unpack) on top.
   The App Store can't enforce the memory: there's no capability key for it,
   and `iphone-performance-gaming-tier` is for games (dropped 2026-11-12).
   Any iPhone on iOS 27 can install the app; below 12 GB it opens on
   `UnsupportedDeviceView` and downloads nothing. Say 12 GB in the store text
   and the review notes (a reviewer's iPhone may have 8 GB).
   Requirements can be relaxed in an update, never tightened.
9. **Screenshots** (`asc-screenshot-resize`, then `asc screenshots upload`).
   Take them with `scripts/device-harness.sh screenshots`
   (`build/device-harness/attachments/screenshots/`), never the simulator.
   `asc-shots-pipeline` is blocked in `.agents/hooks.json` for that reason.
10. **Metadata** (`asc-metadata-sync`, `asc-whats-new-writer`). Privacy is the
   core pitch: on-device, no account, no cloud. Mention the 3.7 GB model
   download.
11. **Review** (`asc-submission-health`, `asc-release-flow`).
    - Web search uses only sources whose terms permit the app (App Review
      5.2.2: "specifically permitted" under each service's terms; ready to
      show Apple). DuckDuckGo was removed for that on 2026-11-12. Check any
      new source's terms before it ships (ROADMAP "Current status").
    - Explain the large model download and the memory entitlements in the
      review notes.
12. **After release** (`asc-crash-triage`). TestFlight crashes may come from
    LiteRT-LM's native code. Symbolicate one report with `axiom_xcsym_crash`
    or triage a batch with `axiom_xcsym_triage` (plus `axiom_get_agent` if
    deeper audit guidance is needed).
