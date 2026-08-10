# AnyMix

Per-app volume mixer for macOS. Lives in the menu bar, lists whatever is
currently making sound, and gives each app its own slider and mute — the thing
Windows has had since Vista and macOS still doesn't.

## Why it needs to exist

macOS exposes exactly one output volume. If a video call is too quiet relative
to your music, the OS offers no way to fix it short of hunting for a volume
control inside each app — and most apps don't have one.

## How it works

macOS 14.2 added Core Audio **process taps** — the ability to intercept another
process's audio. AnyMix uses that directly:

- **`ProcessDiscovery`** enumerates processes that currently hold audio objects,
  so the list shows what's actually playing rather than every running app.
- **`ProcessTap`** creates a tap plus an aggregate device per process, then
  applies gain in the IO callback.
- Gain changes are **ramped over 30 ms** rather than applied instantly. A step
  change in amplitude between one buffer and the next is an audible click; the
  ramp is what makes a slider drag sound smooth.
- **`VolumeStore`** persists per-app levels, so an app comes back at the volume
  you left it.

No kernel extension, no audio driver to install, no virtual output device to
select — it's the OS-sanctioned API, which is also why it needs macOS 14.2.

## Requirements

macOS 14.2+, Swift 6, Xcode 16. The project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open AnyMix.xcodeproj
```

Audio recording entitlement is required — process taps are, from the system's
point of view, capture.

## Status

Working, self-signed, unreleased. No notarized build yet.

## License

MIT
