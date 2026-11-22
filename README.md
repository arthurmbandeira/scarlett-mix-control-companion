# Scarlett MixControl Companion

A macOS control and diagnostics companion for the **Focusrite Scarlett 18i8, 1st generation**. This project was started because the original Focusrite Scarlett MixControl app stopped being supported on the development Mac after upgrading to macOS Tahoe. The Swift probe reads CoreAudio/IOKit state and exposes a limited set of explicit, verified controls. The browser UI labels live controls separately from simulated mixer/routing controls.

The 18i8 1st generation is the reference device used for development and hardware tests. Live Scarlett controls are intentionally scoped to the `Scarlett 18i8 USB` target, rather than automatically acting on another Scarlett model.

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

This repository intentionally excludes the original `target/Scarlett MixControl.app` bundle and its firmware/resources. The Routing tab uses the 18i8 1st-gen artwork when the bundle is available locally, and falls back to a note in source-only clones.

## Implemented

- **Device status:** CoreAudio device IDs, input/output channel counts, current sample rate, supported sample-rate ranges, current/supported clock sources, macOS default input/output, USB VID/PID, descriptors, and interfaces.
- **Line/Inst:** Read and set Inputs 1-2, with read-back. Reads retry up to two times if consecutive replies differ, to avoid showing a transient first response.
- **Preamp PAD:** Read and set analog Inputs 1-4. The UI requires a read before enabling Apply; a write is reported successful only after read-back.
- **Input gain query:** Read-only raw protocol byte for Inputs 1-8. It is not decoded as dB and is not a gain control.
- **Input/output metering:** Manual two-second RMS/peak capture for one input, simultaneous scan of all 18 inputs, continuous read-only CoreAudio meters for Inputs 1-18, and a system-audio tap for Scarlett Outputs 1-8. The output tap requires macOS 14.2 or newer and may require system-audio recording permission. A bounded 440 Hz tone can be played through CoreAudio Output 1-8 to identify physical sockets, then stops automatically. On desktop, Analogue 1, Analogue 2, Analogue 3/4, and output pairs 1/2, 3/4, 5/6, and 7/8 appear together. Playback return meters remain simulated. Audio is processed in memory and never recorded or played back by the companion.
- **Signal threshold:** Classifies scan/measurement levels as above or below a user-set dBFS threshold. This does not prove a cable or instrument is connected or map CoreAudio channels to front-panel jacks.
- **macOS default input/output:** Device-tab selectors use current CoreAudio device IDs. Apply changes the system-wide default and verifies by reading it back. Ableton can use a separate device selection. The Routing tab can also apply Scarlett as the macOS default output and restore the previous output with read-back verification.
- **Scarlett sample rate:** Reads the current rate and CoreAudio-supported ranges. Apply offers the discrete rates reported for the 18i8, checks the property is settable, then verifies read-back. A change affects all apps and can interrupt active audio.
- **Scarlett clock source:** Reads current and supported clock-source names from CoreAudio. Apply accepts only a source ID reported by the device, checks settable state, and verifies read-back. External S/PDIF/ADAT sync requires a valid connected source.
- **Snapshots:** Save live browser and verified hardware state locally, Load UI without changing hardware, and Apply hardware explicitly. Hardware snapshots capture macOS default input/output, Scarlett sample rate and clock source, Input 1-2 Line/Inst, and PAD 1-4. Apply compares current state and skips unchanged settings; every changed setting is read back after posting.
- **Theme:** Dark is the default. Light/dark preference persists in browser local storage.

All hardware-changing actions require an explicit Apply/Set action. No setting is changed when the page loads.

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
| `POST /api/output-tone` | Play a bounded 440 Hz or custom tone on one Scarlett CoreAudio output; JSON body: `{"channel":1,"frequencyHz":440,"durationMilliseconds":2000}`. |
| `POST /api/sample-rate` | Set Scarlett sample rate; JSON body: `{"deviceID":145,"sampleRateHz":48000}`. |
| `POST /api/clock-source` | Set Scarlett clock source; JSON body: `{"deviceID":145,"sourceID":690487296}`. Use IDs from `/api/device`. |

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
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --play-scarlett-output-tone 1 440 2000
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-default-input "$COREAUDIO_DEVICE_ID"
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-default-output "$COREAUDIO_DEVICE_ID"
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-scarlett-sample-rate "$SCARLETT_DEVICE_ID" "$SUPPORTED_RATE_HZ"
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --set-scarlett-clock-source "$SCARLETT_DEVICE_ID" "$CLOCK_SOURCE_ID"
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --read-monitor-input-gains 1
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --read-monitor-mix-gain 1 1
swift run --package-path tools/scarlett-device-probe ScarlettDeviceProbe -- --read-monitor-mix-range 1 1
```

The last three monitor-mix commands are **diagnostic reads only**. Their values are not trusted as a complete snapshot of the active mixer matrix.
Set the device/source ID variables from the current `--json` snapshot. Device IDs are runtime-specific; sample-rate values must be in the device's reported supported ranges.

## Simulated and unavailable

- Mixer faders, pan, M/S, meter demo, simulation profile/clock/rate, and browser-only output selectors change only browser state. The pan readout mirrors the slider value; Analogue 1 and 2 default to centered (`0`). Input meters 1-18 and Scarlett output meters 1-8 use live CoreAudio taps. macOS default output routing is live and reversible through Apply/Restore; Scarlett internal monitor-matrix routing remains unavailable. Playback return meters remain simulated, and the host-output tap may not include internal direct monitoring.
- Scarlett monitor-mix mute/solo and physical output crosspoint routing are **not implemented**. Current routing cannot yet be read reliably, and exploratory gain writes did not produce reliable read-back. No monitor-mixer write is exposed.
- No Ableton track mute/solo or DAW control is implemented.

## Next tasks

1. **Confirm Scarlett physical output mapping:** use the controlled 440 Hz test to record each CoreAudio output 1-8 against the front-panel/headphone/S/PDIF destinations. The signal test is implemented; physical confirmation requires manual listening/measurement.
2. **Capture per-channel output history:** retain a short rolling RMS/peak history for Inputs 1-18 and Outputs 1-8 in the browser, with the existing threshold controls.
4. **Reverse engineer monitor-matrix writes:** investigate a reliable read-back and write protocol for monitor mixes, mute/solo, and direct-monitor routing before exposing it in the UI.
5. **Add Scarlett mix presets:** save and restore Line/Inst, PAD, route, sample-rate, and clock settings only after each state can be read back and verified.

The highest-priority remaining work is physical output mapping and monitor-matrix protocol reverse engineering. Adding hardware matrix controls without reliable read-back should remain blocked.

## Code layout

- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/CoreAudioProbe.swift`: CoreAudio device enumeration, input metering, clock/sample-rate controls, and macOS default-route operations.
- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/ScarlettUSBProbe.swift`: USB descriptors, Line/Inst, PAD, input-gain queries, and diagnostic mixer reads.
- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/ProbeModels.swift`: response models and errors.
- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/main.swift`: CLI and snapshot composition.
- `tools/playground-server.mjs`: loopback-only HTTP bridge.
- `playground.html`: browser control surface and diagnostics.
