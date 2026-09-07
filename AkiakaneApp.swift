//
//  AkiakaneApp.swift
//  Akiakane
//
//  Created by User on 2026/09/07.
//

import SwiftUI

@main
struct AkiakaneApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 940, height: 600)
        .commands {
            // 「新規」は使わないので外す。
            CommandGroup(replacing: .newItem) { }
        }
    }
}
