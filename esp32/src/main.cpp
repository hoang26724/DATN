                                                                                                                                          #include <Arduino.h>
#include <BluetoothSerial.h>

#include "bluetooth_config.h"

// L298N driver pin mapping
// Module 1 - Motor 1 (front-left):  IN1 = GPIO18, IN2 = GPIO19 -> OUT1 / OUT2
//            Motor 2 (front-right): IN3 = GPIO5,  IN4 = GPIO17 -> OUT3 / OUT4
// Module 2 - Motor 3 (rear-left):   IN5 = GPIO12, IN6 = GPIO14 -> OUT1 / OUT2
//            Motor 4 (rear-right):  IN7 = GPIO27, IN8 = GPIO26 -> OUT3 / OUT4
// ENA / ENB jumpers on both modules must stay installed.
// WARNING: GPIO12 is the MTDI strapping pin. If it is pulled HIGH while the
// chip resets, the flash is configured for 1.8V and the board may not boot.
// Never fit an external pull-up on GPIO12.
constexpr uint8_t IN1 = 18;
constexpr uint8_t IN2 = 19;
constexpr uint8_t IN3 = 5;
constexpr uint8_t IN4 = 17;
constexpr uint8_t IN5 = 12;
constexpr uint8_t IN6 = 14;
constexpr uint8_t IN7 = 27;
constexpr uint8_t IN8 = 26;

struct Channel {
  uint8_t inA;
  uint8_t inB;
  bool reversed;
};

// Chassis forward direction: the rear pair (motors 3 and 4) is mirrored
// relative to the front pair, so both pairs push the chassis the same way.
// A motor wired against these still needs its own flag set to true.
constexpr bool REVERSE_MOTOR2 = false;
constexpr bool REVERSE_MOTOR3 = true;
constexpr bool REVERSE_MOTOR4 = true;

constexpr Channel MOTORS[] = {
    {IN1, IN2, false},
    {IN3, IN4, REVERSE_MOTOR2},
    {IN5, IN6, REVERSE_MOTOR3},
    {IN7, IN8, REVERSE_MOTOR4},
};
// Order matters: index 0/2 must be the left wheels, index 1/3 the right ones,
// because drive() picks its direction from the index parity.

constexpr size_t MOTOR_COUNT = sizeof(MOTORS) / sizeof(MOTORS[0]);

// ---- Bluetooth ----------------------------------------------------------
// Classic Bluetooth (RFCOMM / SPP) peripheral, not BLE. The Flutter app pairs
// with BLUETOOTH_DEVICE_NAME and opens one socket. There is no IP address and
// no WiFi anywhere in this firmware any more.
//
// A command is one ASCII character, optionally followed by '\n':
//   F = forward, B = backward, L = left, R = right, S = stop
// Upper and lower case both work, line endings are ignored.
//
// BluetoothSerial ships with the Arduino ESP32 core (no lib_deps needed). It
// was removed from the core in arduino-esp32 3.x in favour of the external
// ESP32-BT-Serial-ESP32 library; this firmware targets the 2.x core.
BluetoothSerial serialBt;

// Idle yield when a phone is linked but sending nothing. loop() would
// otherwise spin at full speed; the Bluetooth stack runs on the other core so
// this costs at most one tick of command latency, which is nothing next to the
// keep-alive interval.
constexpr uint8_t IDLE_DELAY_MS = 1;

// Safety net: if no byte at all arrives for this long, motors stop. The app
// must therefore re-send the held command well inside this window. Kept a little
// above the app's 200 ms keep-alive so ordinary Bluetooth jitter cannot stop
// the robot mid-hold.
constexpr uint32_t COMMAND_TIMEOUT_MS = 600;

// Serial is for humans, Bluetooth is for the app. Print the link state on a
// slow heartbeat instead of only on transitions, so opening the monitor late
// still shows whether a phone is attached.
constexpr uint32_t HEARTBEAT_INTERVAL_MS = 5000;

uint32_t lastCommandMs = 0;
uint32_t lastHeartbeatMs = 0;
bool motorsRunning = false;
bool linkAnnounced = false;

void drive(bool leftForward, bool rightForward);
void stopAll();
void stopForSafety(const char* reason);

void applyCommand(char command) {
  switch (command) {
    case 'F':
    case 'f':
      drive(true, true);
      motorsRunning = true;
      break;
    case 'B':
    case 'b':
      drive(false, false);
      motorsRunning = true;
      break;
    case 'L':
    case 'l':
      drive(false, true);
      motorsRunning = true;
      break;
    case 'R':
    case 'r':
      drive(true, false);
      motorsRunning = true;
      break;
    case 'S':
    case 's':
      stopAll();
      motorsRunning = false;
      break;
    default:
      break;
  }
  lastCommandMs = millis();
}

void stopForSafety(const char* reason) {
  if (!motorsRunning) {
    return;
  }
  stopAll();
  motorsRunning = false;
  Serial.print("[safety] stopped: ");
  Serial.println(reason);
}

void readCommands() {
  while (serialBt.available() > 0) {
    const char command = static_cast<char>(serialBt.read());
    if (command == '\n' || command == '\r') {
      continue;
    }
    Serial.print("[cmd] ");
    Serial.println(command);
    applyCommand(command);
  }
}

void announceLink() {
  const uint32_t now = millis();
  if (linkAnnounced && now - lastHeartbeatMs < HEARTBEAT_INTERVAL_MS) {
    return;
  }
  lastHeartbeatMs = now;

  if (!linkAnnounced) {
    Serial.print("[bt] advertising as ");
    Serial.print(BLUETOOTH_DEVICE_NAME);
    Serial.print(", PIN ");
    Serial.println(BLUETOOTH_PIN);
    Serial.println("[bt] pair the phone, then open the app");
    linkAnnounced = true;
    return;
  }

  Serial.print("[bt] waiting for app, free heap ");
  Serial.print(ESP.getFreeHeap());
  Serial.println(" bytes");
}

void setup() {
  for (const Channel& motor : MOTORS) {
    pinMode(motor.inA, OUTPUT);
    pinMode(motor.inB, OUTPUT);
  }
  stopAll();

  Serial.begin(115200);
  Serial.println("[boot] ESP32 robot controller (Bluetooth)");

  // setPin() must come before begin(): _init_bt() only forwards the PIN to the
  // GAP layer if the flag is already set, and there is no later hook to redo it.
  serialBt.setPin(BLUETOOTH_PIN);
  serialBt.begin(BLUETOOTH_DEVICE_NAME);
}

void loop() {
  // hasClient() flips false as soon as the RFCOMM socket goes away, which is
  // the Bluetooth equivalent of the old client.connected() check. Drop the
  // motors before doing anything else so a phone that walks out of range never
  // leaves the robot driving.
  if (!serialBt.hasClient()) {
    stopForSafety("app disconnected");
    announceLink();
    delay(20);
    return;
  }

  if (motorsRunning && millis() - lastCommandMs > COMMAND_TIMEOUT_MS) {
    stopForSafety("command timeout");
  }

  readCommands();
  announceLink();
  delay(IDLE_DELAY_MS);
}

// MOTORS is ordered left/right, left/right: 0 front-left, 1 front-right,
// 2 rear-left, 3 rear-right. The per-motor reversed flag stays authoritative,
// so "forward" here always means forward for the chassis, never per-wheel.
void drive(bool leftForward, bool rightForward) {
  for (size_t i = 0; i < MOTOR_COUNT; i++) {
    const Channel& motor = MOTORS[i];
    const bool isLeft = (i % 2) == 0;
    const bool forward = isLeft ? leftForward : rightForward;
    const bool aHigh = forward != motor.reversed;

    digitalWrite(motor.inA, aHigh ? HIGH : LOW);
    digitalWrite(motor.inB, aHigh ? LOW : HIGH);
  }
}

void stopAll() {
  for (const Channel& motor : MOTORS) {
    digitalWrite(motor.inA, LOW);
    digitalWrite(motor.inB, LOW);
  }
}
