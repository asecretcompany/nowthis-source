---
layout: default
title: NowThis Documentation
---

<div align="center" markdown="1">

# NowThis Developer Docs

**Privacy-first, self-hosted CalDAV task manager for iOS.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://github.com/asecretcompany/nowthis-source/blob/main/LICENSE)
[![GitHub Repo](https://img.shields.io/badge/GitHub-Repository-black.svg?logo=github)](https://github.com/asecretcompany/nowthis-source)

[![Join the Beta on TestFlight](https://img.shields.io/badge/Join_the_Beta-TestFlight-0D96F6.svg?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/WEVC7CCZ)

</div>

---

Welcome to the open-source documentation for **NowThis**. 

This site provides technical guidance for developers looking to build, fork, or contribute to the NowThis iOS client.

## What's New in 1.0.4

The 1.0.4 release focuses on faster task entry, rock-solid Nextcloud sync, and smarter due dates.

- **Add tasks by voice** — Natural-language quick-add via Siri: dictate one sentence (*"buy milk tomorrow at 5pm"*) and NowThis parses the title and due date/time. The same parser powers typed Quick Add.
- **Faster task entry** — Single-tap to add on any list, an inline quick-add field on every list, and smart new-task defaults (app-wide and per-list default due date and time).
- **Reliable two-way Nextcloud sync** — Server-side creates, edits, completions, and reorders now reach the device and widget automatically; manual ordering round-trips via `X-APPLE-SORT-ORDER`; subtasks sort and reorder under their parent; fresh installs sync the last 3 months of completed tasks by default.
- **Smarter due dates** — Every due date shows a time slot (all-day tasks read "· All day"), all-day (date-only) due dates now show the correct day, and an All Day toggle flips a task between all-day and a specific time.
- **Clearer sync errors** — Plain-language banners for sign-in, connection, permission, and temporary server problems.
- **Stability** — The Kanban board no longer crashes when a task is deleted during sync.

## Core Architecture

NowThis is written in **Swift 6** using **SwiftUI** for the user interface and **SwiftData** for local persistence.

Key technical pillars include:
- **CalDAV Sync Engine:** A custom-built, actor-isolated sync engine (`CalDAVClient`) that supports background fetching and ETag-based inbound change detection with conflict resolution.
- **Natural-Language Parsing:** A shared `NaturalLanguageParser` turns free-text and Siri dictation into structured title + due date/time, powering both Quick Add and App Intents.
- **Local Vault:** A completely offline mode that bypasses the network layer, storing everything securely on-device.
- **Geofencing:** Location-based task reminders driven by CoreLocation and UserNotifications.
- **App Groups:** Shared state between the main app and widgets using iOS App Groups.

## Getting Started

NowThis uses **XcodeGen** to avoid merge conflicts in `.xcodeproj` files. To build the project locally:

1. Clone the repo from [GitHub](https://github.com/asecretcompany/nowthis-source).
2. Create a `Local.xcconfig` file from the template and add your Apple Developer Team ID.
3. Run `xcodegen generate` to create the `.xcodeproj` file.
4. Open the project in Xcode and run.

## Sync Deep Dive

Our sync engine communicates with any standard CalDAV server (with first-class support for Nextcloud). 
It uses a pull-then-push strategy:
1. Fetch latest changes via `REPORT` requests.
2. Resolve conflicts using ETag matching.
3. Push local changes via `PUT` requests.
4. Refresh the local SwiftData `ModelContext`.

## Security & Privacy

We take privacy seriously. 
- No analytics SDKs or tracking frameworks are included.
- All credentials are stored in the Secure Enclave using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Network requests are strictly authenticated and validate redirects to prevent token leakage.

## License

NowThis is released under the **GNU General Public License v3.0 (GPLv3)**. 
For more details, see the [LICENSE](https://github.com/asecretcompany/nowthis-source/blob/main/LICENSE) file in the repository.
