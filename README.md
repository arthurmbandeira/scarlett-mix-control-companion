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
- **Input metering:** Manual two-second RMS/peak capture for one input, simultaneous scan of all 18 inputs, and a continuous read-only CoreAudio stream for Inputs 1-18. On desktop, the mixer starts with Analogue 1, Analogue 2, Analogue 3/4, Playback 1/2, Playback 3/4, and Monitor together; Inputs 5-18 follow. Inputs 1-4 map to the first three input strips, with Analogue 3/4 shown as stereo. Inputs 5-18 are labeled by CoreAudio channel number because their physical ADAT/S/PDIF mapping has not been validated. Playback and Monitor meters remain simulated. Audio is processed in memory and discarded, never saved or played.
- **Signal threshold:** Classifies scan/measurement levels as above or below a user-set dBFS threshold. This does not prove a cable or instrument is connected or map CoreAudio channels to front-panel jacks.
- **macOS default input/output:** Device-tab selectors use current CoreAudio device IDs. Apply changes the system-wide default and verifies by reading it back. Ableton can use a separate device selection.
- **Scarlett sample rate:** Reads the current rate and CoreAudio-supported ranges. Apply offers the discrete rates reported for the 18i8, checks the property is settable, then verifies read-back. A change affects all apps and can interrupt active audio.
- **Scarlett clock source:** Reads current and supported clock-source names from CoreAudio. Apply accepts only a source ID reported by the device, checks settable state, and verifies read-back. External S/PDIF/ADAT sync requires a valid connected source.
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
| `POST /api/default-input` | Set macOS default input; JSON body: `{"deviceID":145}`. Use an ID from `/api/device`. |
| `POST /api/default-output` | Set macOS default output; JSON body: `{"deviceID":88}`. Use an ID from `/api/device`. |
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

- Mixer faders, pan, M/S, meter demo, simulation profile/clock/rate, and output-routing selectors change only browser state. The pan readout mirrors the slider value; Analogue 1 and 2 default to centered (`0`). Input meters 1-18 use live CoreAudio data; Playback and Monitor meters remain simulated.
- Scarlett monitor-mix mute/solo and physical output crosspoint routing are **not implemented**. Current routing cannot yet be read reliably, and exploratory gain writes did not produce reliable read-back. No monitor-mixer write is exposed.
- No Ableton track mute/solo or DAW control is implemented.

## Code layout

- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/CoreAudioProbe.swift`: CoreAudio device enumeration, input metering, clock/sample-rate controls, and macOS default-route operations.
- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/ScarlettUSBProbe.swift`: USB descriptors, Line/Inst, PAD, input-gain queries, and diagnostic mixer reads.
- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/ProbeModels.swift`: response models and errors.
- `tools/scarlett-device-probe/Sources/ScarlettDeviceProbe/main.swift`: CLI and snapshot composition.
- `tools/playground-server.mjs`: loopback-only HTTP bridge.
- `playground.html`: browser control surface and diagnostics.
