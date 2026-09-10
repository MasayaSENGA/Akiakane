import SwiftUI
import AppKit

/// 変換設定と出力先の設定パネル。ウインドウ右側のインスペクタとして出す。
/// ここでの変更は即座に保存され、次に開始する変換から反映される。
struct SettingsInspector: View {

    @Bindable var queue: ConversionQueue

    var body: some View {
        Form {
            Section("映像") {
                Picker("コーデック", selection: $queue.encodeSettings.videoCodec) {
                    ForEach(VideoCodec.allCases, id: \.self) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }

                switch queue.encodeSettings.videoCodec {
                case .libx265:
                    Stepper(value: $queue.encodeSettings.crf, in: 0...51) {
                        LabeledContent("CRF", value: "\(queue.encodeSettings.crf)")
                    }
                    Text("小さいほど高画質で大きなファイルになる。放送録画なら 20〜24 が目安。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("プリセット", selection: $queue.encodeSettings.preset) {
                        ForEach(EncodeSettings.presetChoices, id: \.self) { preset in
                            Text(preset).tag(preset)
                        }
                    }
                    Text("遅いプリセットほど同じ画質で小さくなるが、変換時間が延びる。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .hevcVideoToolbox:
                    Stepper(value: $queue.encodeSettings.videoToolboxQuality, in: 1...100, step: 5) {
                        LabeledContent("品質", value: "\(queue.encodeSettings.videoToolboxQuality)")
                    }
                    Text("1〜100 で、大きいほど高画質。libx265 より速いが、同じサイズでの画質は劣る。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .copy:
                    Text("映像を再エンコードせず、コンテナの詰め替えだけを行う。インターレース解除は無効になる。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("インターレース解除", selection: $queue.encodeSettings.deinterlace) {
                    ForEach(DeinterlaceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(queue.encodeSettings.videoCodec == .copy)
            }

            Section("音声") {
                Picker("音声", selection: audioKindBinding) {
                    ForEach(AudioMode.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                if case .aac(let bitrate) = queue.encodeSettings.audioMode {
                    Picker("ビットレート", selection: aacBitrateBinding(current: bitrate)) {
                        ForEach(AudioMode.aacBitrateChoices, id: \.self) { choice in
                            Text("\(choice) kbps").tag(choice)
                        }
                    }
                }
            }

            Section("出力") {
                Picker("コンテナ", selection: $queue.encodeSettings.container) {
                    ForEach(Container.allCases, id: \.self) { container in
                        Text(container.displayName).tag(container)
                    }
                }
                if queue.encodeSettings.container == .mkv {
                    Text("MKV は QuickTime Player で開けない。Apple 製アプリで見るなら MP4 にする。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("保存先", selection: destinationKindBinding) {
                    Text("入力と同じフォルダ").tag(DestinationKind.sameAsInput)
                    Text("指定したフォルダ").tag(DestinationKind.folder)
                }

                if queue.outputSettings.destinationFolderPath != nil {
                    HStack {
                        Text(queue.outputSettings.destinationFolderPath ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("選択…") { chooseDestinationFolder() }
                    }
                }

                TextField("ファイル名の接尾辞", text: $queue.outputSettings.suffix)
                Text("元のファイル名の後ろに付ける。空にすると元と同じ名前になり、拡張子だけが変わる。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("同名ファイルがあるとき", selection: $queue.outputSettings.existingFilePolicy) {
                    ForEach(ExistingFilePolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
            }

            if queue.isRunning {
                Section {
                    Text("設定の変更は、いま変換中のファイルには反映されない。次のファイルから使われる。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - バインディング

    private var audioKindBinding: Binding<AudioMode.Kind> {
        Binding(
            get: { queue.encodeSettings.audioMode.kind },
            set: { kind in
                switch kind {
                case .copy: queue.encodeSettings.audioMode = .copy
                case .aac:  queue.encodeSettings.audioMode = .aac(bitrate: AudioMode.defaultAACBitrate)
                case .none: queue.encodeSettings.audioMode = .none
                }
            }
        )
    }

    private func aacBitrateBinding(current: Int) -> Binding<Int> {
        Binding(
            get: { current },
            set: { queue.encodeSettings.audioMode = .aac(bitrate: $0) }
        )
    }

    private enum DestinationKind: Hashable {
        case sameAsInput
        case folder
    }

    private var destinationKindBinding: Binding<DestinationKind> {
        Binding(
            get: { queue.outputSettings.destinationFolderPath == nil ? .sameAsInput : .folder },
            set: { kind in
                switch kind {
                case .sameAsInput:
                    queue.outputSettings.destinationFolderPath = nil
                case .folder:
                    // 「指定したフォルダ」に切り替えた直後は、まだフォルダが決まっていない。
                    // すぐにパネルを出し、キャンセルされたら元に戻す。
                    chooseDestinationFolder()
                }
            }
        )
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "このフォルダに保存"
        if let current = queue.outputSettings.destinationFolderURL {
            panel.directoryURL = current
        }
        if panel.runModal() == .OK, let url = panel.url {
            queue.outputSettings.destinationFolderPath = url.path
        }
    }
}
