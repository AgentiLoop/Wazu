//
//  WazuApp.swift
//  Wazu
//
//  One window; the Go and Playback menus drive the web controller.
//

import SwiftUI

@main
struct WazuApp: App {
    @StateObject private var web = WebController()

    var body: some Scene {
        Window("Wazu", id: "main") {
            ContentView().environmentObject(web)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Sign Out of Hulu") { web.signOut() }
            }
            CommandMenu("Go") {
                ForEach(Array(Place.allCases.enumerated()), id: \.element) { index, place in
                    Button(place.title) { web.go(place) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                Button("Back") { web.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!web.canGoBack)
                Button("Forward") { web.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!web.canGoForward)
                Button("Reload Page") { web.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Playback") {
                Button(web.isPlaying ? "Pause" : "Play") { web.playPause() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Skip Back 10 Seconds") { web.skip(-10) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Skip Ahead 10 Seconds") { web.skip(10) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button("Picture in Picture") { web.pictureInPicture() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}
