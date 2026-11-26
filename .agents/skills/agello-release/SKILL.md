---
name: agello-release
description: First-release checklist for Agello (TestFlight and App Store), and which asc skills to use for each step. Use when preparing a build for TestFlight or the App Store, or for App Store Connect setup.
---

# Agello release checklist

Use this only when the user decides Agello is ready for TestFlight or the App Store — never schedule or start a release unprompted. App Store Connect work uses `/opt/homebrew/bin/asc` (`BypassSandbox: true`). Load `asc-cli-usage` first, then the skill named for each step. Any Apple account mutation (IDs, records, uploads, submission) requires explicit user go-ahead first.

## Identity & Capabilities

| Item | Value |
| --- | --- |
| Team / Bundle IDs | `FK2D8X36G2` · `com.patricedery.agello` · `.widgets` · `.share` |
| App Group | `group.com.patricedery.agello` (app + share extension) |
| Capabilities | Extended Virtual Addressing, Increased Memory Limit, Background GPU (`continued-processing` + `continued-processing.inference`), App Groups, WeatherKit (Capabilities + App Services) |
| Info.plist / Live Activities & Permissions | `NSSupportsLiveActivities = true`, `NSAlarmKitUsageDescription`, `NSPhotoLibraryUsageDescription` (`INFOPLIST_KEY_*` in `project.pbxproj`), `NSCalendarsFullAccessUsageDescription`, `NSRemindersFullAccessUsageDescription`, `NSContactsUsageDescription`, Mic / Speech / Camera / Location |

## Checklist

1. **Bundle IDs & capabilities** (`asc-signing-setup`). Old `com.patricedery.irtchat` IDs can be removed. Confirm all three bundle IDs, App Group, WeatherKit, and memory/background entitlements in the Developer portal before distribution signing.
2. **App record** (`asc-app-create-ui`, user's visible browser; user signs in to Apple). Confirm whether a record exists before creating one.
3. **Privacy & usage-string parity.**
   - `Agello/PrivacyInfo.xcprivacy` and `AgelloShare/PrivacyInfo.xcprivacy` (`C617.1`) declare no tracking, no data collected, and required-reason APIs (re-check `CLiteRTLM` via `agello-litert-update`). App Store answers must match: **"Data Not Collected"**.
   - **Pre-submission parity check:** Confirm [docs/privacy.md](../../../docs/privacy.md) and every `AgelloiOS/Info.plist` / `project.pbxproj` usage description match all shipping features & network calls: Web Search, opt-in WeatherKit/MapKit even with Search OFF, Calendar & Reminders CRUD (incl. `.destructive` delete), Contacts & `prepare_message` compose sheets, `AlarmKit` + Live Activities, opt-in Photos OCR (`.limited`-safe ANE), Outbound Shortcuts Bridge (`.external`, outside sandbox), linked project folders, `PasteButton`, lock-screen authenticated AppIntents, and Spotlight indexing. Get user confirmation.
4. **Model hosting.** Keep both Apache 2.0 repos public (`LICENSE`, `NOTICE`, SHA-256s pinned in `ModelCatalog.swift`):
   - `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope` (`gemma-4-E4B-it-agello-v2.litertlm`)
   - `PowerBeef02/embeddinggemma-2-text-270m-coreai-ane` (`embeddinggemma-2-text-270m-ane.aar`)
   - Keep `NOTICE` byte-identical to `Agello/Resources/NOTICE.txt` (`cmp NOTICE Agello/Resources/NOTICE.txt`).
5. **Export compliance.** `AgelloiOS/Info.plist` sets `ITSAppUsesNonExemptEncryption = false` (HTTPS via `URLSession` only). Revisit if custom crypto is added.
6. **App icon.** `Agello/Assets.xcassets/AppIcon.appiconset` ships 1024 + dark + tinted variants.
7. **Build & upload** (`asc-xcode-build`, `asc-build-lifecycle`). Release config; all three targets (`Agello`, `AgelloWidgets`, `AgelloShare`) must sign (`AgelloSim` has `SKIP_INSTALL = YES`). Wait for processing.
8. **TestFlight** (`asc-testflight-orchestration`). Requires **12 GB iPhone** (iPhone 17 Pro / Pro Max, iPhone Air, later), **iOS 27.0+**, and **`~7.0 GB` free** before starting sequential downloads:
   - `ModelStore.requiredBytes` (`sizeBytes + engineCacheBytes + 500 MB` margin):
     - **Gemma 4 E4B:** `3.69 GB` + `2.50 GB` cache + `0.50 GB` margin = **`6.69 GB`**.
     - **EmbeddingGemma 2 (ANE):** `128 MB` `.aar` + `180 MB` cache/unpacked + `500 MB` margin = **`0.81 GB`**.
     - **Combined installed footprint (files + caches):** **`6.49 GB`** (**`~7.0 GB` free** at start with 500 MB headroom).
   - No App Store 12 GB capability key exists; devices `< 12 GB` open `UnsupportedDeviceView` and download nothing. State 12 GB in store text and App Review notes (reviewers may test on 8 GB). Requirements can be relaxed later, never tightened.
9. **Screenshots** (`asc-screenshot-resize`, `asc screenshots upload`). Capture only on physical iPhone via `scripts/device-harness.sh screenshots`, never Simulator (`asc-shots-pipeline` blocked).
10. **Metadata** (`asc-metadata-sync`, `asc-whats-new-writer`). Lead with private on-device AI (no account, no cloud); mention ~3.8 GB model downloads and 12 GB floor.
11. **Review** (`asc-submission-health`, `asc-release-flow`). Web search queries only terms-permitted sources (App Review 5.2.2; verify terms and document in [docs/privacy.md](../../../docs/privacy.md) and `Knowledge/Web/` before shipping). Explain model downloads, 12 GB floor, memory/background-GPU entitlements, and opt-in personal/Shortcuts confirmations in review notes.
12. **After release** (`asc-crash-triage`). Symbolicate native LiteRT-LM or Swift crash reports with `axiom` MCP (`axiom_xcsym_crash`, `axiom_xcsym_triage`, `axiom_get_agent`).
