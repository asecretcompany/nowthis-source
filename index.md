---
layout: default
title: NowThis Documentation
---

<div align="center">

# NowThis Developer Docs

**Privacy-first, self-hosted CalDAV task manager for iOS.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://github.com/asecretcompany/nowthis-source/blob/main/LICENSE)
[![GitHub Repo](https://img.shields.io/badge/GitHub-Repository-black.svg?logo=github)](https://github.com/asecretcompany/nowthis-source)

[![Join the Beta on TestFlight](https://img.shields.io/badge/Join_the_Beta-TestFlight-0D96F6.svg?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/WEVC7CCZ)

</div>

---

Welcome to the open-source documentation for **NowThis**. 

This site provides technical guidance for developers looking to build, fork, or contribute to the NowThis iOS client.

## Core Architecture

NowThis is written in **Swift 6** using **SwiftUI** for the user interface and **SwiftData** for local persistence.

Key technical pillars include:
- **CalDAV Sync Engine:** A custom-built, actor-isolated sync engine (`CalDAVClient`) that supports background fetching and ETag-based conflict resolution.
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
