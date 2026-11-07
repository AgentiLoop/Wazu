# Wazu

A personal Mac TV player for a Hulu subscription, in SwiftUI. Not for distribution.

Like Waze (Disney+) and StarPlayrX, it talks to the service's own web API and plays natively:
the same calls hulu.com's player makes (discover.hulu.com for browsing, guide.hulu.com for live
TV, play.hulu.com for the stream) feed a native UI, and AVPlayer plays the FairPlay HLS stream
with keys from Hulu's license server (AVContentKeySession). Sign-in happens once on hulu.com
in a web view; its session cookies are what the API client uses.

You need your own Hulu subscription. The app stores nothing but the session cookies the site
itself keeps in the browser.

## Features

- Sidebar: Home, TV, Movies, Live TV, My Stuff, Search (⌘1–⌘6); ⌘[ goes back a page
- Rows of artwork per hub; series pages list seasons and episodes; a Play button resumes
- Live TV: every channel in the guide with what's on now
- Player: AVKit's floating controls (full screen, Picture in Picture, audio/subtitle
  menus), Play/Pause ⌘P, skip ±10 s, Stop ⌘., Esc closes; the keyboard's media keys work
- Sign-in is remembered between launches (Wazu > Sign Out of Hulu clears it)

## Keyboard

| Shortcut | Action |
| --- | --- |
| ⌘1 – ⌘6 | Sidebar hubs (Search is ⌘6) |
| ⌘[ | Back |
| ⌘P | Play / Pause |
| ⌘← / ⌘→ | Skip back / forward 10 s |
| ⌃⌘T | Float on Top (player window) |
| ⌘. | Stop |
| Esc | Close the player |

## Requirements

- macOS 14 or later
- Xcode 15 or later
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the Xcode
  project is generated from `project.yml`

## Build

```sh
xcodegen generate
xcodebuild -project Wazu.xcodeproj -scheme Wazu -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Wazu.app
```

Re-run `xcodegen generate` after adding or removing files under `Sources/`.

## Layout

| File | Role |
| --- | --- |
| `Sources/WazuApp.swift` | App entry point, menus and keyboard shortcuts |
| `Sources/ContentView.swift` | Sidebar, hubs, rows of artwork, series/episode views, live guide, inline player |
| `Sources/HuluClient.swift` | The discover / guide / playlist API client and FairPlay key delivery |
| `Sources/Models.swift` | Codable models for the Hulu API responses |
| `Sources/Player.swift` | AVPlayer controller and AVKit player view |
| `Sources/PlayerWindow.swift` | Stand-alone player window (own full screen, Float on Top) |
| `Sources/SignIn.swift` | hulu.com sign-in web view that captures the session cookies |
| `project.yml` | xcodegen project definition |

## Notes

- Playback is DRM-protected; screenshots and screen recordings of the player come out black.
- This is a personal project that depends on undocumented endpoints; it can break whenever the
  service changes its web player.
