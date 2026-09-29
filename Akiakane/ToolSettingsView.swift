import SwiftUI
import AppKit

/// ⌘, で開く設定ウインドウ。ffmpeg / ffprobe の実行ファイルの場所だけを扱う。
/// 変換設定はメインウインドウのインスペクタにあり、ここには置かない。
struct ToolSettingsView: View {

    @Environment(ConversionQueue.self) private var queue
    @State private var customPaths: [FFTool: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(FFTool.allCases, id: \.self) { tool in
                    toolRow(tool)
                }
            } header: {
                Text("実行ファイルの場所")
            } footer: {
                Text("空欄なら \(FFToolLocator.searchDirectories.joined(separator: "、")) の順に探す。Homebrew で入れていればそのままでよい。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            for tool in FFTool.allCases {
                customPaths[tool] = UserDefaults.standard.string(forKey: tool.userDefaultsKey) ?? ""
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ tool: FFTool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(tool.rawValue, text: pathBinding(tool), prompt: Text("自動で探す"))
                    .textFieldStyle(.roundedBorder)
                Button("選択…") { choose(tool) }
            }
            HStack(spacing: 4) {
                if let located = FFToolLocator.locate(tool) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("使用中: \(located.path)")
                } else {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("見つかりません")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func pathBinding(_ tool: FFTool) -> Binding<String> {
        Binding(
            get: { customPaths[tool] ?? "" },
            set: { newValue in
                customPaths[tool] = newValue
                FFToolLocator.setCustomPath(newValue, for: tool)
                queue.recheckTools()
            }
        )
    }

    private func choose(_ tool: FFTool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "\(tool.rawValue) の実行ファイルを選ぶ"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            pathBinding(tool).wrappedValue = url.path
        }
    }
}
