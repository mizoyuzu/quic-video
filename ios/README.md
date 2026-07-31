# iOS App

`QuicVideo.xcodeproj` contains the iOS 18+ publisher app.

## First build

1. Open `ios/QuicVideo.xcodeproj` on a Mac with Xcode 16 or newer.
2. Select a signing team and a physical iPhone target.
3. Let Swift Package Manager resolve `moq-dev/moq-swift` at `0.4.1`.
4. Install and start the Mac relay before pressing `Start`.

The app uses `avc1`/`hvc1` with AVCC/HVCC initialization data. This matches the current
MoQ importer and the length-prefixed access units produced by VideoToolbox.

The first build is expected to validate the package version and generated FFI symbols on
the Mac. Keep the resolved package versions in `Package.resolved` after that validation.
