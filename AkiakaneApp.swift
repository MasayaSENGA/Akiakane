//
//  AkiakaneApp.swift
//  Akiakane
//
//  Created by User on 2026/09/07.
//

import SwiftUI
import AppKit

@main
struct AkiakaneApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.queue)
        }
        .defaultSize(width: 1180, height: 680)
        .commands {
            // 「新規」は使わないので外す。
            CommandGroup(replacing: .newItem) { }

            CommandMenu("変換") {
                Button("変換を開始") { appDelegate.queue.startAll() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(appDelegate.queue.isRunning || appDelegate.queue.waitingCount == 0)
                Button("停止") { appDelegate.queue.stopAll() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!appDelegate.queue.isRunning)
            }
        }

        Settings {
            ToolSettingsView()
                .environment(appDelegate.queue)
        }
    }
}

/// キューの持ち主。アプリ終了時に ffmpeg を止め、`.partial` の掃除が終わるのを待つためにここに置く。
final class AppDelegate: NSObject, NSApplicationDelegate {

    let queue = ConversionQueue()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard queue.isRunning else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "変換中のファイルがあります"
        alert.informativeText = "終了すると変換中のファイルはキャンセルされ、書きかけの出力は削除されます。待機中のファイルはリストに残りません。"
        alert.addButton(withTitle: "終了する")
        alert.addButton(withTitle: "変換を続ける")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task { @MainActor in
            await queue.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
