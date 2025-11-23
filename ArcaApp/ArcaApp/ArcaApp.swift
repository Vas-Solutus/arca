//
// ArcaApp.swift
// Arca
//
// Main application entry point for Arca GUI
//

import SwiftUI

@main
struct ArcaApp: App {
    @StateObject private var setupManager = SetupManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(setupManager)
                .frame(minWidth: 500, minHeight: 400)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Arca") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "Arca",
                            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
                            .credits: NSAttributedString(string: "Docker Engine API for Apple Containerization\n\n© 2025 Liquescent Development LLC")
                        ]
                    )
                }
            }
        }
    }
}
