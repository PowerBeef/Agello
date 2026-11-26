---
title: Agello privacy policy
---

# Agello privacy policy

*Effective November 25, 2026*

Agello runs Google's Gemma models entirely on your iPhone. Your conversations, files, photos,
recordings, personal tool results and memories stay on your device. The developer of Agello doesn't
collect, receive, store or share any of your data. There are no accounts, analytics, advertising or
tracking.

## What stays on your iPhone

- **Chats and projects**, including the replies, their versions and reasoning, chat titles, and
  project instructions.
- **Files, linked folders, and photos** you attach, the text read from them, and the index used to
  search them. When you link a local or iCloud Drive folder to a project, Agello stores a
  security-scoped folder bookmark locally in `UserDefaults` and reads supported files into your local
  SwiftData store only when you tap Sync.
- **Voice**: voice messages, dictation and voice mode are recorded and understood on the device.
  Recordings are deleted once they're sent, and replies are read aloud with the system's
  on-device voices.
- **Camera**: pictures and document scans are processed on the device.
- **Memories** Agello saves about you (you can review and delete them in Settings → Memory), your
  personalization, and your settings.
- **Personal tools (opt-in)**: Calendar events, Reminders, Contacts, Alarms & Timers, and Photos
  (OCR) data you allow Agello to access are processed exclusively on your iPhone and are never sent
  off the device. Calendar and Reminders support reading, creating, updating, completing/reopening,
  and deleting; creating, changing, or deleting events, reminders, message drafts, timers, or alarms
  always requires your explicit tap on an in-chat confirmation card (including a red destructive
  confirmation for deletions and a multi-step plan card when multiple actions are proposed).
  Drafting an SMS or email opens iOS's native Messages or Mail composer (`MFMessageComposeViewController`
  / `MFMailComposeViewController`) — Agello never sends messages silently. Photos (OCR) runs
  on-device Apple Vision text recognition (`VNRecognizeTextRequest`) on photos you allow and never
  uploads images.
- **Clipboard, App Intents, and Focus Filters**: Agello never reads your clipboard in the
  background; pasting uses iOS's explicit system `PasteButton`. Siri and Shortcuts actions require
  device unlock (`IntentAuthenticationPolicy.requiresAuthentication`), and iOS Focus Filters adjust
  your personal tools and default project locally on-device.
- **Spotlight**: chat titles and short snippets, project names, and attached document names are added
  to the iPhone's on-device search index. You can turn this off in Settings, which clears them.
- **Diagnostics**: iOS gives Agello its crash and performance reports, and Agello keeps a log of
  its recent activity. Both stay on your iPhone; you can share them yourself from Settings →
  Help → Share diagnostics (the log can include parts of your questions).

Deleting a chat deletes its messages and files. Deleting the app deletes everything Agello stored.
Your iPhone's own backups (iCloud or a computer) can include Agello's chats, as for other apps;
downloaded models are excluded from backups.

## When Agello uses the network

Agello connects to other services only for the following, and only when you use them:

- **Model downloads.** The models are downloaded from Hugging Face (huggingface.co). Hugging Face
  receives a standard download request, including your IP address.
- **Web search.** When you turn on Search for a message, or allow automatic search in Settings,
  Agello looks your message up in the sources that fit it: Wikipedia and its sister projects
  (Wikivoyage, Wiktionary, Wikiquote) and Wikidata; Apple Maps for places and Apple Weather for
  weather; the European Central Bank's exchange rates; Crossref and PubMed for scientific and
  medical papers; or a SearXNG server you set up. The queries are short phrases the on-device
  model writes from your question and the last few messages; for weather, it's a place name, and
  Apple Weather receives that place's coordinates. Agello then downloads the pages it found to
  read them, identifying itself as Agello. Those services and websites receive the queries or page
  requests and your IP address. Your chats, files and memories are not sent. You can turn web
  access off entirely in Settings → Web search.
- **Opt-in Weather and Maps & Places personal tools (even with Web Search off).** If you enable
  **Weather** or **Maps & Places** in Settings → Personal tools, asking about forecasts, weather
  alerts, nearby places, or travel times contacts Apple Weather (`WeatherService`) or Apple Maps
  (`MKLocalSearch` / `MKDirections`) directly — even when Web Search is turned off. Only the place
  query, route endpoints, or coordinates needed for that lookup are sent to Apple; your chat history,
  files, and memories are never sent.
- **Your location.** Only when you ask about places, travel times, or weather near you ("the nearest
  gas station"), Agello asks for your location (while you use the app) and takes one reading. It's
  used on the iPhone to search Apple Maps or Apple Weather around you, so Apple receives that area;
  Agello doesn't store it or send it anywhere else. You can turn it off in Settings → Agello →
  Location, and ask about a named place instead.
- **Shared links.** When you share a web page to Agello and web access is on, Agello downloads
  that page to read it.
- **Outbound Apple Shortcuts (opt-in).** If you register specific Shortcuts in Settings →
  Automations & Shortcuts, Agello can propose running only those allowlisted Shortcuts. Before any
  Shortcut runs, you must approve an external confirmation card showing the Shortcut name and exact
  input payload. Agello then opens `shortcuts://x-callback-url/run-shortcut` and accepts any return
  output on `agello://shortcut-result` verified by a single-use 256-bit random callback nonce.
  Because third-party Shortcuts run **outside Agello's sandbox**, any actions, network requests, or
  third-party services inside a Shortcut you run are governed by Apple Shortcuts and those services'
  own privacy policies.

These services handle what they receive under their own privacy policies. Agello doesn't send
anything to the developer.

## Permissions

- **Microphone**: voice messages, dictation and voice mode.
- **Camera**: taking photos and scanning documents, and showing the model what your camera sees
  in voice mode.
- **Photos**: attaching photos you pick, and (if you opt in to **Photos (OCR)** in Settings →
  Personal tools) searching text inside photos you grant access to via on-device Apple Vision OCR
  (`PHPhotoLibrary` full or Limited Photos access). Photos are analyzed on your iPhone and never
  uploaded.
- **Location** (while you use the app): only when you ask about places, travel times, or weather
  near you, to search Apple Maps and Apple Weather around you. It isn't stored or sent anywhere
  else. You can turn it off in Settings → Agello → Location.
- **Calendar** (opt-in, off by default): only when you enable Calendar in Settings → Personal tools,
  to check your schedule, find free slots, or create, update, and delete events on your iPhone after
  you explicitly approve an in-chat confirmation card (deletions show a red destructive confirmation).
  Your calendar data never leaves your device.
- **Reminders** (opt-in, off by default): only when you enable Reminders in Settings → Personal
  tools, to list your reminders or create, update, complete/reopen, and delete reminders on your
  iPhone after you explicitly approve an in-chat confirmation card (or tap Complete/Snooze on a
  reminder card). Your reminders never leave your device.
- **Contacts** (opt-in, off by default): only when you enable Contacts in Settings → Personal
  tools, to look up names, phone numbers, email addresses, and organizations locally on your
  iPhone, and to pre-fill recipients when you confirm an SMS or email draft in the native Messages
  or Mail sheet. Your contacts never leave your device.
- **Alarms & Timers** (opt-in, off by default): uses iOS 27 `AlarmKit` (`NSAlarmKitUsageDescription`)
  and Lock Screen Live Activities (`NSSupportsLiveActivities`) only when you enable Alarms & Timers
  in Settings → Personal tools, to list active timers and alarms or schedule and cancel them on your
  iPhone after explicit confirmation. Your alarm data never leaves your device.

Each is used only when you enable or start the matching feature, and you can change them in
Agello's Settings or the iPhone's Settings at any time.

## Children

Agello isn't directed at children under 13 and doesn't knowingly collect anything from anyone.

## Changes

If this policy changes, the new version will be posted here with a new effective date.

## Contact

Questions about this policy: open an issue at <https://github.com/PowerBeef/Agello/issues>.
