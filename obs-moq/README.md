# obs-moq integration

The receiver is kept as an upstream checkout because `obs-moq` is released
from the `moq-dev/moq` monorepo and links the matching `libmoq` release. Apply
the local patches to the exact upstream commit recorded in the experiment
manifest:

```bash
git -C ../moq apply ../quic-video/obs-moq/patches/*.patch
```

The patches add:

- a `Max latency (ms)` source setting with `0`, `50`, `100`, and `200` ms use;
- a disabled-by-default JSONL diagnostic output path;
- receive and render events with monotonic timestamps, media PTS, payload size,
  and keyframe state;
- URL redaction remains enabled and is not changed by these patches.

The plugin still uses its upstream GPL-2.0-or-later license. This repository
does not redistribute the plugin source or binary.
