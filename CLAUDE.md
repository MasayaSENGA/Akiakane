# CLAUDE.md

このファイルはリポジトリルートに置く。Claude Code が毎回読む前提の常設コンテキスト。

## プロジェクト概要

**Akiakane** — macOS 用の動画変換アプリ。GitHub でソースコードのみを公開している（MIT License）。
ビルド済みバイナリは配布しない。利用者は clone して Xcode でビルドする。

主な用途は、放送録画由来の `.ts` / `.m2ts` と既存の H.264 ファイルを H.265 に一括変換すること。
変換処理そのものは ffmpeg に委譲し、本アプリは **フロントエンドとキュー管理** に徹する。
独自のエンコード実装や動画編集機能は作らない。

利用者向けの説明は `README.md`、Xcode プロジェクトをゼロから作る手順は `SETUP.md` にある。

## 前提と制約

| 項目 | 内容 |
|---|---|
| 配布 | GitHub でソース配布のみ。コード署名・公証・App Store 対応はいずれも不要 |
| App Sandbox | **無効**。有効にすると `Process` から ffmpeg を起動できないため、絶対に再有効化しない |
| 最低 OS | macOS 14.0（`@Observable` を使うため） |
| アーキテクチャ | Apple Silicon のみ。Intel 対応は不要 |
| UI | SwiftUI。AppKit は必要な場合のみ限定的に使う |
| ffmpeg / ffprobe | Homebrew 版をパス参照する。`.app` への同梱はしない |
| UI 言語 | 日本語 |
| コード内コメント | 日本語 |

## ビルドと確認

```bash
xcodebuild -project Akiakane.xcodeproj -scheme Akiakane -configuration Debug build
```

コードを変更したら、ユーザーに渡す前に必ず上記でビルドが通ることを確認する。
Xcode を開いて手で確認してもらうのは最後の実行確認だけにする。

## 現在のファイル構成

| ファイル | 役割 | 状態 |
|---|---|---|
| `AkiakaneApp.swift` | エントリポイント。`AppDelegate` がキューを所有し、終了時に ffmpeg を止める | 完成 |
| `ContentView.swift` | メイン画面。キュー一覧（サイドバー）・ツールバー・設定インスペクタの配置 | 完成 |
| `MediaInfoDetail.swift` | 選択ファイルのメタデータと変換状態の表示 | 完成 |
| `SettingsInspector.swift` | 変換設定・出力先の編集パネル | 完成 |
| `ToolSettingsView.swift` | ⌘, の設定ウインドウ。ffmpeg / ffprobe のパス指定 | 完成 |
| `ConversionQueue.swift` | 変換キュー。ffprobe での読み込み、1本ずつの順次変換、停止・再投入 | 完成 |
| `EncodeSettings.swift` | 変換設定・出力先設定のモデル、`makeAudioPlan` / `makeArguments` / `makeOutputPlan`、UserDefaults への保存 | 完成 |
| `AudioLayoutScanner.swift` | 変換前の音声の走査。ADTS ヘッダからチャンネル構成の切り替えとデュアルモノを検出する | 完成 |
| `FFmpegRunner.swift` | ffmpeg の実行と `-progress` のパース、AAC エンコーダ（`aac_at` / `aac`）の選択 | 完成 |
| `ProcessRunner.swift` | 外部プロセスを async で実行する基盤（一括版と、行単位・バイト列のストリーミング版） | 完成 |
| `FFToolLocator.swift` | ffmpeg / ffprobe のパス解決 | 完成 |
| `FFProbeReport.swift` | ffprobe の JSON デコード用 | 完成 |
| `MediaInfo.swift` | アプリが扱うメタデータのドメインモデル | 完成 |
| `FFProbeRunner.swift` | ffprobe 実行、および入力ファイルの収集 | 完成 |
| `AkiakaneTests/` | `makeArguments`・音声の扱いの決定・ADTS の解析・`ProcessRunner` のキャンセル・進捗パーサ・出力先命名・設定保存のユニットテスト | 通過 |

ステップ4（1ファイルの変換・進捗・キャンセル）とステップ5（キュー管理・設定 UI）まで実装済み。
実機での一括変換の動作確認はこれから。

### テスト

```bash
xcodebuild -project Akiakane.xcodeproj -scheme Akiakane -configuration Debug test -destination 'platform=macOS'
```

ソースはルート直下の同期フォルダで管理している。`AkiakaneTests/` に新しいテストファイルを足したら、
`project.pbxproj` の `membershipExceptions`（アプリターゲットからの除外リスト）にも追加しないと、
アプリ本体のビルドで `XCTest` が解決できずに失敗する。

## 設計上の決定と、その理由

書き換える前に理由を確認すること。いずれも実際に踏んだ問題への対処である。

- **`ProcessRunner` は stdout / stderr / プロセス終了の3つを `DispatchGroup` で待ち合わせる。**
  パイプは 64KB 程度で埋まる。待機中も読み続けないと、出力の多いプロセスがブロックして終了しない。
- **`FFProbeReport` は `profile` フィールドを decode していない。**
  ffprobe のバージョンとコーデックによって文字列と数値が混在し、型を固定すると Decodable 全体が失敗する。
- **`MediaInfo.duration` は `format.duration` → 各ストリームの `duration` の最大値 の順にフォールバックする。**
  `.ts` は `format.duration` が欠けることがある。この値は変換時の進捗率の分母になるため落とせない。
- **`FFToolLocator` は `which` を使わず候補ディレクトリを直接見る。**
  GUI アプリの PATH は短く、シェルの設定が反映されない。
- **ffprobe は1本ずつ順に実行する。**
  大量ドロップ時にプロセスが一気に増えるのを避けるため。
- **ffmpeg も1本ずつ順に実行する。**
  libx265 はそれ自体でコアを使い切るので並列にしても総時間は縮まらず、1本ずつのほうが完了ファイルが早く得られる。
- **出力は `<最終名>.partial` に書き、成功後にリネームする。そのため `-f mp4` などコンテナ形式を必ず明示する。**
  ffmpeg は拡張子から形式を推定するので、`.partial` 名のままだと起動時に「Unable to choose an output format」で失敗する。
- **プロジェクトの既定 actor 分離は MainActor（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）。**
  パイプの読み取りスレッドから呼ばれるクラス（`LineSplitter`、`OutputCollector`、`FFmpegProgressAccumulator`、`ProgressRelay`、`ADTSLayoutParser` など）は
  `nonisolated` を明示する。付けないと「main actor-isolated ... in a synchronous nonisolated context」の警告が出る。
- **出力先の決定（`makeOutputPlan`）は入力そのものと同じパスになる場合に `_h265` を強制する。**
  接尾辞を空にして同じフォルダ・同じコンテナで変換すると、入力ファイルを上書きしてしまうため。
- **MPEG-TS の AAC 音声は、変換の前にファイル全体の ADTS ヘッダを走査する（`AudioLayoutScanner`）。**
  放送は録画の途中でチャンネル構成が変わる（CM はステレオ、本編は 5.1ch など）。MP4 / MKV の AAC は構成を1つしか持てないため、
  コピーすると切り替え以降が再生できない。デュアルモノは切り替えがなくても Apple で再生できない。どちらも ffmpeg は終了コード 0 で終わる。
  ffprobe のストリーム情報は冒頭の構成しか示さないので、全フレームを見る必要がある。
- **5.1ch はダウンミックスしない。構成が1つならコピーし、切り替えやデュアルモノがあるときだけ、全体の最大チャンネル数を `-ac` で指定して AAC に変換する。**
  `-ac` を付けずに再エンコードすると、ffmpeg は最初のフレームの構成でエンコーダを作る。冒頭がステレオの録画では、本編の 5.1ch が黙ってステレオに落ちる。
  ffmpeg だけで無劣化のまま切り替えを保つ方法（fMP4、MKV、TS 出力など）は、どれも Apple で再生できなかった。
- **`ADTSLayoutParser` は先頭のフレームの構成を必ず区間として残し、PCE の構成を後続のフレームへ引き継ぐ。**
  コピーでは aac_adtstoasc が最初のフレームから構成を作るので、先頭の1〜2フレームだけ違っても全編が壊れる（3フレームの確定条件で捨ててはいけない）。
  ffmpeg などは PCE を最初のフレームにしか書かず、後続の channel_configuration 0 のフレームは先頭が SCE になる。引き継がないと、5.1ch を ARIB 式のデュアルモノ（2ch）と取り違えて `-ac 2` でダウンミックスする。
- **ARIB 式のデュアルモノ（channel_configuration 0、PCE なし）を含む録画と、チャンネル数を判定できない区間を含む切り替えは、変換を止める（`AudioLayoutReport.checkConvertible`）。**
  ffmpeg 9 の aac デコーダは前者を1フレームも復号できず、その区間が無音になり、Apple では以降の音声がずれる。後者は `-ac` を決められず、5.1ch を落とすおそれがある。
- **再エンコードでは `-af aresample=async=1` を付ける。**
  復号できなかったフレームは MP4 に duration の穴として残り、AVFoundation は穴を詰めて鳴らすため、音声が映像より先に進む。
- **`aac_at` には `-channel_layout 5.1` を渡さない。**
  aac_at は `5.1(side)` しか受け付けず、`5.1` を指定すると起動時に失敗する。`-ac 6` だけならレイアウトを ffmpeg が選ぶ。
- **`ProcessRunner` のストリーミング版は、プロセスの終了を待ったあと、タスクの中でキャンセルを確かめる。**
  `DispatchGroup.notify` のクロージャは Swift のタスクの外で動くため、そこで `Task.isCancelled` を見ても常に false になる。
  ffmpeg は SIGTERM を受けると終了コード 255 で終わるので、確かめないとキャンセルが「失敗」として扱われる。

## コーディング方針

- Swift Concurrency（async/await、`TaskGroup`）を使う。`DispatchQueue` は `ProcessRunner` の内部のような、必要な箇所に限る。
- UI の状態を持つクラスは `@Observable`。UI を触るメソッドには `@MainActor` を付ける。クラス全体を `@MainActor` にはしない（`@State` の初期化で問題が出るため）。
- エラーは `LocalizedError` に準拠させ、`errorDescription` に何が起きたか、`recoverySuggestion` にどうすれば直るかを書く。「エラーが発生しました」で終わらせない。
- **実行した ffmpeg / ffprobe のコマンドは必ず全文をログに残す。**
  GUI で組んだ設定がどのコマンドになったかを確認して、ターミナルで再現できることが重要。`ProcessRunner.commandLine(executable:arguments:)` を使う。
- UI の文言は能動態・常体で短く。ボタンは何が起きるかを書く（「実行」ではなく「変換を開始」）。

## やらないこと

- 動画編集機能（カット編集、エフェクト、合成）
- ディスクオーサリング
- App Sandbox の有効化
- ffmpeg のバンドル同梱
- Intel Mac / macOS 13 以下への対応
