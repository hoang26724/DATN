# app_control_robot

Flutter app that drives the ESP32 chassis over **Classic Bluetooth (RFCOMM/SPP)** with a console-style gamepad UI and a live Raspberry-Pi camera view. Android only — see "Platform limits" below.

## What it is

A hold-to-move remote laid out like a phone keypad, with the Raspberry-Pi camera above it:

```
1 2 3     1 suction speed up, 2 forward (F), 3 drive speed up
4 5 6     4 turn left (L), 5 toggle the suction brush (G1/G0), 6 turn right (R)
7 8 9     7 suction speed down, 8 backward (B), 9 drive speed down
```

The four direction keys are hold-to-drive: pressing sends the command and resends it on the keep-alive timer, releasing or dragging off stops the rear main drive. The four corner keys are hold-to-ramp: `1`/`7` set L298N #1 (the suction brush) and `3`/`9` set L298N #2 (the two main wheels); suction starts at 100%, drive at 50%. Key 5 is a **tap** (not a hold) that toggles the L298N #1 suction brush; while on, the app resends `G1` on the keep-alive cadence, so the firmware watchdog does not stop it. Auto mode lives in the top strip next to relay and Bluetooth, and the direction keys go dead while it is armed — the suction brush stays available because it is not a drive. The firmware kills the motors after 600 ms without a byte, so the app's keep-alive at 200 ms is what keeps a held direction driving.

The camera sits above the pad; a **strip between them** carries the person / pickleball counts and the two speed percentages, labelled `Tốc độ hút` (suction) and `Tốc độ chạy` (drive). The pad is a fixed 320x320 canvas inside `FittedBox(fit: BoxFit.scaleDown)`, so it keeps its shape and its touch-target sizes on any screen instead of reflowing on a short one. The keys paint icons and their `Hút`/`Chạy` role, never digits.

## Commands

```
flutter analyze
flutter test                              # all tests, headless, no hardware
flutter build apk --debug                 # also compiles MainActivity.kt (the Bluetooth host)
flutter run                               # needs an Android phone with the robot paired
```

`flutter test` cannot verify that the motors turn the right way — that only shows up on the chassis. `flutter build apk` is the only automated check that the Kotlin side compiles; a successful test run says nothing about it.

## Architecture

Seven files, each with one job:

- `lib/bluetooth_transport.dart` — `RobotTransport` (interface), `BluetoothDevice`, `BluetoothUnavailable`, and `MethodChannelTransport` (the platform-channel implementation). Owns every Bluetooth-specific call: permissions, the bond list, opening the socket, writes. No widgets, no protocol.
- `lib/robot_link.dart` — `RobotLink`, a `ChangeNotifier` wrapping a `RobotTransport`. Owns the protocol (`hold`/`release`/`holdSpeed`/`setFrontModule`/`setAutoMode`/`setRelay`), the direction/brush keep-alives, the speed-repeat timer, and link-loss handling. No widgets, no platform channels.
- `lib/pi_camera_transport.dart` — `PiCameraTransport` (interface), `HttpPiCameraTransport` (the real MJPEG + `/stats` HTTP client), and `MjpegSplitter`. No widgets.
- `lib/pi_camera_link.dart` — `PiCameraLink`, a `ChangeNotifier` over a `PiCameraTransport`: the latest frame, the stall watchdog, and `/stats` polling. No widgets.
- `lib/camera_panel.dart` — `CameraPanel`: paints the decoded frame, the FPS pill, and the reload / reconnect affordances. Widgets only.
- `lib/gamepad_controls.dart` — `DirectionButton`, `SpeedButton`, `PadToggleButton`, `_PadSurface`, `GamepadActionButton`, `LinkLamp`. Styling and press/release signalling only; the pad paints icons and the `Hút`/`Chạy` role, no keypad digits.
- `lib/main.dart` — `ControlPage`: the app bar, `_ConnectionStrip`, `_InfoStrip`, the 3x3 `_PadGrid`, and the device picker sheet. Wires the rest together.

Splitting it this way is what makes the tests possible: `test/robot_link_test.dart` swaps in a `FakeTransport` and asserts on the exact bytes, and `test/pi_camera_test.dart` swaps in a `FakePiCameraTransport`, so protocol and feed regressions are caught without a robot or a Pi. Keep protocol logic in `RobotLink` and every platform/network call in the transports — a `MethodChannel` or socket call inside a widget cannot be faked.

`ControlPage` accepts optional `RobotLink` and `PiCameraLink` so tests can inject them. **An injected link is not disposed by the page**; only one the page created itself is. Getting that backwards produces "used after being disposed".

## The Pi camera

`CameraPanel` shows the MJPEG stream the Raspberry Pi serves on port 8000 (`../raspberry/`); the host lives in `pi_camera_transport.dart`. `ControlPage` starts the camera in `initState`, stops it when the app is backgrounded, and restarts it on resume — a socket parked while the app was away comes back wedged far more often than not. The panel carries **no corner buttons**: tapping the picture reloads the stream (the status overlay sits above the picture, so a tap that lands on it never reaches the picture), the reconnect button appears in the middle when the link asks for one, and the **auto, relay and connect/disconnect buttons** share one evenly divided row in `_ConnectionStrip` — their state and writes are `RobotLink.autoMode` / `setAutoMode`, `RobotLink.relayOn` / `setRelay`, and `RobotLink.disconnect` / the device picker, the strip only paints them.

- The failure this subsystem exists for is a **silently frozen** picture: a half-open TCP socket that never errors and never delivers a byte. `PiCameraLink` declares a stall after `stallTimeout` with no frame and flips to `PiCameraStatus.stalled`, so the panel can offer a reconnect. `/stats` failures only mark the counts stale; they never tear down a stream that is still delivering frames.
- `PiCameraLink._detach()` **fires the subscription cancel and does not await it**. Awaiting anything derived from `StreamSubscription.cancel()` deadlocks the widget-test fake clock (see below), and a reload opens a fresh stream anyway, so nothing has to wait for the old cancel to land.

## The Android host

`android/app/src/main/kotlin/.../MainActivity.kt` implements the classic-Bluetooth socket by hand. There is no plugin for it, and no third-party dependency was added: `androidx.core` (`ContextCompat`, `ActivityCompat`) comes in transitively from the Flutter embedding.

Channel contract, both sides must agree:
- MethodChannel `com.example.app_control_robot/bluetooth`: `ensureReady`, `pairedDevices`, `openBluetoothSettings`, `connect {address, name}`, `disconnect`, `write {data}`.
- EventChannel `.../bluetooth/events`: `{'type': 'message', 'text': ...}` and `{'type': 'linkLost', 'reason': ...}`.

Rules in there worth knowing before editing:
- **`Context.BLUETOOTH_SERVICE` returns a `BluetoothManager`, not a `BluetoothAdapter`.** Casting it straight to `BluetoothAdapter` compiles, but `as?` then yields null on *every* device and *every* Android version, so the app reports "Máy này không có Bluetooth" on a phone that obviously has Bluetooth. The adapter comes from `manager.adapter`. This is the single easiest way to break the whole app; there is a comment on the `adapter` property saying so.
- **`BluetoothSocket.connect()` and socket writes both block**, so neither may run on the platform thread. `connect()` gets its own `Thread`; writes go through `writer`, a single-threaded executor so a command and its keep-alives stay ordered. Capturing `session.get()` *before* queueing a write is what keeps a write that fails because the user disconnected from reporting a link loss they asked for.
- **`session: AtomicInteger` is the generation guard.** Bumping it in `closeSession()` is what stops a reader blocked in `read()` from reporting a link loss the user asked for. Never report a link loss without checking the id still matches.
- **Permission requests park a lambda, not a `MethodChannel.Result`.** The system dialog is async, so `pendingPermission` holds a continuation and `onRequestPermissionsResult` resumes it.
- **A `MethodChannel.Result` must always be answered, exactly once.** An unanswered one hangs the Dart future forever, which is why the write path answers even when the executor is shutting down.
- Host-side error messages are already written in Vietnamese for the user. Dart passes them through verbatim (`BluetoothUnavailable`), so do not prefix them with anything technical.
- Reads drain into a `HandlerThread`, and `Looper.getHandler()` is not public API — build the `Handler` from `thread.looper`.

## Permissions

`AndroidManifest.xml` declares `BLUETOOTH` / `BLUETOOTH_ADMIN` / `ACCESS_FINE_LOCATION` with `maxSdkVersion="30"` (the pattern Google's own Bluetooth docs prescribe, to keep only the grants each platform needs), plus `BLUETOOTH_CONNECT` and `BLUETOOTH_SCAN` (`neverForLocation`) for Android 12+.

What is asked for **at runtime** is only what the app actually uses:
- On API < 31, `ACCESS_FINE_LOCATION` — the one that matters, because reading `bondedDevices` requires it.
- On API 31+, `BLUETOOTH_CONNECT` alone. Talking to an already-paired device is "communicating with already-paired devices", which needs CONNECT only. **`BLUETOOTH_SCAN` is declared but never requested**: the app never scans, and requiring it would let a single refusal wedge the app with no way for the user to recover. It stays declared because `BluetoothAdapter.cancelDiscovery()` is itself scan-gated on 31+, and the call is wrapped in `runCatching` so a refusal is harmless.

**`INTERNET` is gone from the main manifest** — the link is a Bluetooth socket, not TCP. `android/app/src/debug/AndroidManifest.xml` and `.../profile/AndroidManifest.xml` still declare it because the Flutter tool needs it for hot reload and debugging. It therefore still shows up in a **debug** merged manifest; that is expected. Do not "restore" it to the main manifest.

## Platform limits

- **Android only.** iOS apps cannot open a Classic Bluetooth RFCOMM socket to an arbitrary device without MFi certification. `ios/Runner/Info.plist` still carries `NSLocalNetworkUsageDescription` and `NSAllowsLocalNetworking` from the WiFi era; they are now dead keys, kept only in case this moves to BLE.
- **Pairing happens in the system settings, never in the app.** Android does not allow an app to pair a device, so the sheet only lists *bonded* devices and offers a button that jumps to `Settings.ACTION_BLUETOOTH_SETTINGS`. Anything that claims to scan for robots from the app is wrong.

## Quirks that bite

- **`DirectionButton` uses `Listener`, not `InkWell`.** `InkWell` cancels its tap when the finger drags off, which would skip the release and leave the robot driving. `Listener` delivers `onPointerUp` regardless of where the finger ended up. Do not "simplify" this to a gesture-based button.
- **The pad is a positional 3x3 keypad.** Row 1 is suction speed up / forward / drive speed up, row 2 is turn left / toggle the suction brush / turn right, row 3 is suction speed down / backward / drive speed down. The turn keys use `chevron_left`/`chevron_right` so they read as `<`/`>`. The `1`–`9` positions in the diagram above are layout shorthand only — **the app paints no digits on the keys**, per the user's request. Do not reflow it into a `GamepadDpad`, and keep the spatial arrangement even though the digits are gone.
- **`release()` always writes `S`, even when nothing was held.** There is no STOP button on the pad any more, so a gesture ending is the only thing that ever sends `S`, and it must never be a no-op while connected. `S` stops the rear main drive but leaves the middle-key suction brush running; only the firmware's safety stop (link loss, watchdog) turns that module off as well. The `_heldCommand` null check in `hold()` is what makes re-pressing the same direction idempotent; there is intentionally no equivalent guard in `release()`.
- **`didChangeAppLifecycleState` calls `release()`, `releaseSpeed()` and `setFrontModule(false)`.** Backgrounding, a lock screen, or an incoming call must not leave any motor running. Any new entry point that can start a command needs the same treatment.
- Movement (direction) keys are disabled until connected and disabled again in auto mode; the speed keys and the suction toggle stay live whenever connected. The strip's auto toggle is disabled until connected.
- Key 5 is a **tap, not a hold** (`PadToggleButton`): it flips the absolute `G1`/`G0` suction-brush state and stays lit while on. While on, `RobotLink` resends `G1` every `keepAliveInterval`; releasing a direction key does not cancel that timer, and the toggle still works in auto mode.
- Auto mode is a **tap toggle in `_ConnectionStrip`**, not on the pad. It stays lit while armed and writes `A`/`M`. It does **not** touch the suction brush: the brush is not a drive, so the operator can keep it running while the Pi steers.
- Speed keys ramp on a repeat timer (`RobotLink.speedRepeatInterval`, 150 ms) and clamp to 0-100; each writes an **absolute** `f` or `r` command, so the firmware never tracks a delta. Suction defaults to 100% and drive to 50% on connect.
- `GamepadActionButton` is a plain `InkWell` tap, not a hold; its label/icon colour comes from the fill via `ColorScheme.contrastOn`. It is no longer used on the pad (the pad has no centre action button, and `widget_test.dart` asserts its absence) — the Bluetooth affordance is the strip's `FilledButton`.
- The **app bar** is titled `ROBOT PICKLEBALL` and owns the connection status: `Đã kết nối` / `Chưa kết nối` (`Đang kết nối...` while connecting). The strip does not repeat the device name or MAC address; once connected, the status label is the only place the link state appears. The raw link-loss reason is deliberately not surfaced. The top strip's Bluetooth button shows `Kết nối` + `Icons.bluetooth` when disconnected and `Ngắt` + `Icons.bluetooth_disabled` when connected, and all three buttons are evenly divided.

## Protocol contract

Bluetooth Serial (RFCOMM/SPP) to `ESP32_ROBOT`, PIN `1234`, one ASCII **line** per command. Drive: `F`/`B`/`L`/`R`, plus `S` stop (rear drive only). The app no longer sends `X`/`Z`; the firmware still accepts them. Suction brush: `G1` on, `G0` off — absolute, never a toggle; while on `RobotLink` resends `G1` on the keep-alive timer. Speed: `f<0-100>` sets the brush (L298N #1), `r<0-100>` the drive (L298N #2); suction defaults to 100 and drive to 50 on connect. Auto: `A` arms the Pi driver, `M` returns to manual. Relay: `Y1` closes the GPIO-32 relay, `Y0` opens it — absolute, never a toggle; `RobotLink.setRelay` mirrors it in `relayOn`, and both sides reset to off on link loss (the firmware drops the pin in its `hasClient()` branch). Lower case `f`/`r` are reserved for the speed setters, so drive letters must be upper case. `connect()` pushes the current `f`/`r` speeds right after the socket opens. See `../esp32/AGENTS.md` for the firmware side and the Pi-UART auto protocol. **The two sides must change together** — the command characters, the device name/PIN, and `COMMAND_TIMEOUT_MS` (firmware, 600 ms) vs `RobotLink.firmwareCommandTimeout` / `keepAliveInterval` (app, 600 ms / 200 ms).

## Widget-test notes

`test/widget_test.dart` drives `ControlPage` with a `FakeTransport` and a `FakePiCameraTransport`. Two constraints to respect before editing it or `PiCameraLink`:

- **Do not `pumpAndSettle()`** while the camera is `connecting`: the reload button's `CircularProgressIndicator` never settles. The `settleSheet` helper pumps fixed durations instead (the sheet animation just needs timed pumps).
- **Do not await a future that completes from a `StreamSubscription.cancel()` callback** under `testWidgets` (Flutter 3.47.x): the next `tester.pump()` hangs. That is exactly why `PiCameraLink._detach()` fire-and-forgets its cancel. Keep the app free of `await sub.cancel()` (and of `whenComplete`/`Completer` fed from it) anywhere a widget test drives it.

## Not verified here

`RobotLink` is tested against a fake transport, not the real ESP32. Whether the firmware honours the bytes, whether the phone pairs, whether the watchdog fires at 600 ms, and whether `L`/`R` turn in the intended directions all require the physical robot. Likewise `PiCameraLink` is tested against a fake feed; the real MJPEG/`/stats` HTTP behaviour and the Pi UART auto-driving need the hardware.

`flutter build apk --debug` proves the Kotlin host compiles and the manifest merges, nothing more. In particular it cannot prove `BluetoothAdapter` is obtainable on the user's phone — the null-adapter bug above was invisible to every automated check, because a wrong `as?` cast is perfectly valid Kotlin.
