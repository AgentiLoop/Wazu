//
//  WazuApp.swift
//  Wazu
//
//  One window; the Go and Playback menus drive the app model and the player.
//

import SwiftUI

@main
struct WazuApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("Wazu", id: "main") {
            ContentView().environmentObject(app)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Sign In to Hulu…") { app.showSignIn = true }
                Button("Sign Out of Hulu") { app.signOut() }
            }
            CommandMenu("Go") {
                ForEach(Array(Place.allCases.enumerated()), id: \.element) { index, place in
                    Button(place.title) { app.place = place }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                Button("Back") { app.path.removeLast() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(app.path.isEmpty)
            }
            CommandMenu("Playback") {
                Button(app.player.isPlaying ? "Pause" : "Play") { app.player.playPause() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(app.player.current == nil)
                Button("Skip Back 10 Seconds") { app.player.skip(-10) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(app.player.current == nil)
                Button("Skip Ahead 10 Seconds") { app.player.skip(10) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(app.player.current == nil)
                Divider()
                Button("Stop") { app.player.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(app.player.current == nil)
            }
        }
    }
}
