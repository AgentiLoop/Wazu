# Wazu

A personal Mac TV player for a Hulu subscription, in SwiftUI. Not for distribution.

Hulu's video is FairPlay-encrypted, so the app doesn't pull streams itself: it hosts
Hulu's own web player (hulu.com/hub/home) in a WebKit view, which gets the keys the
normal way with your sign-in. Around it is a native shell:

- Sidebar: Home, TV, Movies, Live TV, My Stuff, Search (⌘1–⌘6)
- Back / Forward / Reload (⌘[ ⌘] ⌘R)
- Play/Pause, skip ±10 s, Picture in Picture (Playback menu), and the keyboard's
  media keys
- The window title shows what's playing
- Sign-in is remembered between launches (Wazu > Sign Out of Hulu clears it)

## Build

```sh
xcodegen generate
xcodebuild -project Wazu.xcodeproj -scheme Wazu -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Wazu.app
```
