# セットアップ手順（ステップ2〜3）

## 1. ffmpeg / ffprobe の用意

```bash
brew install ffmpeg
which ffprobe   # /opt/homebrew/bin/ffprobe が返れば OK
```

`FFToolLocator` は `/opt/homebrew/bin` → `/usr/local/bin` → `/opt/local/bin` → `/usr/bin` の順に探します。別の場所に入れている場合は、UserDefaults のキー `FFToolPath.ffprobe` にフルパスを入れれば優先されます。

## 2. Xcode プロジェクトの作成

1. Xcode → File → New → Project
2. **macOS → App** を選択
3. 設定：
   - Product Name: `Akiakane`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Testing System / Core Data: いずれも不要
4. 保存先を決めて Create

## 3. App Sandbox を無効にする（重要）

新規プロジェクトには App Sandbox が既定で付いています。このままだと `Process` から Homebrew の ffmpeg を起動できません。

1. プロジェクトナビゲータでプロジェクト名 → TARGETS の `Akiakane` を選択
2. **Signing & Capabilities** タブ
3. **App Sandbox** の右上にある「×」または「-」ボタンで capability ごと削除
4. Hardened Runtime も付いていれば削除してよい（自分専用なので不要）

削除後、`Akiakane.entitlements` に `com.apple.security.app-sandbox` が残っていないことを確認してください。

## 4. Deployment Target の設定

TARGETS → General → Minimum Deployments → macOS **14.0**

`@Observable` マクロ（Observation フレームワーク）を使うため、13 以下では動きません。

## 5. ソースファイルの追加

Xcode が自動生成した `ContentView.swift` と `AkiakaneApp.swift` を、このフォルダの同名ファイルで置き換えます。残りは新規追加してください。

| ファイル | 役割 |
|---|---|
| `AkiakaneApp.swift` | エントリポイント |
| `ContentView.swift` | 動作確認用の最小 UI |
| `ProcessRunner.swift` | 外部プロセスを async で実行する共通基盤 |
| `FFToolLocator.swift` | ffmpeg / ffprobe の実行パス解決 |
| `FFProbeReport.swift` | ffprobe の JSON をそのまま受けるデコード用の型 |
| `MediaInfo.swift` | アプリが扱いやすい形に変換したメタデータ |
| `FFProbeRunner.swift` | ffprobe の実行とデコード |

Finder からドラッグして追加する場合は「Copy items if needed」にチェックを入れ、Target が `Akiakane` になっていることを確認してください。

## 6. 動作確認

Run して、ウインドウに .ts / .m2ts / .mp4 をドロップします。次が表示されれば成功です。

- コンテナ形式、長さ、ファイルサイズ、全体ビットレート
- 映像ストリーム：コーデック、解像度、フレームレート、ピクセルフォーマット、ビット深度、**フィールドオーダー**、SAR/DAR
- 音声ストリーム：コーデック、チャンネル数、サンプルレート、言語タグ
- 字幕・その他ストリームの本数

Xcode のコンソールには実行した ffprobe のコマンド全文が出ます。うまくいかないときは、それをそのままターミナルに貼って再現できます。

## 7. ここで確認しておきたいこと

手持ちの素材を何本か通して、以下を見ておくと次のステップが楽になります。

- **field_order が取れるか** — 1080i の .ts で `tt`（トップフィールドファースト）になるか。`unknown` が返る素材があるなら、インターレース解除はプリセット固定ではなく手動指定が必要になります。
- **format.duration が信頼できるか** — .ts は不正確なことがあります。ここが狂うと次のステップの進捗率がずれます。ずれる素材があれば、`-count_frames` や別の取得方法を検討します。
- **音声ストリームが複数あるか** — 主音声・副音声が両方入っている素材があるなら、ストリーム選択 UI の優先度が上がります。

## 次のステップ

ステップ4（FFmpegRunner）では、`-progress pipe:1 -nostats` を付けて ffmpeg を起動し、標準出力に流れてくる `out_time_us` を `MediaInfo.duration` で割って進捗率にします。`ProcessRunner` はその時点で「実行中に出力をストリーミングで受け取る」版を追加することになります。
