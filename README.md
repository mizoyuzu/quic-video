# quic-video

iOS 18+端末のカメラ映像を、LAN/Wi-Fi環境でMedia over QUIC (MoQ)により低遅延転送し、macOS上のOBS Studioで受信するための実験リポジトリです。

## 現時点の方針

- iOS送信、macOS上のOBS受信を対象にする
- 1対1のLAN利用を基本にする
- macOS側で既存のMoQ relayを動かし、ネットワーク上のQUIC endpointとして使う
- 受信表示は既存の`obs-moq`プラグインを優先して使う
- iOSのMoQ接続は`moq-dev/moq`のSwift Packageを第一候補にする
- 映像のみで開始し、音声は後で追加する
- 通常時は集計ログ、診断時はフレーム単位ログを保存し、qlogは取得できた場合だけ保存する
- iOS 18+端末を対象にし、端末が対応しないプリセットはUIで無効化する
- 最終用途はライブシーンのIMAGを想定し、初期目標は実測end-to-end遅延100ms未満とする
- 背面カメラを入力とし、480p/720p/1080pと30fps/60fpsを設定で選べるようにする

## 実装状況

- `ios/QuicVideo.xcodeproj`: SwiftUIのiOS送信アプリ
- `mac/relay`: `moq-relay`のLAN実験設定とmkcert手順
- `mac/BonjourAdvertiser`: relayをBonjourで発見するためのmacOS補助サービス
- `obs-moq`: upstreamの`obs-moq`へ遅延設定と診断JSONLを追加するpatch
- `web`: `@moq/watch`を使ったブラウザ受信画面

## ブラウザで見る

Mac上でrelayを起動した後、別のターミナルで次を実行します。

```bash
./web/start.sh
```

ChromeまたはEdgeで <http://localhost:8080> を開き、iOSアプリの
`Broadcast path`とrelay URL（通常は`https://localhost:4443`）を入力します。
初回は先に`./mac/relay/setup-cert.sh`を実行して、relayの証明書をMacで信頼してください。

VideoToolboxの出力はAVCC/HVCCのlength-prefixed access unitなので、MoQのsingle-codec
media formatには`avc1`/`hvc1`を使います。`avc3`/`hev1`のAnnex-B経路は初期実装の対象外です。

## 重要な前提

既存のMoQ Swift SDKはiOS 15+向けで、`MoqFFI.xcframework`を通じてRust実装を利用できます。一方、カメラの`CVPixelBuffer`をそのまま受け取る公開APIはないため、iOS側では`AVCaptureVideoDataOutput`と`VTCompressionSession`を使う薄い映像取り込み層が必要です。アプリのdeployment targetはiOS 18に固定します。

既存のRust VideoToolbox encoderは現在macOS向けに条件付けされているため、iOSではそのコードをそのままリンクせず、SwiftのVideoToolbox実装を使います。

## 資料

- [アーキテクチャと採用候補](docs/architecture.md)
- [実験計画と計測項目](docs/experiment-plan.md)

## 外部実装

- [moq-dev/moq](https://github.com/moq-dev/moq): MoQのRust、C FFI、Swift、relay、OBS plugin
- [moq-dev/moq-swift](https://github.com/moq-dev/moq-swift): Swift wrapper
- [moq-dev/moq-swift-ffi](https://github.com/moq-dev/moq-swift-ffi): Swift用XCFramework
- [Media over QUIC Transport draft](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/): IETF仕様策定中の仕様

仕様と外部実装は変更されるため、依存するコミットまたはリリースを実験開始時に固定します。
