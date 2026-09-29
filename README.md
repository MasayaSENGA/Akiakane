# Akiakane

macOS 用の動画一括変換アプリ。放送録画由来の `.ts` / `.m2ts` や既存の H.264 ファイルを、ffmpeg を使って H.265 に変換する。

もとは作者が自分の録画を整理するために作ったもので、ソースコードのみを公開している。変換処理は ffmpeg に委譲し、このアプリは **フロントエンドとキュー管理** に徹する。独自のエンコード実装や編集機能は持たない。

ビルド済みのアプリは配布していない。使うには clone して Xcode でビルドする。動作の保証やサポートは行わないが、Issue や Pull Request は歓迎する。

## 動作環境

- macOS 14.0 以降、Apple Silicon
- Homebrew の ffmpeg / ffprobe（`brew install ffmpeg`）
- Xcode 26 以降（ビルド用）

App Sandbox は無効にしてある。有効にすると `Process` から ffmpeg を起動できなくなる。コード署名と公証もしていないため、App Store には出せない。

## インストール

```bash
brew install ffmpeg
git clone https://github.com/MasayaSENGA/Akiakane.git
cd Akiakane
open Akiakane.xcodeproj
```

Xcode で `Akiakane` スキームを選んで Run する。Signing はローカルの「Sign to Run Locally」のままでよい。
初回起動時に ffmpeg が見つからないと表示されたら、⌘, の設定ウインドウで実行ファイルのパスを指定する。

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
| 音声 | コピー（必要なときだけ AAC に変換）/ AAC に変換（ビットレート指定）/ 含めない |
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

### 放送 TS の音声

放送の録画は、途中で音声のチャンネル構成が変わることがある（前後の CM はステレオ、本編は 5.1ch など）。二か国語放送（デュアルモノ）もある。MP4 / MKV の AAC は構成を1つしか持てないため、そのままコピーすると、切り替え以降の音声が再生できなくなる。デュアルモノは、切り替えがなくても Apple 製のアプリで再生できない。ffmpeg はこの場合もエラーを出さずに終わる。

そこで、`.ts` / `.m2ts` / `.mts` の AAC 音声は、変換の前にファイル全体の ADTS ヘッダを読んで構成を調べる。音声はデコードしないので、所要時間はディスクの読み出し速度で決まる（SSD で十数秒まで、HDD や NAS では数分）。

```
ffmpeg -hide_banner -nostdin -loglevel error -i input.ts -map 0:a:0 -c copy -f data pipe:1
```

- 構成が1つだけなら、設定どおりコピーする。5.1ch は無劣化のまま 5.1ch で残る
- 途中で切り替わるか、デュアルモノなら、そのファイルだけ AAC に変換する。全体での最大チャンネル数を `-ac` で指定し、5.1ch を 5.1ch のまま保つ（例: `-af aresample=async=1 -c:a aac_at -b:a 384k -ac 6`）。ステレオの区間は前方の左右に入り、残りのチャンネルは無音になる
- 先頭の1〜2フレームだけ構成が違う場合も、コピーすると全編が再生できなくなるので AAC に変換する（コピーは最初のフレームの構成で全編を書くため）
- デュアルモノは、主音声が左、副音声が右に入る
- 「AAC に変換」を選んだ場合も、同じ走査の結果でチャンネル数を指定する。`-ac` がないと ffmpeg は最初のフレームの構成でエンコーダを作るため、冒頭がステレオの録画では本編の 5.1ch がステレオに落ちる
- 再エンコードでは `aresample=async=1` で、受信エラーなどで復号できなかったフレームの分を無音で補う。補わないと Apple 製のアプリでは音声が映像より先に進む
- AAC のエンコーダは、ffmpeg に Apple の AudioToolbox（`aac_at`）があればそれを、なければ内蔵の `aac` を使う。ビットレートはステレオが基準で、5.1ch では2倍にする

どう扱ったかは、変換中と完了後の詳細画面に出る。

次の場合は、音声を失わないよう変換を止めて理由を表示する。音声が不要なら「音声を含めない」にすれば変換できる。

- ARIB 式の二か国語（channel_configuration 0、PCE なし）を含む。ffmpeg はこの形式を復号できず、変換するとその区間が無音になり、以降の音声もずれる
- 構成が途中で変わり、一部の区間のチャンネル数を判定できない。5.1ch をステレオに落とすおそれがある

走査するのは `.ts` / `.m2ts` / `.mts` の AAC 音声だけ。AC-3 など他のコーデックの TS で途中にチャンネル数が変わる場合は、「AAC に変換」で 5.1ch がステレオに落ちることがある（日本の放送 TS は AAC なので該当しない）。

## ビルドとテスト

```bash
xcodebuild -project Akiakane.xcodeproj -scheme Akiakane -configuration Debug build
xcodebuild -project Akiakane.xcodeproj -scheme Akiakane -configuration Debug test -destination 'platform=macOS'
```

ユニットテストは ffmpeg を起動せず、引数の組み立て、音声の扱いの決定、ADTS ヘッダの解析、`-progress` 出力のパース、出力先の命名、設定の保存を検証する。`ProcessRunner` のテストだけは `/bin/sleep` などの macOS 標準コマンドを起動する。

### 自分用の .app を作る

Release 構成でビルドして `/Applications` に置く。署名はアドホック（Sign to Run Locally 相当）なので、ビルドした Mac ではそのまま起動できる。

```bash
xcodebuild -project Akiakane.xcodeproj -scheme Akiakane -configuration Release -derivedDataPath build build
ditto build/Build/Products/Release/Akiakane.app /Applications/Akiakane.app
```

コードを更新したら同じコマンドで上書きする。`build/` は `.gitignore` で除外している。
別の Mac にコピーした場合は未署名扱いになるため、初回は「システム設定 → プライバシーとセキュリティ → このまま開く」が必要になる。

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
| `EncodeSettings.swift` | 設定モデル、音声の扱いの決定、ffmpeg 引数の組み立て、出力先の決定 |
| `AudioLayoutScanner.swift` | 変換前の音声の走査（チャンネル構成の切り替えとデュアルモノの検出） |
| `FFmpegRunner.swift` | ffmpeg の実行と進捗のパース |
| `FFProbeRunner.swift` | ffprobe の実行と入力ファイルの収集 |
| `FFProbeReport.swift` / `MediaInfo.swift` | ffprobe の JSON とドメインモデル |
| `ProcessRunner.swift` | 外部プロセスの async 実行基盤 |
| `FFToolLocator.swift` | ffmpeg / ffprobe のパス解決 |
| `Scripts/DrawIcon.swift` | アプリアイコンを CoreGraphics で描くスクリプト。アプリには含まれない |

プロジェクトをゼロから作り直す場合の Xcode 設定手順は `SETUP.md` にある。開発時の前提や設計上の決定は `CLAUDE.md` にまとめている。

## やらないこと

- 動画編集（カット、エフェクト、合成）
- ディスクオーサリング
- App Sandbox の有効化、コード署名、公証、App Store やビルド済みバイナリでの配布
- ffmpeg の同梱
- Intel Mac / macOS 13 以下への対応

## ライセンス

MIT License。詳細は `LICENSE` を参照。

ffmpeg / ffprobe はこのリポジトリに含まれておらず、利用者が Homebrew などで別途インストールしたものを外部プロセスとして起動する。ffmpeg 自体のライセンスは ffmpeg のビルド構成に従う。
