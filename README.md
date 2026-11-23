# Scarlett MixControl Companion

A macOS control and diagnostics companion for the **Focusrite Scarlett 18i8, 1st generation**. This project was started because the original Focusrite Scarlett MixControl app stopped being supported on the development Mac after upgrading to macOS Tahoe. The Swift probe reads CoreAudio/IOKit state and exposes a limited set of explicit, verified controls and clearly labelled experimental routing commands.

The 18i8 1st generation is the reference device used for development and hardware tests. Live Scarlett controls are intentionally scoped to the `Scarlett 18i8 USB` target, rather than automatically acting on another Scarlett model.

This is experimental software, not a complete replacement for Scarlett MixControl. Hardware routing read-back is unreliable and the previous routing cannot be restored automatically. Start with low listening levels.

For operating instructions, see the [user guide](USER_GUIDE.md).

## Run

Requirements: macOS, Swift 5.9 or later, and Node.js.

Build the probe and start the local UI/API:

```sh
swift build --package-path tools/scarlett-device-probe
node tools/playground-server.mjs
```

The server binds to `127.0.0.1:8787`. Set `PORT` to use another port:

```sh
PORT=8793 node tools/playground-server.mjs
```

The legacy script path remains as a SwiftPM launcher:

```sh
swift tools/scarlett-device-probe.swift --json
```

This repository intentionally excludes the original `target/Scarlett MixControl.app` bundle and its firmware/resources.

## Implemented

- **Device status:** CoreAudio device IDs, input/output channel counts, current sample rate, supported sample-rate ranges, current/supported clock sources, macOS default input/output, USB VID/PID, descriptors, and interfaces.
- **Line/Inst:** Read and set Inputs 1-2, with read-back. Reads retry up to two times if consecutive replies differ, to avoid showing a transient first response.
- **Preamp PAD:** Read and set analog Inputs 1-4. The UI requires a read before enabling Apply; a write is reported successful only after read-back.
- **Input gain query:** Read-only raw protocol byte for Inputs 1-8. It is not decoded as dB and is not a gain control.
- **Input/output metering:** Manual two-second RMS/peak capture for one input, simultaneous scan of all 18 inputs, continuous read-only CoreAudio meters for Inputs 1-18, and a system-audio tap for Scarlett Outputs 1-8. The output tap requires macOS 14.2 or newer and may require system-audio recording permission. A bounded 440 Hz tone can isolate a single CoreAudio channel or send the same mono signal to stereo pairs 1/2, 3/4, 5/6, and 7/8, then stop automatically. Measurements are processed in memory and are not saved.
- **Signal threshold:** Classifies scan/measurement levels as above or below a user-set dBFS threshold. This does not prove a cable or instrument is connected or map CoreAudio channels to front-panel jacks.
- **macOS default input/output:** Device-tab selectors use current CoreAudio device IDs. Apply changes the system-wide default and verifies by reading it back. Ableton can use a separate device selection. The Routing tab can also apply Scarlett as the macOS default output and restore the previous output with read-back verification.
- **Scarlett sample rate:** Reads the current rate and CoreAudio-supported ranges. Apply offers the discrete rates reported for the 18i8, checks the property is settable, then verifies read-back. A change affects all apps and can interrupt active audio.
- **Scarlett clock source:** Reads current and supported clock-source names from CoreAudio. Apply accepts only a source ID reported by the device, checks settable state, and verifies read-back. External S/PDIF/ADAT sync requires a valid connected source.
- **Standalone software monitor:** Copies Scarlett CoreAudio Input 1 to chosen CoreAudio Outputs 1-8 through a companion-owned duplex IOProc. The browser can send it to rear Monitors 1/2, Headphone 01, Headphone 02, S/PDIF, or a combination, with gain from -30 to 0 dB. Closing the stream or pressing Stop sends SIGTERM and destroys the callback. It can run alongside the host-output meter: each output pair shows separate **Host tap** and **Software monitor** readings. The host tap may also include the software monitor, so the two readings are not necessarily independent or additive and neither is a complete hardware-output meter. This works without a DAW but is software monitoring, so it can add latency and should be used with low listening volume. It does not change the Scarlett hardware monitor matrix and is not zero-latency direct monitoring.
- **Experimental hardware routing:** Explicit commands can set mixer channel 18's shared source to DAW 7 or 8, its Mix 1 gain to off or -12 dB, and Headphone 01 to off, DAW 1/2, DAW 3/4, or Mix 1 left / DAW 2 right. These limited cases were checked by listening on one 18i8 at 44.1 kHz. Hardware read-back is unreliable: a completed USB request is reported as **sent, not verified**, and the previous state cannot be restored automatically. Mixer source changes may affect other mixes and outputs. A headphone route uses two writes and a failure can leave a partial change. Start at low volume.
- **Experimental Monitor Outputs 1/2 routing:** An explicit command attempts to replace their current sources with DAW 1/2. A listening test confirmed that Monitor Output 1 played computer audio while Input 1 stopped reaching it directly; Monitor Output 2 has not been independently tested. Read-back and automatic restore are unavailable; the two writes can partially succeed. Lower monitor volume and confirm the result by listening.
- **Snapshots:** Save verified hardware state locally and apply it explicitly. Snapshots capture macOS default input/output, Scarlett sample rate and clock source, Input 1-2 Line/Inst, and PAD 1-4. Apply compares current state and skips unchanged settings; every changed setting is read back after posting. Older snapshots with hardware state remain compatible; their simulated UI fields are ignored. Experimental routing is not saved or restored.
- **Theme:** Dark is the default. Light/dark preference persists in browser local storage.

All hardware-changing actions require an explicit Apply/Set/Send action. No setting is changed when the page loads. Experimental routing commands are not verified by read-back.

## Local API

The HTTP server listens only on `127.0.0.1`. State-changing actions require explicit `POST` requests.

| Method and path | Behavior |
| --- | --- |
| `GET /api/device` | Device snapshot, CoreAudio defaults, rate/clock capabilities, and USB information. |
| `GET /api/input-mode?channel=1..2` | Read Line/Inst mode. |
| `POST /api/input-mode` | Set mode; JSON body: `{"channel":1,"mode":"inst"}`. |
| `GET /api/input-pad?channel=1..4` | Read preamp PAD. |
| `POST /api/input-pad` | Set PAD; JSON body: `{"channel":1,"enabled":true}`. |
| `GET /api/input-gain?channel=1..8` | Read raw input-gain protocol byte. |
| `POST /api/input-meter` | Measure one input for two seconds; JSON body: `{"channel":1}`. |
| `POST /api/input-scan` | Measure all 18 CoreAudio input channels simultaneously for two seconds. |
| `GET /api/live-input-meter?channel=1` | Server-sent RMS/peak frames for Input 1; closing the connection stops the capture process. |
| `GET /api/live-input-meters?channels=1,2,...,18` | One server-sent stream for the selected input channels; closing it stops the capture process. |
| `GET /api/live-output-meter` | Server-sent RMS/peak frames for Scarlett CoreAudio Outputs 1-8 using a private, unmuted CoreAudio tap; requires macOS 14.2 or newer. Closing it destroys the tap and aggregate device. |
| `POST /api/default-input` | Set macOS default input; JSON body: `{"deviceID":145}`. Use an ID from `/api/device`. |
| `POST /api/default-output` | Set macOS default output; JSON body: `{"deviceID":88}`. Use an ID from `/api/device`. |
| `POST /api/output-tone` | Play a bounded mono tone on one or more Scarlett CoreAudio outputs; JSON body: `{"channels":[1,2],"frequencyHz":440,"durationMilliseconds":2000}`. Use one channel for side isolation or 1/2, 3/4, 5/6, 7/8 for stereo pairs. |
| `GET /api/software-monitor?input=1&outputs=1,2,3,4&gainDb=-12` | Server-sent software-monitor frames; copies Input 1 to the selected outputs 1-8. One session is allowed. Closing the stream stops the callback. Gain must be -30 to 0 dB. |
| `POST /api/sample-rate` | Set Scarlett sample rate; JSON body: `{"deviceID":145,"sampleRateHz":48000}`. |
| `POST /api/clock-source` | Set Scarlett clock source; JSON body: `{"deviceID":145,"sourceID":690487296}`. Use IDs from `/api/device`. |
| `POST /api/experimental-mixer18-source` | Send shared mixer channel 18 source: `{"source":"daw7"}` or `"daw8"`; not verified. |
| `POST /api/experimental-mixer18-gain` | Send channel 18 Mix 1 gain: `{"gain":"off"}` or `"minus12"`; not verified. |
| `POST /api/experimental-headphone01` | Send Headphone 01 route: `{"preset":"clear"}`, `"daw-tracking"`, `"mixing"`, or `"mix1-left"`; not verified. These affect Headphone 01 only. |
| `POST /api/experimental-monitor12-source` | Send Monitor 1/2 route: `{"source":"daw12"}`; no reliable read-back, Output 2 not independently tested. |

Example IDs are runtime-specific; query `/api/device` instead of copying them. The default input/output routes are system-wide and do not control Ableton's own device settings. The current OS route is shown as-is and is not forced to the Scarlett on load.

## Probe commands

The SwiftPM executable and legacy launcher accept the same commands:

```sh
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --json
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --read-input-mode 1
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-input-mode 1 inst
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --read-input-pad 1
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-input-pad 1 on
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --read-input-gain 1
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --measure-input 1
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --measure-all-inputs
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --stream-input-meter 1
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --stream-input-meters 1,2,3,4
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --stream-scarlett-output-meters 1,2,3,4,5,6,7,8
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --play-scarlett-output-tone 1,2 440 2000
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --monitor-scarlett-input 1 1,2,3,4 -12
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-default-input "$COREAUDIO_DEVICE_ID"
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-default-output "$COREAUDIO_DEVICE_ID"
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-scarlett-sample-rate "$SCARLETT_DEVICE_ID" "$SUPPORTED_RATE_HZ"
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-scarlett-clock-source "$SCARLETT_DEVICE_ID" "$CLOCK_SOURCE_ID"
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --read-monitor-input-gains 1
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --read-monitor-mix-gain 1 1
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --read-monitor-mix-range 1 1
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-mixer18-source daw7
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-mixer18-gain off
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-headphone01-preset daw-tracking
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-monitor12-source daw12
```

The three `--read-monitor-*` commands are **diagnostic reads only**. Their values are not trusted as a complete snapshot of the active mixer matrix. The experimental `--set-*` routing commands write hardware without reliable read-back and report `verified: false`.
Set the device/source ID variables from the current `--json` snapshot. Device IDs are runtime-specific; sample-rate values must be in the device's reported supported ranges.

## Limitations

- The host-output tap may not include internal direct monitoring; the complete physical CoreAudio channel-to-connector mapping remains to be confirmed.
- Beyond the limited experimental commands above, Scarlett mixer source selection, gain, mute/solo, and physical output routing are **not implemented**. Complete device-wide routing presets and independent per-mix source selection are unavailable.
- Read-only mux probes against the connected 18i8 returned the mixer slot index for slots 0-17 and zero for output slots 0-7. A two-byte mixer read returned only one byte, although the original application's routing read requests two. These observations do not establish active routing or reliable read-back. The [Linux Scarlett driver](https://github.com/torvalds/linux/blob/master/sound/usb/mixer_scarlett.c) documents candidate mux controls; its [mixer code](https://github.com/torvalds/linux/blob/master/sound/usb/mixer.c) also caches values. Further routing combinations require controlled validation.
- In controlled Headphone 01 tests, the listener confirmed DAW 1/2, DAW 3/4, clear, and Mix 1 on the left. With a DAW 8 tone, switching mixer channel 18 from DAW 7 to 8 increased the level, as did enabling its Mix 1 gain; other channels also contributed. Output-mux reads still returned zero for both headphone slots after different writes. DAW 1/2 was restored; the pre-test route and mixer state were unknown. Other outputs and source combinations remain unverified.
- No Ableton track mute/solo or DAW control is implemented.

## Next tasks

1. **Investigate direct Input 1 monitoring on Headphone 01:** validate a hardware route without changing Monitor Outputs 1/2 and without relying on the software monitor.
2. **Capture per-channel output history:** retain a short rolling RMS/peak history for Inputs 1-18 and Outputs 1-8 in the browser, with the existing threshold controls.
3. **Expand Audio Source Select:** validate additional mixer channels and analog sources with controlled audio tests, while investigating reliable read-back.
4. **Extend Scarlett mix presets:** include internal routing only after its state can be read back and verified.

Other output mappings and mixer sources also require controlled validation and explicit unverified-state warnings until reliable read-back is available.

## Code layout

- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/CoreAudioProbe.swift`: CoreAudio device enumeration, input metering, clock/sample-rate controls, and macOS default-route operations.
- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/ScarlettUSBProbe.swift`: USB descriptors, Line/Inst, PAD, input-gain queries, and diagnostic mixer reads.
- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/ProbeModels.swift`: response models and errors.
- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/main.swift`: CLI and snapshot composition.
- `tools/playground-server.mjs`: loopback-only HTTP bridge.
- `playground.html`: browser control surface and diagnostics.
