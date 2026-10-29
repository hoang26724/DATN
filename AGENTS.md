# AGENTS.md

Graduation-thesis (DATN) repo for a robot + vision stack. **Three independent
sub-projects with no root build, no CI, no task runner, and no root manifest.**
Nothing at the root builds, tests, or runs anything. `flutter/` and `esp32/`
collaborate only through a Bluetooth byte protocol; `esp32/` also reads a UART
ball-position line from `raspberry/`.

Root `README.md` is a list of weekly demo video links, not documentation.

## Layout

| Path | What it is | Entrypoint | Deeper instructions |
| --- | --- | --- | --- |
| `flutter/` | Android-only app that drives the chassis over **Classic Bluetooth (RFCOMM/SPP)** with a console-style gamepad UI | `flutter/lib/main.dart`; the Bluetooth host is hand-written Kotlin at `flutter/android/app/src/main/kotlin/com/example/app_control_robot/MainActivity.kt` | **`flutter/AGENTS.md`** — read it before touching anything in `flutter/` |
| `esp32/` | PlatformIO firmware: ESP32 DOIT DEVKIT V1 + two L298N modules, four DC motors, Bluetooth peripheral | `esp32/src/main.cpp`, Arduino `setup()` / `loop()` (the framework supplies `main()`) | **`esp32/AGENTS.md`** — read it before touching anything in `esp32/` |
| `raspberry/` | One-file Pi service: IMX500 person detection + NCNN pickleball detection + RPLidar, exposed as an HTML/MJPEG dashboard on port 8000, and streams the ball's horizontal offset to the ESP32 over UART | `raspberry/pickleball.py` | none exists — read the file |

`raspberry/` is the weak spot and gets no instruction file: **no
`requirements.txt`, no linter, no test**. Dependencies are implicit (`picamera2`,
`picamera2.devices.imx500`, `rplidar`, `ncnn`, `cv2`, `numpy`); one model path is
absolute and Pi-specific
(`/usr/share/imx500-models/imx500_network_ssd_mobilenetv2_fpnlite_320x320_pp.rpk`);
the LIDAR is hardcoded to `/dev/ttyUSB0` @ 115200. It cannot run or be checked on
a dev machine at all. `raspberry/.gitignore` still ignores `rplidar_sdk/` and
`lidar_web/`, directories that no longer exist.

## Naming gotcha

The Dart package is named **`app_control_robot`** (`pubspec.yaml`), but it lives in
**`flutter/`** — there is no `app_control_robot/` directory. Import paths use the
package name, file paths use `flutter/`.

## The one cross-component contract

`flutter/` <-> `esp32/` only, over RFCOMM/SPP. Both sides must change together:

- device name `ESP32_ROBOT`, pairing PIN `1234` (firmware: `esp32/src/bluetooth_config.h`; app: the paired-device sheet)
- one ASCII line per command (ended by `\n`): `F` forward, `B` backward, `L` / `R` turn left / right, `S` stop the rear main drive; `f<0-100>` / `r<0-100>` set the suction-brush / drive L298N speed (suction boots at 100%, drive at 50%); `A` arms the Pi auto driver, `M` returns to manual; `G1` / `G0` turn the L298N #1 suction brush on / off; `Y1` / `Y0` close / open the relay on GPIO 32 (it also drops on link loss). The firmware still accepts `X` / `Z` strafe, but the app no longer sends them.
- **L298N #2 (rear) drives the two main omni wheels.** L298N #1 (front) drives the rotating suction brush, toggled by the middle pad key; while on, the app resends `G1` as a keep-alive so the firmware watchdog does not stop it. Auto mode leaves the brush alone (it is not a drive).
- firmware `COMMAND_TIMEOUT_MS` = 600 ms (stop when no byte arrives) vs app `RobotLink.firmwareCommandTimeout` = 600 ms and `keepAliveInterval` = 200 ms. The app's keep-alive is what keeps a held direction driving.
- firmware `AUTO_TIMEOUT_MS` = 600 ms (stop when no `BALL` line arrives from the Pi while auto is on)
- Changing the name or PIN forces re-pairing on the phone.

`raspberry/` shares no protocol with `flutter/`. It does feed `esp32/` over UART:
`BALL <offset>` (-1.0 left edge … +1.0 right edge) or `BALL none`, 115200 8N1 on
ESP32 GPIO 21/22 (`Serial2`). Do not assume the three parts are one system.

## Commands

Run each from its own directory; there is no root-level invocation.

```
# flutter/  — `flutter pub get` is required once after clone (pubspec.lock is committed)
flutter analyze                  # typecheck + lint. `flutter_lints`; analysis_options.yaml excludes
                                 # android/** so Kotlin is NEVER analyzed here
flutter test                     # 56 tests, headless, no hardware needed
flutter build apk --debug        # the ONLY automated check that MainActivity.kt compiles
flutter run                      # needs an Android phone with the robot already paired

# esp32/
pio run                          # the only automated check (~19s, no board needed)
pio run -t upload --upload-port COM3
pio device monitor -p COM3 -b 115200     # note: -b is a `pio device monitor` flag, not a `pio run` one
```

No `upload_port` or `monitor_speed` is set in `platformio.ini`; discover the port
with `pio device list` rather than assuming `COM3`.

## What no automated check can prove

`flutter analyze` / `flutter test` prove nothing about the Kotlin host's runtime
behaviour (a wrong `as?` cast is valid Kotlin). `pio run` proves only that the
firmware compiles. Unproven without hardware: Bluetooth pairing, the socket
opening, the command and auto watchdogs firing, motor direction and PWM speed,
the Pi UART link, and all of `raspberry/`. The
end-to-end bring-up order is in `esp32/AGENTS.md`.

Also note `esp32/test/` holds only the stock PlatformIO README — `pio test` errors
with 0 cases. Never report ESP32-side tests as passing.

## Conventions

- **User-facing text is Vietnamese; code comments and identifiers are English.** READMEs, the root `.docx` deliverables, the Kotlin `BluetoothUnavailable` messages, and the Python log/print strings are all Vietnamese without diacritics in some places — match whatever the file already does rather than normalising it.
- The two root `.docx` files (`Báo cáo tuần 3.docx`, `Ke Hoach Thuc hien DATN.docx`) are the report and plan deliverables. Don't regenerate or reformat them.

## Repo hygiene

- One git repo at the root, branch `main`, very few commits. No CI, no hooks, no pre-commit config, no root `.gitignore`.
- Generated and gitignored — never hand-edit or commit: `esp32/.pio/`, `esp32/.vscode/c_cpp_properties.json`, `esp32/.vscode/launch.json`, `flutter/.dart_tool/`, `flutter/build/`. Change build config in `platformio.ini` / `analysis_options.yaml` instead.
- Binary weights are committed deliberately: `raspberry/pickleball_Yolo11n.pt` and `raspberry/pickleball_Yolo11n_ncnn_model/model.ncnn.bin`. Don't delete them as "artifacts", and don't regenerate them casually.
- `esp32/` targets the **arduino-esp32 2.x** core; `BluetoothSerial.h` was removed in 3.x. `platform = espressif32` is unpinned, so a `pio pkg update` can silently break the build. See `esp32/AGENTS.md`.