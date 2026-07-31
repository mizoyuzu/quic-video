# アーキテクチャ検討

## 1. 想定構成

```text
┌──────────────────────────────┐
│ iPhone / iPad                 │
│                              │
│ AVCaptureSession              │
│   -> CVPixelBuffer            │
│   -> VTCompressionSession     │
│   -> AVCC/HVCC access unit    │
│   -> Moq MediaProducer        │
└──────────────┬───────────────┘
               │ native QUIC / LAN Wi-Fi
               v
┌──────────────────────────────┐
│ macOS                        │
│                              │
│ moq-relay (local)             │
│   -> obs-moq source           │
│   -> FFmpeg decode            │
│   -> OBS Studio               │
└──────────────────────────────┘
```

ここでのrelayはインターネット向けCDNではありません。受信側Mac上に置き、iOSからMacへ向かうネットワーク上の接続を受け付けるための小さなMoQ endpointです。relayが同一Mac上で動くため、iOSからMacまでのネットワークホップは1つです。

IPアドレスとポートの手入力に加え、Mac補助サービスがBonjourでrelayを広告します。LAN relayの証明書はmkcertで作成し、MacではローカルCAを信頼し、iOS側ではfingerprint pinningを使います。

## 2. 既存実装の採用

### iOS送信

第一候補は次の構成です。

- Swift Package: `moq-dev/moq-swift`
- ネイティブバインディング: `MoqFFI.xcframework`
- セッション: `Moq.Client`、`Moq.Session`
- 映像公開: `BroadcastProducer.publishMedia(format:initData:)`
- フレーム投入: `MediaProducer.writeFrame(_:timestampUs:)`
- 接続統計: `Session.stats()`

`Moq`の既存APIは、エンコード済みのアクセスユニットとPresentation Timestampを受け取る設計です。したがって、アプリ側の責務は次の範囲に限定できます。

- カメラ入力の取得
- VideoToolboxでのH.264/HEVCエンコード
- VideoToolboxのAVCC/HVCC初期データの抽出
- length-prefixed access unitのMoQ media trackへの投入
- PTSと診断ログの付与

`AVAssetWriter`はファイル・コンテナ向けのバッファリングが入りやすいため、低遅延の最初の実装では使いません。

### macOS/OBS受信

第一候補は`moq-dev/moq`に含まれる`cpp/obs`の`obs-moq`です。現在のプラグインはMoQ relayへのpublishと、MoQ broadcastをOBS sourceとしてsubscribeする両方を実装しており、macOS arm64向けのビルド・リリース経路があります。

ただし、プラグインはWIPで、署名済みの完成品SDKとは扱わない方が安全です。最初は既存プラグインをビルドして動作確認し、必要なログや接続設定だけを小さく改修します。

`cpp/obs`はOBSの`libobs`にリンクするためGPL-2.0-or-laterです。Rust、C FFI、Swift wrapper、通常のMoQ crateとはライセンス条件が異なるため、配布時に分離して扱います。

## 3. コーデック比較

| 候補 | iOS送信 | OBS/macOS受信 | 低遅延候補 | 初期評価 |
|---|---|---|---|---|
| H.264 / `avc1` | VideoToolboxで広く利用可能 | FFmpegで広い | AVCC、B-frame無効、短いGOP | 第一候補 |
| HEVC / `hvc1` | 対応端末ではVideoToolboxハードウェア利用可能 | FFmpegで利用可能だが設定差を確認 | HVCC、H.264より帯域効率が期待できる | 第二候補 |
| AV1 | iOS側のハードウェアエンコード可否を端末ごとに確認する必要がある | OBS側候補にはある | 実装・端末互換性のリスクが高い | 初期対象外 |

IMAGでは画質だけでなく動きの連続性、カメラパン時の破綻、キーフレーム待ち時間が重要です。iOS 18+の対応端末を対象にし、480p/720p/1080pと30fps/60fpsを設定で選べるようにします。100ms未満はiPhone撮影からOBS表示までの最終目標ですが、カメラ、エンコード、Wi-Fi、relay、FFmpeg、OBS表示の合計値なので、各段階を個別に記録します。

初期アプリでは次の6プリセットを選択可能にします。

| Preset | Resolution | FPS |
|---|---:|---:|
| SD30 | 854x480 | 30 |
| SD60 | 854x480 | 60 |
| HD30 | 1280x720 | 30 |
| HD60 | 1280x720 | 60 |
| FHD30 | 1920x1080 | 30 |
| FHD60 | 1920x1080 | 60 |

コーデックはH.264とHEVCを同じプリセットから選択できる設計にします。最初の比較では、少なくとも以下を同じ計測条件で実施します。

- 6プリセットのH.264
- 6プリセットのHEVC

H.264は互換性を優先した基準値、HEVCは同画質・低帯域の候補として比較します。HEVCが常に低遅延になるとは仮定しません。端末のVideoToolbox実装、OBSのFFmpegデコーダ、Wi-Fiの帯域変動を別々に計測します。

## 4. 低遅延の設定方針

- VideoToolboxのリアルタイムモードを有効にする
- B-frame/フレーム並べ替えを無効にする
- GOPはまず1秒程度、つまり30fpsなら30フレームを基準にする
- 新規購読者が待つ時間とキーフレームの帯域増加を計測してGOPを調整する
- MoQの購読側は`latencyMaxMs`を小さくし、古いgroupを待ち続けない
- groupは新しいものを優先し、詰まりが発生した場合に古い映像を捨てる
- エンコード入力キューは有界にし、満杯なら最古フレームを捨てる
- 送信処理をカメラcapture callback内でブロックしない
- フレーム処理の各段階で滞留時間を計測する
- IMAGの画質を維持できる範囲で、古いフレームを捨ててライブエッジを優先する

映像フレーム全体は通常1200バイトを超えるため、QUIC datagramを映像本体の搬送に使うことは初期案にしません。MoQのmedia trackとgroup/stream経路を使い、datagramは将来の小さなメタデータや制御情報用に限定します。

現行Swift APIではmedia trackのpublisher-side `latency_max`や`ordered`を十分に細かく指定できない可能性があります。必要なら`moq-ffi`にmedia publish optionsを追加するのが、プロトコルを自作するより小さい拡張です。

## 5. ログと計測

### 保存形式

アプリ独自の構造化JSON Linesを正とします。`os.Logger`はConsoleでの即時確認に併用し、後で解析するデータはApplication Support配下のファイルに書きます。

```text
Application Support/
  quic-video/
    logs/
      session-<uuid>.jsonl
      session-<uuid>.qlog
```

通常モードでは1秒ごとの集計、接続状態、エラー、キーフレーム、ドロップ数を記録します。診断モードではフレーム単位のイベントを追加します。

### 共通イベント項目

- `schema_version`
- `session_id`
- `role` (`ios_publisher` / `relay` / `obs_subscriber`)
- `event`
- `wall_time`
- `monotonic_us`
- `frame_id`
- `media_pts_us`
- `codec`, `width`, `height`, `fps`
- `payload_bytes`
- `queue_depth`
- `drop_reason`
- `rtt_us`, `send_rate_bps`, `bytes_sent`, `bytes_lost`, `packets_lost`
- `error_domain`, `error_code`, `error_message`

URLのtoken、認証情報、完全な接続文字列は保存しません。ログに残す接続先はscheme、host、portまでに正規化します。

### 計測する段階

```text
capture -> encode_submit -> encode_done -> moq_write
        -> relay/transport -> obs_receive -> decode_done -> render
```

MoQ Swift側には`Session.stats()`があり、RTT、帯域推定、送受信バイト、損失カウンタを周期取得できます。qlogは`moq-native`側に実装がありますが、現在のSwift FFIから保存先を設定するAPIは不足しているため、診断時に取得できた場合だけ保存します。

## 6. 主要なリスク

- `moq-transport`はIETF draftであり、実装間のwire compatibilityをリリースごとに確認する必要がある
- `moq-dev/moq`は`moq-lite`を中心に実装しており、対象relayとOBS pluginのプロトコルバージョンを固定する必要がある
- iOS向けXCFrameworkが対象アーキテクチャとiOS 18の実機で動くことを確認する必要がある
- self-signed TLSをLANで使う場合、証明書fingerprintまたはローカルCAを安全に配布する必要がある
- 既存`obs-moq`のmacOSビルドはOBS/FFmpeg依存と署名・配布の問題がある
- frame単位ログはI/Oで映像処理を遅くするため、非同期writerとサンプリングが必要
- iOSがバックグラウンドへ移行した場合のカメラ、Network、ログ継続性は別途検証が必要
- IMAG用途では映像の大きな破綻や長いfreezeが許容されにくいため、100ms目標とドロップ率のトレードオフを実映像で判断する必要がある

## 7. 採用判断の順序

1. macOSでrelayと`obs-moq`を動かし、既存サンプル映像をOBSで表示する
2. iOSでH.264の1フレームエンコード結果を保存し、AVCC/`avc1`としてOBSがデコードできることを確認する
3. iOSからH.264 720p30を送信し、接続統計とアプリログを保存する
4. H.264のGOP、キュー、MoQ latency設定を変えて低遅延特性を測る
5. HEVCを同じパイプラインに追加して比較する
6. 必要な箇所だけ`moq-ffi`と`obs-moq`を拡張する
