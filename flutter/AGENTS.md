# app_control_robot

Flutter app that drives the ESP32 chassis over **Classic Bluetooth (RFCOMM/SPP)** with a console-style gamepad UI. Android only — see "Platform limits" below.

## What it is

A hold-to-move remote laid out like a game controller. The screen splits into **three** columns: on the **left** the pivot pair (Trái `L` / Phải `R`), in the **centre** a round **STOP** and a **BT** button that opens the paired-device sheet, and on the **right** the drive pair (Tiến `F` / Lùi `B`). Pressing a direction sends it and resends it on a timer; releasing sends stop. The firmware kills the motors after 600 ms without a byte, so the app's keep-alive at 200 ms is what keeps a held direction driving.

The pad is a fixed 300x216 canvas inside a `FittedBox(fit: BoxFit.scaleDown)`, so it keeps its shape and its touch-target sizes on any screen instead of reflowing on a short one. Both action buttons sit in the centre column deliberately: they must not sit under a thumb that is holding a direction.

## Commands

```
flutter analyze
flutter test                              # all tests, headless, no hardware
flutter build apk --debug                 # also compiles MainActivity.kt (the Bluetooth host)
flutter run                               # needs an Android phone with the robot paired
```

`flutter test` cannot verify that the motors turn the right way — that only shows up on the chassis. `flutter build apk` is the only automated check that the Kotlin side compiles; a successful test run says nothing about it.

## Architecture

Four files, each with one job:

- `lib/bluetooth_transport.dart` — `RobotTransport` (interface), `BluetoothDevice`, `BluetoothUnavailable`, and `MethodChannelTransport` (the platform-channel implementation). Owns every Bluetooth-specific call: permissions, the bond list, opening the socket, writes. No widgets, no protocol.
- `lib/robot_link.dart` — `RobotLink`, a `ChangeNotifier` wrapping a `RobotTransport`. Owns the protocol (`hold`/`release`), the keep-alive timer, and link-loss handling. No widgets, no platform channels.
- `lib/gamepad_controls.dart` — `DirectionButton`, `GamepadActionButton`, `LinkLamp`. Styling and press/release signalling only.
- `lib/main.dart` — `ControlPage`: the connection strip, the device picker sheet, and the layout (including `_DirectionCluster`, the two-thumb-zone helper). Wires the other three together.

Splitting it this way is what makes `test/robot_link_test.dart` possible: it swaps in a `FakeTransport` and asserts on the exact bytes, so protocol regressions are caught without a robot. Keep protocol logic in `RobotLink` and every platform call in `RobotTransport` — a `MethodChannel` call inside a widget cannot be faked.

`ControlPage` accepts an optional `RobotLink` so tests can inject one. **An injected link is not disposed by the page**; only a link the page created itself is. Getting that backwards produces "A RobotLink was used after being disposed".

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
- **The direction commands are grouped by hand, not by axis.** `L`/`R` (pivot) are the left cluster and `F`/`B` (drive) the right one. They are deliberately *not* one D-pad: a single cross makes it ambiguous whether a slide was meant as a turn or a reverse, and the two pairs are used by different hands. Do not "helpfully" merge them back into a `GamepadDpad`.
- **`release()` always writes `S`, even when nothing was held.** The stop button must never be a no-op while connected. The `_heldCommand` null check in `hold()` is what makes re-pressing the same direction idempotent; there is intentionally no equivalent guard in `release()`.
- **`didChangeAppLifecycleState` calls `release()`.** Backgrounding, a lock screen, or an incoming call must not leave motors running. Any new entry point that can start a command needs the same treatment.
- Movement buttons are disabled until connected; STOP is always live. Keep that asymmetry.
- `GamepadActionButton` is a plain `InkWell` tap, not a hold. STOP must fire even if the finger lands and lifts immediately. Its label/icon colour is derived from the fill via `ColorScheme.contrastOn`, not hardcoded to `onError`, so a non-error fill (BT is `tertiary`) stays readable.

## Protocol contract

Bluetooth Serial (RFCOMM/SPP) to `ESP32_ROBOT`, PIN `1234`. One ASCII char per command plus `\n`: `F`/`B`/`L`/`R`/`S`. See `../esp32/AGENTS.md` for the firmware side. **The two sides must change together** — the command characters, the device name/PIN, and `COMMAND_TIMEOUT_MS` (firmware, 600 ms) vs `RobotLink.firmwareCommandTimeout` / `keepAliveInterval` (app, 600 ms / 200 ms).

## Not verified here

`RobotLink` is tested against a fake transport, not the real ESP32. Whether the firmware honours the bytes, whether the phone pairs, whether the watchdog fires at 600 ms, and whether `L`/`R` pivot in the intended directions all require the physical robot.

`flutter build apk --debug` proves the Kotlin host compiles and the manifest merges, nothing more. In particular it cannot prove `BluetoothAdapter` is obtainable on the user's phone — the null-adapter bug above was invisible to every automated check, because a wrong `as?` cast is perfectly valid Kotlin.
