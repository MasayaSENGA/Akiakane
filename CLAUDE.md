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

アプリのソースと `Assets.xcassets` は `Akiakane/`、テストは `AkiakaneTests/`、アイコンを描くスクリプトは `Scripts/` にある。

| ファイル（`Akiakane/` 内） | 役割 | 状態 |
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
| `OrphanedFFmpeg.swift` | 変換中の ffmpeg の記録と、異常終了後に取り残された ffmpeg の後始末 | 完成 |
| `FFProbeReport.swift` | ffprobe の JSON デコード用 | 完成 |
| `MediaInfo.swift` | アプリが扱うメタデータのドメインモデル | 完成 |
| `FFProbeRunner.swift` | ffprobe 実行、および入力ファイルの収集 | 完成 |
| `AkiakaneTests/` | `makeArguments`・音声の扱いの決定・ADTS の解析・ffprobe の JSON・`ProcessRunner` のキャンセル・`FFmpegRunner` の完了処理（偽の ffmpeg を使う）・同じファイルの判定・進捗パーサ・出力先命名・設定保存のユニットテスト | 通過 |

ステップ4（1ファイルの変換・進捗・キャンセル）とステップ5（キュー管理・設定 UI）まで実装済み。
実機での一括変換の動作確認はこれから。

### テスト

```bash
xcodebuild -project Akiakane.xcodeproj -scheme Akiakane -configuration Debug test -destination 'platform=macOS'
```

`Akiakane/` と `AkiakaneTests/` は Xcode の同期フォルダ（`PBXFileSystemSynchronizedRootGroup`）で、置いたファイルがそのまま各ターゲットに入る。
新しいソースやテストを足すときに `project.pbxproj` を編集する必要はない。アプリのソースをリポジトリ直下に置かないこと（下の設計上の決定を参照）。

## 設計上の決定と、その理由

書き換える前に理由を確認すること。いずれも実際に踏んだ問題への対処である。

- **アプリの同期フォルダは `Akiakane/` で、リポジトリ直下ではない。**
  以前はリポジトリ直下全体をアプリの同期フォルダにしていたため、README の手順（`-derivedDataPath build`）で作られた `build/` を
  次のビルドが取り込み、「Multiple commands produce」で以後のビルドがすべて失敗した。README・CLAUDE.md・gitignore 対象のメモまで .app に同梱されていた。
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
- **出力は `<最終名>.<実行ごとの8文字>.partial` に書き、成功後にリネームする。そのため `-f mp4` などコンテナ形式を必ず明示する。**
  ffmpeg は拡張子から形式を推定するので、`.partial` 名のままだと起動時に「Unable to choose an output format」で失敗する。
  名前を固定にすると、アプリの異常終了で取り残された ffmpeg と、再起動後の同じファイルの変換が同じ `.partial` に書き込み、壊れた出力が「完了」になった。
- **動いている ffmpeg を UserDefaults に記録し、次の起動時に、持ち主のアプリがもう動いていなければ止める（`OrphanedFFmpeg`）。**
  ffmpeg は親が死んでも止まらない（SIGPIPE を無視し、進捗を書けなくても続ける）。記録には ffmpeg と持ち主のアプリの PID と開始時刻を残す。
  PID は再利用されるので開始時刻でも照合する。持ち主を見ないと、Release 版の変換中に Debug 版を起動したときや、並列に動くテストのほかのプロセスの ffmpeg を止めてしまう（実際にテストで起きた）。
- **実行するコマンドは `ProcessRunner` が起動の直前に、`~/Library/Logs/Akiakane/commands.log`（`CommandLogFile`）と `os.Logger`（サブシステムはバンドル ID、カテゴリ command）へ残す。**
  `#if DEBUG` の `print` だけでは、README の手順で入れる Release 版ではまったく残らなかった。`Process` を直接使わず、必ず `ProcessRunner` を通す。
  統合ログは1件あたり約 1KB で切り詰めるので、全文はファイルに書く（長い番組名と深い NAS のパスで末尾が消えた）。
  `commandLine` は、シェルで意味を持つ文字を含む引数をシングルクォートで囲む。放送録画のファイル名によくある `[字]` は zsh のグロブになるため、空白だけのクォートでは再現できなかった。
- **音声をコピーする設定でも、出力の形式に入らないコーデックや、入れても Apple 製アプリで鳴らないコーデックは変換する（`Container.canCopyAudio` / `losslessPCMCodec`）。**
  wmav2・pcm_u8・adpcm_ima_wav などを MP4 にコピーすると、ffmpeg は起動直後に失敗する。MP3 は MP4 に書けても、AVFoundation が音声トラックごと無視する（MOV なら鳴る）。
  MKV も Blu-ray / DVD / 放送の LPCM（pcm_bluray / pcm_dvd / s302m）は書けないので、MOV / MKV ではこれらを無劣化の pcm_s24le に、MP4 では AAC にする。
  `aac_adtstoasc` は TS の AAC にだけ付ける。AVCHD の AC-3 などに付けると失敗する。TS の AC-3 を MOV にコピーするときは `-tag:a ac-3` を付ける（既定の `AC-3` では Apple 製アプリで鳴らない）。
- **AAC に変換するときは、チャンネル数を必ず `-ac` で明示する。8ch は内蔵の `aac`、48 kHz を超える音声は `-ar 48000` にする。**
  `aac_at` はレイアウトの交渉で 7.1ch を 7.0（LFE を捨てる）、2.1ch をステレオに落とす。`-ac 8` を渡すとチャンネルの割り当てが崩れるので、7.1ch には使えない。
  `aac_at` は 96 / 192 kHz を受け付けず、起動直後に失敗する（'fmt?'）。
- **フォルダの走査では、パッケージのうち AVCHD / BDMV（`public.audiovisual-content-collection` に適合するもの）の中には入る。**
  macOS はこれらをパッケージとして扱うので、`.skipsPackageDescendants` ではビデオカメラの SD カードをドロップしても1本も拾えなかった。
- **ffprobe の解析は、キューに1本だけあるループで順に行う。**
  ドロップのたびに解析のタスクを作ると、続けてドロップしたときに ffprobe が並列に走り、同じファイルが二重に登録された。
- **出力先を決めるとき、キューのほかの項目の入力と、このバッチで書き出した出力は予約済みとして扱い、「上書きする」でも別名にする（`makeOutputPlan` の `isReserved`）。**
- **プロジェクトの既定 actor 分離は MainActor（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）。**
  パイプの読み取りスレッドから呼ばれるクラス（`LineSplitter`、`OutputCollector`、`FFmpegProgressAccumulator`、`ProgressRelay`、`ADTSLayoutParser` など）は
  `nonisolated` を明示する。付けないと「main actor-isolated ... in a synchronous nonisolated context」の警告が出る。
- **出力先の決定（`makeOutputPlan`）は入力そのものと同じパスになる場合に `_h265` を強制する。**
  接尾辞を空にして同じフォルダ・同じコンテナで変換すると、入力ファイルを上書きしてしまうため。
- **同じファイルかどうかは `refersToSameFile` で判定し、パスの文字列比較はしない。**
  macOS 既定の APFS は大文字小文字を区別しない。`CLIP.MP4` の出力候補 `CLIP.mp4` を別物と判定すると、「上書きする」で入力が削除され出力に置き換わった。
  実在するファイルは `fileResourceIdentifier` で、無ければ大文字小文字を無視したパスで比べる。`FFmpegRunner` も、出力先を削除する直前に同じ確認をする。
  識別子が違っても、名前・大きさ・更新日時が同じなら同じとみなす（同じ共有の二重マウントや FUSE では、同じファイルが別の識別子で見える）。迷ったら同じとみなす。誤っても接尾辞が付くだけで済む。
  名前が大文字小文字を除いて違えば、ファイルシステムに問い合わせずに別物とする。SwiftUI の描画中にも呼ばれるので、既定の設定で余計な stat をしない。
- **ffmpeg が終了コード 0 でも、標準エラーに `Error during demuxing` があれば失敗にする（`inputReadError` / `inputReadFailure`）。**
  ffmpeg は入力の読み取りエラー（NAS の切断など）を EOF として扱い、途中までの出力を確定させて正常終了する。見逃すと尻切れの出力が「完了」になる。
  `-xerror` はデコードエラーでも止まるので、受信エラーのある放送 TS には使えない。放送 TS の受信エラーや末尾の切れでは、この行は出ない（60通り以上で確認済み）。
  行の末尾が I/O 系のエラー（`Input/output error`、`Operation timed out` など）なら接続の問題として再試行を勧め、それ以外（壊れた AVI や MP4 の `Cannot allocate memory` など）はファイルの破損として扱う。
- **静止画かどうかは ffprobe の `disposition`（`attached_pic` / `timed_thumbnails` / `still_image`）で判定し、`-map` はストリームの番号（`0:<index>`）で指定する。**
  コーデック名（mjpeg など）で判定すると、Motion-JPEG の動画を静止画扱いにして、映像のない出力を作った。
  `0:v:0` は映像の中での順番なので、静止画が本編より前にあると、解析したものと別のストリームを変換する。
- **MPEG-TS の AAC 音声は、変換の前にファイル全体の ADTS ヘッダを走査する（`AudioLayoutScanner`）。**
  放送は録画の途中でチャンネル構成が変わる（CM はステレオ、本編は 5.1ch など）。MP4 / MKV の AAC は構成を1つしか持てないため、
  コピーすると切り替え以降が再生できない。デュアルモノは切り替えがなくても Apple で再生できない。どちらも ffmpeg は終了コード 0 で終わる。
  ffprobe のストリーム情報は冒頭の構成しか示さないので、全フレームを見る必要がある。
- **5.1ch はダウンミックスしない。構成が1つならコピーし、切り替えやデュアルモノがあるときだけ、全体の最大チャンネル数を `-ac` で指定して AAC に変換する。**
  `-ac` を付けずに再エンコードすると、ffmpeg は最初のフレームの構成でエンコーダを作る。冒頭がステレオの録画では、本編の 5.1ch が黙ってステレオに落ちる。
  ffmpeg だけで無劣化のまま切り替えを保つ方法（fMP4、MKV、TS 出力など）は、どれも Apple で再生できなかった。
- **`ADTSLayoutParser` は先頭のフレームの構成を必ず区間として残し、PCE の構成を後続のフレームへ引き継ぐ。**
  コピーでは aac_adtstoasc が最初のフレームから構成を作るので、先頭の1〜2フレームだけ違っても全編が壊れる（3フレームの確定条件で捨ててはいけない）。
  ただしこの区間は壊れたフレームのこともあるので（`leadingSegmentIsUnconfirmed`）、`checkConvertible` で変換を止める理由にはしない。
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
  GUI で組んだ設定がどのコマンドになったかを確認して、ターミナルで再現できることが重要。`ProcessRunner` で起動すれば、`ProcessRunner.logCommand` が自動で残す。
- UI の文言は能動態・常体で短く。ボタンは何が起きるかを書く（「実行」ではなく「変換を開始」）。

## やらないこと

- 動画編集機能（カット編集、エフェクト、合成）
- ディスクオーサリング
- App Sandbox の有効化
- ffmpeg のバンドル同梱
- Intel Mac / macOS 13 以下への対応
