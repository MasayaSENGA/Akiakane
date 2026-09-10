# Akiakane

macOS 用の動画一括変換アプリ。放送録画由来の `.ts` / `.m2ts` や既存の H.264 ファイルを、ffmpeg を使って H.265 に変換する。

作者専用のツールで、配布はしない。変換処理は ffmpeg に委譲し、このアプリは **フロントエンドとキュー管理** に徹する。独自のエンコード実装や編集機能は持たない。

## 動作環境

- macOS 14.0 以降、Apple Silicon
- Homebrew の ffmpeg / ffprobe（`brew install ffmpeg`）
- Xcode 26 以降（ビルド用）

App Sandbox は無効にしてある。有効にすると `Process` から ffmpeg を起動できなくなる。

## できること

- ファイルやフォルダをドロップすると、ffprobe でメタデータを読み取ってキューに並べる
- 「変換を開始」で、待機中のファイルを上から順に1本ずつ変換する
- 進捗率、速度、推定残り時間、出力サイズをリアルタイムに表示する
- 途中で停止・個別キャンセルができる。書きかけの出力は残らない
- 失敗・キャンセルしたファイルは待機に戻して再実行できる
- 変換中は Mac のスリープを抑止する

### 変換設定（ウインドウ右のパネル）

| 項目 | 選択肢 |
|---|---|
| 映像コーデック | libx265（ソフトウェア）/ VideoToolbox（ハードウェア）/ コピー |
| 画質 | libx265 は CRF（既定 21）とプリセット（既定 slow）。VideoToolbox は品質 1〜100（既定 65） |
| インターレース解除 | しない / 素材から自動判定 / 常に解除する（bwdif） |
| 音声 | コピー / AAC に変換（ビットレート指定）/ 含めない |
| コンテナ | MP4 / MKV / MOV |
| 保存先 | 入力と同じフォルダ / 指定したフォルダ |
| ファイル名 | 元の名前 + 接尾辞（既定 `_h265`） |
| 同名ファイルがあるとき | 別名で保存 / 上書き / スキップ |

設定は UserDefaults に保存され、次回起動時に引き継がれる。ffmpeg / ffprobe を Homebrew 以外の場所に入れている場合は、⌘, の設定ウインドウでパスを指定する。

### ffmpeg のコマンド

実行した ffmpeg / ffprobe のコマンドは全文が Xcode のコンソールに出る。GUI の設定がどのコマンドになったかを確認し、ターミナルにそのまま貼って再現できる。

`.ts` を MP4 に変換するときの既定の形は次のとおり。

```
ffmpeg -hide_banner -nostdin -y -fflags +genpts -i input.ts \
  -map 0:v:0 -map 0:a:0 \
  -c:v libx265 -crf 21 -preset slow -pix_fmt yuv420p \
  -vf bwdif=mode=send_frame:parity=auto:deint=interlaced \
  -c:a copy -bsf:a aac_adtstoasc \
  -tag:v hvc1 -movflags +faststart \
  -progress pipe:1 -nostats -loglevel error -f mp4 input_h265.mp4.partial
```

- `-tag:v hvc1` がないと QuickTime や Apple 製デバイスで HEVC が再生できない
- 出力は `.partial` 名で書き、成功後にリネームする。そのため `-f` でコンテナ形式を明示している
- インターレース解除は ffprobe の `field_order` を見て判断する。取れない素材は、インターレースとマークされたフレームだけを解除する

## ビルドとテスト

```bash
xcodebuild -project Akiakane.xcodeproj -scheme Akiakane -configuration Debug build
xcodebuild -project Akiakane.xcodeproj -scheme Akiakane -configuration Debug test -destination 'platform=macOS'
```

ユニットテストは ffmpeg を起動せず、引数の組み立て、`-progress` 出力のパース、出力先の命名、設定の保存を検証する。

テスト用のインターレース素材は次のコマンドで作れる。

```bash
ffmpeg -f lavfi -i testsrc2=size=1440x1080:rate=30000/1001 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 10 \
  -vf "tinterlace=mode=interleave_top,setfield=tff,setsar=4/3" -flags +ilme+ildct \
  -c:v mpeg2video -b:v 8M -c:a aac -f mpegts sample.ts
```

## ファイル構成

| ファイル | 役割 |
|---|---|
| `AkiakaneApp.swift` | エントリポイント。終了時に変換中の ffmpeg を止める |
| `ContentView.swift` | メイン画面。キュー一覧とツールバー |
| `MediaInfoDetail.swift` | 選択ファイルのメタデータと変換状態 |
| `SettingsInspector.swift` | 変換設定・出力先の編集パネル |
| `ToolSettingsView.swift` | ffmpeg / ffprobe のパス指定 |
| `ConversionQueue.swift` | 変換キュー。読み込みと順次変換 |
| `EncodeSettings.swift` | 設定モデル、ffmpeg 引数の組み立て、出力先の決定 |
| `FFmpegRunner.swift` | ffmpeg の実行と進捗のパース |
| `FFProbeRunner.swift` | ffprobe の実行と入力ファイルの収集 |
| `FFProbeReport.swift` / `MediaInfo.swift` | ffprobe の JSON とドメインモデル |
| `ProcessRunner.swift` | 外部プロセスの async 実行基盤 |
| `FFToolLocator.swift` | ffmpeg / ffprobe のパス解決 |

初期セットアップの手順は `SETUP.md` を参照。

## やらないこと

- 動画編集（カット、エフェクト、合成）
- ディスクオーサリング
- App Sandbox の有効化、コード署名、公証、配布
- ffmpeg の同梱
- Intel Mac / macOS 13 以下への対応
