# AGENTS.md

Single-env PlatformIO firmware project: ESP32 (DOIT ESP32 DEVKIT V1) driving four DC motors through **two** L298N modules, now **Bluetooth**-commanded from the Flutter app in `../flutter/` (the Dart *package* is named `app_control_robot`, but the directory is `flutter/` — there is no `app_control_robot/` folder). There is no CI, no linter, no formatter, and no typecheck step. The git repo is at the repo root, one level up.

**There is no WiFi in this firmware.** `WiFi.h`, the TCP server, the DHCP retry logic, and `src/wifi_config.h` are all gone. Do not reintroduce them; the phone and the robot never share a network.

## Protocol (shared contract with the Flutter app)

The ESP32 is a **Classic Bluetooth / RFCOMM (SPP) peripheral**, not BLE. It advertises as `BLUETOOTH_DEVICE_NAME` and requires `BLUETOOTH_PIN` during pairing. One RFCOMM socket at a time; the app is the single client.

Commands arrive as an ASCII **line** (ended by `\n` or `\r`); only the first character picks the action:
- `F` forward, `B` backward, `L` turn left, `R` turn right, `S`/`s` stop the rear main drive — the drive commands. `X`/`Z` (strafe left/right) are still parsed but the current app does not send them.
- **L298N #2 (rear) is the main drive** and carries the two omni wheels. `F`/`B` run both rear wheels; `L`/`R` pivot with the rear wheels counter-rotating (left backward / right forward for `L`); `X`/`Z` run the rear wheels in opposite directions for lateral travel.
- **L298N #1 (front) drives the rotating suction brush.** `G1` turns it on, `G0` off (absolute, never a toggle). It runs in reverse continuously while on and does not depend on a direction key. The app resends `G1` on its keep-alive cadence, which is what satisfies `COMMAND_TIMEOUT_MS`. `G` is accepted in auto mode too, because the brush is not part of the drive.
- `f<0-100>` sets the **brush** module (L298N #1) speed, e.g. `f50`; `r<0-100>` sets the **drive** module (L298N #2) speed. The brush boots at **100%**, the drive at **50%**. Lower case `f`/`r` are the speed setters, so they are the only drive letters **not** accepted in lower case.
- `A`/`a` enters **auto mode** (the Pi drives over UART, below); `M`/`m` returns to manual (the app drives). Auto mode stops the wheels but leaves the suction brush under its own `G1`/`G0` toggle.
- `Y1` closes the **relay** on GPIO 32, `Y0` opens it (absolute, never a toggle, so a reconnect cannot desync the app). The relay also opens whenever `hasClient()` goes false, same safety rationale as the motors. Lower case `y` is accepted too.
- Drive commands are ignored while in auto mode; `S` stops the rear drive and leaves the front toggle alone.

`src/bluetooth_config.h` holds the name and PIN (`ESP32_ROBOT` / `1234`). Keep it out of `main.cpp` so the identity can be swapped without touching logic. Changing the name means re-pairing on the phone; changing the PIN means unpairing first.

Watchdog rules, all of which must stay in sync with `RobotLink` on the app side:
- **Command timeout.** `COMMAND_TIMEOUT_MS` (600 ms) with no byte received stops the motors *in manual mode*. The app resends the held command every 200 ms, so this is the primary "app crashed / phone locked / phone walked out of range" safety net.
- **Auto timeout.** `AUTO_TIMEOUT_MS` (600 ms) with no `BALL` line from the Pi stops the motors *in auto mode*. Same idea, different source: the Pi sends on every camera frame (~10 Hz).
- **Link loss.** `serialBt.hasClient()` going false stops the motors immediately, before anything else in `loop()`, and drops out of auto mode.
- `stopForSafety()` itself starts with `if (!motorsRunning) return;`, so both the stop and the `[safety]` log line happen only on a real transition. Calling it when already stopped is a cheap no-op.

Changing the command characters here requires editing `RobotLink`/`ControlPage` in `../flutter/lib/` too.

## Pi UART (auto-driving link)

A second serial link, independent of Bluetooth, carries the ball from the Raspberry Pi in `../raspberry/`:
- ESP32 side is GPIO **22 (RX)** / **21 (TX)** — `Serial2` remapped, because the default UART pins collide with motor IN lines. Cross the wires to the Pi (Pi TX -> GPIO22, Pi RX -> GPIO21), 115200 8N1.
- The Pi sends `BALL <offset>` lines, where `<offset>` is the ball's horizontal position in the frame (-1.0 left edge, +1.0 right edge), or `BALL none` when nothing is detected.
- In auto mode, offset `<= -AUTO_CENTRE_BAND` turns left, `>= +AUTO_CENTRE_BAND` turns right, and anything inside the band drives straight; `BALL none` stops. `AUTO_CENTRE_BAND` (0.15) stops small jitter from making the robot hunt. Auto mode leaves L298N #1 alone: it is a suction brush, not a drive, so the operator may keep it running while the Pi steers.
- The Pi never arms auto mode itself — the app sends `A`/`M` over Bluetooth, and a dropped phone link drops auto mode too.

## Commands

```
pio run                      # compile (only automated verification; ~14s cold, no board needed)
pio run -t upload            # flash (needs board attached)
pio run -t monitor           # serial monitor (needs board attached)
pio run -e esp32doit-devkit-v1
pio debug -e esp32doit-devkit-v1
```

`pio` resolves from `~/.platformio/penv/Scripts` on PATH. First build downloads packages; later builds are offline.

Serial log lines are prefixed `[bt]`, `[cmd]`, `[spd]`, `[front]`, `[relay]`, `[auto]`, `[safety]`, `[boot]`. `platformio.ini` sets no `monitor_speed`, so the monitor defaults to 9600 baud and the log is unreadable — either add `monitor_speed = 115200` to the env or always use `pio device monitor -b 115200`. Note `-b` is a **`pio device monitor` flag**, not a `pio run` flag: `pio run -t monitor -b 115200` fails with `No such option '-b'`.

`platformio.ini` sets no `upload_port`, so upload needs an explicit port. On this machine the board enumerates as the CP210x bridge, so:

```
pio run -t upload --upload-port COM3
pio device monitor -p COM3 -b 115200
```

End-to-end bring-up order (all steps need the hardware):
1. `pio run -t upload --upload-port COM3`
2. `pio device monitor -p COM3 -b 115200`; confirm `[bt] advertising as ESP32_ROBOT, PIN 1234`.
3. On the phone: Settings → Bluetooth → pair `ESP32_ROBOT`, enter PIN `1234`. **Pairing only works from the system settings, never from the app** — Android does not allow it and this firmware does not implement it.
4. Open the app, tap the link button in the strip, pick `ESP32_ROBOT`, connect.
5. Press Tiến (the top-middle pad key) and look for `[cmd] F` on Serial, then `[safety] stopped: command timeout` after lifting. Try sang trái/phải (middle row, outer keys) and confirm the rear omni wheels follow the intended turn.
6. Tap the middle pad key and confirm `[front] on` / `[front] off`; while on, the suction brush should keep spinning after you lift every other key. Drag the corner speed keys and confirm `[spd] front=..` / `[spd] rear=..` changes (the ENA/ENB jumpers must be off — see below).
7. Tap the top-strip auto button, watch for `[auto] on`, and confirm the wheels track a ball the Pi reports (needs the Pi UART wired). Send `M` to return to manual.
8. Check `[safety] stopped: app disconnected` by turning the phone's Bluetooth off mid-drive. A compile cannot prove any of these watchdogs work.
9. Tap the relay button on the camera view; confirm `[relay] on` / `[relay] off` on Serial and that the module clicks. Turn Bluetooth off while it is on: `[relay] off` must appear.

## Layout / entrypoint

- `src/main.cpp` — motors (PWM speed), line command parsing, both watchdogs, the Bluetooth peripheral, and the Pi UART reader. Nothing else compiles into the firmware except `src/bluetooth_config.h`.
- `src/bluetooth_config.h` — device name and pairing PIN. The only "credentials" left.
- `include/`, `lib/`, `test/` — stock empty PlatformIO placeholders (README only). `test/` has no `test_*` directories, so `pio test` errors with 0 cases. Don't report tests as passing. **The protocol has no automated test on this side either**; `../flutter/test/robot_link_test.dart` checks the Dart side against a fake transport, but nothing verifies the ESP32 actually parses those bytes.
- `lib_deps` is absent from `platformio.ini`. `BluetoothSerial.h` comes from the Arduino core, no third-party libraries are needed.

**There is no way to verify behavior without the physical board.** A successful `pio run` proves the code compiles, nothing about whether the phone pairs, the socket opens, the watchdog fires, or the wheels turn the right way.

Arduino framework supplies `main()`. The program entrypoints are `setup()` / `loop()` — do not add a `main()`.

## Generated / gitignored files — never hand-edit

`.pio/`, `.vscode/c_cpp_properties.json`, and `.vscode/launch.json` are generated by the PlatformIO VS Code extension and are gitignored. To change include paths, build flags, or debug config, edit `platformio.ini` and regenerate. Never commit paths to `.platformio` or `D:/esp32/esp32` into tracked config.

## Toolchain versions are not pinned

`platformio.ini` says only `platform = espressif32` with no version. The build actually uses whatever is installed under `~/.platformio` (as of writing: espressif32 6.12.0, arduino-esp32 2.0.17, toolchain-xtensa-esp32 8.4.0). A clean machine or a fresh `pio pkg update` can silently change the compiler and framework.

**`BluetoothSerial` was removed from the core in arduino-esp32 3.x.** It is deprecated there and replaced by the external `ESP32-BT-Serial-ESP32` library. This firmware targets the 2.x core and depends on `BluetoothSerial.h` plus these 2.x-only facts:
- `begin(String localName, bool isMaster)` takes **no PIN argument**. The PIN must be set with `serialBt.setPin()` **before** `begin()`, because `_init_bt()` only forwards it to the GAP layer when the `_isPinSet` flag is already true and there is no later hook to redo it. Calling `begin(name, pin)` will not compile.
- There is **no** `setRxBufferSize()`. The receive queue size is fixed at compile time inside the library.

A `pio pkg update` that moves the core to 3.x breaks the build; add `lib_deps = bblanchon/ESP32-BT-Serial-ESP32` and switch to `BluetoothSerialESP32` if that happens.

No `upload_port` or `monitor_speed` is set. Don't hardcode a COM port — use `pio device list`.

## Firmware facts that are easy to get wrong

- **GPIO 12 is load-bearing and dangerous.** It is the MTDI strapping pin: if it reads HIGH at reset, the flash is set to 1.8V and the board can fail to boot. Never attach an external pull-up or load to it. GPIO 34–39 are input-only and unusable as motor drivers. GPIO 0/2/5/12/15 are all strapping pins, and GPIO 5 (`FL_IN2`) is already in use.
- **Speed is PWM, not jumper-selected.** Each wheel's L298N enable pin has its own LEDC channel (`PWM_CHANNELS` 0–3, 1000 Hz, 8-bit). `applyOutputs()` maps `frontSpeed`/`rearSpeed` (0–100, default 100/50) to per-wheel duty and writes channels 0/1 (brush module) and 2/3 (drive module), so a speed change re-applies to the running motors immediately. **The ENA/ENB jumpers must be removed** — the code assumes it now drives those pins. `stopAll()`/`stopDrive()` drive the stopped IN pairs LOW, which on the L298N is *coast*, not short brake; they leave the enable PWM alone.
- `loop()` is fully non-blocking and command-driven: check `hasClient()` → stop if gone (and drop auto mode) → `readPi()` → auto/command watchdog → `readCommands()`. **Flashing the board alone now does nothing** — it sits idle until a phone pairs and connects. There is no FreeRTOS task usage in this code and no interrupts.
- Classic Bluetooth on the ESP32 costs a lot of RAM: the controller and stack take roughly 50 KB of the 320 KB heap. The build reports ~40 KB used statically and the firmware logs free heap on the `[bt]` heartbeat precisely so a memory problem is visible. Anything added to this sketch has to fit in what is left.
- **All four motors are driven from the `MOTORS[]` table** (`struct Channel { inA, inB, enable, reversed }`). `applyOutputs()` relies on the load-bearing order: 0/2 are the left wheels, 1/3 the right ones. Reordering the table silently reverses the spin. Indices 0/1 are module 1 (suction brush), 2/3 module 2 (drive wheels). `DriveMode` selects the pattern: forward/backward use both rear wheels, turns counter-rotate them in place, strafes run the rear wheels in opposite directions, and the brush runs in reverse while `frontModuleOn`.
- `REVERSE_MOTOR3` and `REVERSE_MOTOR4` are `true` because the rear pair is mirrored relative to the front. `REVERSE_MOTOR2` is `false`; flip any of them individually rather than rewiring. The flag stays authoritative, so `applyOutputs()`'s "forward" always means forward for the chassis.
- **`S` and safety stops differ.** `stopDrive()` stops only the rear main drive, so the L298N #1 suction brush keeps running; `stopAll()` (link loss, command/auto timeout) stops the rear drive *and* switches the brush off. Entering or leaving auto mode uses `stopDrive()`, so the brush is not disturbed.
