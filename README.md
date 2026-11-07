# Wazu

A personal Mac TV player for a Hulu subscription, in SwiftUI. Not for distribution.

Like StarPlayrX, it talks to the service's own web API and plays natively: the same calls
hulu.com's player makes (discover.hulu.com for browsing, guide.hulu.com for live TV,
play.hulu.com for the stream) feed a native UI, and AVPlayer plays the FairPlay HLS stream
with keys from Hulu's license server (AVContentKeySession). Sign-in happens once on hulu.com
in a web view; its session cookies are what the API client uses.

- Sidebar: Home, TV, Movies, Live TV, My Stuff, Search (⌘1–⌘6); ⌘[ goes back a page
- Rows of artwork per hub; series pages list seasons and episodes; a Play button resumes
- Live TV: every channel in the guide with what's on now
- Player: AVKit's floating controls (full screen, Picture in Picture, audio/subtitle
  menus), Play/Pause ⌘P, skip ±10 s, Stop ⌘., Esc closes; the keyboard's media keys work
- Sign-in is remembered between launches (Wazu > Sign Out of Hulu clears it)

## Build

```sh
xcodegen generate
xcodebuild -project Wazu.xcodeproj -scheme Wazu -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Wazu.app
```
