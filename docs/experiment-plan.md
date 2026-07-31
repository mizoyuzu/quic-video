# 実験計画

## 目的

単なる平均遅延ではなく、次のどこで遅延・欠落・キュー滞留が生じるかを再現可能な形で特定します。

- iOSカメラ取り込み
- VideoToolboxエンコード
- MoQ publishとQUIC送信
- Wi-Fi/LAN
- relay転送
- OBS plugin受信とFFmpegデコード
- OBSレンダリング

最終用途はライブシーンのIMAGです。iOS 18+の対応端末を対象にし、端末が対応しないプリセットはUIで無効化します。iPhone撮影からOBS表示までのend-to-end遅延p95 100ms未満を目標値として測定します。30分本試験ではframe drop率0.5%以下、500ms以上のfreezeなし、keyframe待ちp95 1秒未満、エラーなしを合格条件とします。

初期アプリで選択可能にする解像度とfpsは次の6通りです。端末が対応しない組み合わせはUIで無効化します。

| Preset | Resolution | FPS |
|---|---:|---:|
| SD30 | 854x480 | 30 |
| SD60 | 854x480 | 60 |
| HD30 | 1280x720 | 30 |
| HD60 | 1280x720 | 60 |
| FHD30 | 1920x1080 | 30 |
| FHD60 | 1920x1080 | 60 |

## Phase 0: 依存関係の固定

- macOS、Xcode、iOS実機、OBS Studioのバージョンを記録する
- `moq-dev/moq`、`moq-swift`、`moq-swift-ffi`のリリースまたはcommitを記録する
- relay、OBS plugin、Swift packageが同じMoQ wire実装を使うことを確認する
- Apple Siliconの実機・Macでビルドする
- デバッグ用self-signed TLSはfingerprint pinningで接続し、証明書検証無効化を常用しない

## Phase 1: OBS受信経路だけを確認

### 手順

1. Mac上でrelayを起動する
2. `obs-moq`をビルドしてOBSにインストールする
3. 既存のMoQ publisherまたはテストデータをrelayへ送る
4. OBSのMoQ Sourceでbroadcastをsubscribeする
5. OBSログ、relayログ、qlogの保存場所を確認する

### 合格条件

- OBSがMoQ Sourceを作成できる
- H.264のキーフレームから表示を開始できる
- relay再起動、publisher停止、再接続時のログが残る
- 接続URLに含まれるtokenがログに残らない

## Phase 2: iOSエンコード単体

### 対象

- H.264 / `avc1`
- HEVC / `hvc1`

### 記録項目

- 実機モデルとOS
- 入力解像度、出力解像度、fps
- VideoToolbox codec type、profile、平均bitrate、GOP
- `AllowFrameReordering`
- 1フレームあたりのencode時間
- 出力access unitサイズ
- keyframe間隔
- SPS/PPSまたはVPS/SPS/PPSの付加有無
- AVCC/HVCC parserの結果

### 合格条件

- 1000フレーム以上でPTSが単調増加する
- catalogのdescriptionに必要なAVCC/HVCCが含まれる
- 1フレームのエンコードでcapture callbackがブロックしない
- H.264/HEVCそれぞれの出力をmacOSのFFmpegでデコードできる

## Phase 3: MoQ end-to-end

### 基準マトリクス

| Case | Codec | Resolution | FPS | GOP | Bitrate |
|---|---|---:|---:|---:|---:|
| A | H.264 | 854x480 | 30 | 30 | 0.8 Mbps |
| B | H.264 | 854x480 | 60 | 60 | 1.2 Mbps |
| C | H.264 | 1280x720 | 30 | 30 | 2 Mbps |
| D | H.264 | 1280x720 | 60 | 60 | 4 Mbps |
| E | H.264 | 1920x1080 | 30 | 30 | 5 Mbps |
| F | H.264 | 1920x1080 | 60 | 60 | 8 Mbps |
| G | HEVC | 1280x720 | 30 | 30 | 1.5 Mbps |
| H | HEVC | 1280x720 | 60 | 60 | 2.5 Mbps |
| I | HEVC | 1920x1080 | 30 | 30 | 3.5 Mbps |
| J | HEVC | 1920x1080 | 60 | 60 | 6 Mbps |
| K | HEVC | 854x480 | 30 | 30 | 0.48 Mbps |
| L | HEVC | 854x480 | 60 | 60 | 0.72 Mbps |

実際のビットレートは端末と映像内容で変わるため、表は比較用の初期値です。

### 接続条件

- Wi-Fi 5GHz、アクセスポイントから1m
- Wi-Fi 5GHz、アクセスポイントから距離を置いた状態
- 有線接続Macを受信側にした状態
- 他のトラフィックを発生させた状態

### 収集するログ

- iOSのJSONL
- relayのstructured log
- OBS/`obs-moq`のログ
- QUIC qlog（取得できた場合）
- 端末モデル、Wi-Fi band/channel、RSSI、リンク速度
- 実験開始・終了時刻と設定ハッシュ

## Phase 4: 低遅延パラメータ探索

次のパラメータを一つずつ変更し、他を固定します。

- `latencyMaxMs`: 0、50、100、200
- GOP: 15、30、60
- 720p30と720p60
- H.264とHEVC
- 60fps H.264と30fps HEVC
- 送信キュー容量: 1、2、4、8
- bitrate固定と、QUIC推定帯域への追従

## 遅延の測り方

異なる端末のmonotonic clockを直接引き算しません。初期段階では次の2種類を分けます。

### ソフトウェア計測

- iOS frameに`frame_id`とcapture wall timeを紐付ける
- QUIC sessionのRTTとMoQ統計を定期保存する
- OBS pluginで受信、decode開始、decode完了時刻を保存する
- 接続開始時に小さなclock offset測定を行い、wall time差の推定値をログへ残す

これは原因切り分け用であり、表示遅延の絶対値として扱いません。

### 実測

表示遅延を最終評価する場合は、背面カメラの被写体側に高精度の時刻表示を置き、OBS出力を240fpsで撮影します。カメラ、表示器、撮影側の遅延を別途測り、ソフトウェア計測と突き合わせます。

## 初期の判定基準

合格判定は30分本試験でp95 end-to-end 100ms未満、frame drop率0.5%以下、500ms以上のfreezeなし、keyframe待ちp95 1秒未満、エラーなしとします。比較時は、次を「良い/悪い」の二値にせず、p50、p95、最大値、ドロップ数で記録します。

- capture-to-encode p50/p95
- encode-to-publish p50/p95
- publish-to-receive p50/p95
- receive-to-render p50/p95
- end-to-end実測値
- frame drop率
- freeze時間と連続freeze回数
- keyframe待ち時間
- RTT、packet loss、再送量
- reconnect時間

## 実験中に必ず保存するメタデータ

- `session_id`
- git commitと依存packageのversion
- iPhone model identifier、iOS version
- Mac model、macOS version、OBS version
- 実験端末のmodel identifier、iOS version
- codec/profile、解像度、fps、bitrate、GOP
- relay/OBS plugin設定
- Wi-Fi band、channel、RSSI、リンク速度
- log level、detail loggingの有無
- 実験者が記入する異常メモ

## 次に実装する最小スコープ

1. この資料の内容を実験設定として固定する
2. Macで既存relayと`obs-moq`を起動する手順を検証する
3. iOS Swift Packageの最小接続サンプルを作る
4. `VTCompressionSession`からH.264 access unitを取り出す
5. 1つのbroadcast、1つの`avc1` track、非同期JSONL loggerを追加する
6. `Session.stats()`の1秒周期snapshotを同じJSONLへ記録する
7. H.264 720p60を基準にPhase 3を実施する
