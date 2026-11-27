#include <Arduino.h>
#include <BluetoothSerial.h>

#include "bluetooth_config.h"

// ---- L298N driver pin mapping -------------------------------------------
// L298N #2 (rear) drives the two main wheels. L298N #1 (front) drives the
// rotating suction brush, toggled from the middle pad key in the app.
//
// On each module the "A" half (IN1/IN2 + ENA) is the left wheel and the "B"
// half (IN3/IN4 + ENB) is the right one.
//
//   L298N #1 - suction brush: IN1=25, IN2=26, IN3=27, IN4=14, ENA=33, ENB=13
//   L298N #2 - drive wheels:  IN1=18, IN2=5,  IN3=17, IN4=16, ENA=19, ENB=4
//
// The ENA/ENB jumpers must now be REMOVED: those pins are driven as PWM so the
// speed of each module can be set from the app.
constexpr uint8_t FR_IN1 = 25;
constexpr uint8_t FR_IN2 = 26;
constexpr uint8_t FL_IN3 = 27;
constexpr uint8_t FL_IN4 = 14;
constexpr uint8_t FR_ENA = 33;
constexpr uint8_t FL_ENB = 13;
constexpr uint8_t RR_IN1 = 18;
constexpr uint8_t RR_IN2 = 5;
constexpr uint8_t RL_IN3 = 17;
constexpr uint8_t RL_IN4 = 16;
constexpr uint8_t RR_ENA = 19;
constexpr uint8_t RL_ENB = 4;

// ---- Relay --------------------------------------------------------------
// GPIO 32 drives a relay module, active HIGH (HIGH = closed). It is free of
// every motor IN line and all strapping pins. Driven by the
// absolute commands "Y1" (on) / "Y0" (off), not a toggle, so the app's state
// can never drift from the pin. The relay drops whenever the phone link dies,
// same rationale as the motors.
constexpr uint8_t RELAY_PIN = 32;

struct Channel {
  uint8_t inA;
  uint8_t inB;
  uint8_t enable;
  bool reversed;
};

// Chassis forward direction: the rear pair (motors 3 and 4) is mirrored
// relative to the front pair, so both pairs push the chassis the same way.
// A motor wired against these still needs its own flag set to true.
constexpr bool REVERSE_MOTOR2 = false;
constexpr bool REVERSE_MOTOR3 = true;
constexpr bool REVERSE_MOTOR4 = true;

constexpr Channel MOTORS[] = {
    {FR_IN1, FR_IN2, FR_ENA, false},
    {FL_IN3, FL_IN4, FL_ENB, REVERSE_MOTOR2},
    {RR_IN1, RR_IN2, RR_ENA, REVERSE_MOTOR3},
    {RL_IN3, RL_IN4, RL_ENB, REVERSE_MOTOR4},
};
// Order matters: index 0/2 must be the left wheels, index 1/3 the right ones,
// because applyOutputs() picks its direction from the index parity.

constexpr size_t MOTOR_COUNT = sizeof(MOTORS) / sizeof(MOTORS[0]);

// One LEDC PWM channel per wheel's enable pin. Module 1's two channels share
// the brush speed, module 2's two share the drive speed (except while turning,
// where the inner rear wheel is deliberately slowed).
constexpr uint8_t PWM_CHANNELS[MOTOR_COUNT] = {0, 1, 2, 3};
constexpr uint32_t PWM_FREQUENCY = 1000;
constexpr uint8_t PWM_RESOLUTION = 8;
constexpr uint32_t PWM_MAX_DUTY = (1u << PWM_RESOLUTION) - 1;

constexpr int SPEED_MIN = 0;
constexpr int SPEED_MAX = 100;
constexpr int DEFAULT_FRONT_SPEED = 100;
constexpr int DEFAULT_REAR_SPEED = 50;

// ---- Bluetooth ----------------------------------------------------------
// Classic Bluetooth (RFCOMM / SPP) peripheral, not BLE. The Flutter app pairs
// with BLUETOOTH_DEVICE_NAME and opens one socket. There is no IP address and
// no WiFi anywhere in this firmware any more.
//
// A command is one ASCII line, optionally followed by '\n'. Upper case letters
// drive, lower case set a speed, and only the first letter is looked at:
//   F = forward, B = backward
//   L = turn left, R = turn right (pivot: the two rear wheels counter-rotate)
//   X = strafe left, Z = strafe right (accepted, unused by the current app)
//   S = stop the rear main drive (the suction brush keeps its own state)
//   f<0-100> = front-module (L298N #1) speed, e.g. "f50"
//   r<0-100> = rear-module  (L298N #2) speed, e.g. "r50"
//   G1 = suction brush (L298N #1) on, G0 = off; it runs in the reverse direction.
//        The app resends G1 as a keep-alive while the toggle is on.
//   Y1 = relay (GPIO 32) on, Y0 = off; the relay also drops on link loss
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

// Safety net: if no byte at all arrives for this long while driving manually,
// motors stop. The app must therefore re-send the held command well inside this
// window. Kept a little above the app's 200 ms keep-alive so ordinary Bluetooth
// jitter cannot stop the robot mid-hold. When L298N #1 is toggled on, the app
// sends G1 on the same cadence, which is what keeps the suction brush running.
constexpr uint32_t COMMAND_TIMEOUT_MS = 600;

// Serial is for humans, Bluetooth is for the app. Print the link state on a
// slow heartbeat instead of only on transitions, so opening the monitor late
// still shows whether a phone is attached.
constexpr uint32_t HEARTBEAT_INTERVAL_MS = 5000;

enum class DriveMode {
  stop,
  forward,
  backward,
  turnLeft,
  turnRight,
  strafeLeft,
  strafeRight,
};

// Which link sent the last command. The phone's link-loss stop must only fire
// for phone-driven motion; the Pi drives over USB and has its own 600 ms
// command timeout.
enum class CommandSource {
  none,
  bluetooth,
  usb,
};

// The phone app (Bluetooth) and the Raspberry Pi's auto.py (USB serial) both
// speak the same line protocol. Each source gets its own buffer so a partial
// line from one link can never splice onto a partial line from the other.
constexpr size_t COMMAND_LINE_SIZE = 16;
char btCommandLine[COMMAND_LINE_SIZE];
size_t btCommandLength = 0;
char usbCommandLine[COMMAND_LINE_SIZE];
size_t usbCommandLength = 0;

uint32_t lastCommandMs = 0;
uint32_t lastHeartbeatMs = 0;
CommandSource lastCommandSource = CommandSource::none;
bool motorsRunning = false;
bool linkAnnounced = false;
bool relayOn = false;
bool frontModuleOn = false;
DriveMode driveMode = DriveMode::stop;

int frontSpeed = DEFAULT_FRONT_SPEED;
int rearSpeed = DEFAULT_REAR_SPEED;

void driveMotor(const Channel& motor, uint8_t pwmChannel, bool forward,
                int percent);
void applyOutputs();
void stopAll();
void stopDrive();
void stopForSafety(const char* reason);

void setRelay(bool on) {
  // auto.py resends "Y1" as a keep-alive; do not spam the log or re-drive the
  // pin when the state has not changed.
  if (relayOn == on) {
    return;
  }
  relayOn = on;
  digitalWrite(RELAY_PIN, on ? HIGH : LOW);
  Serial.print("[relay] ");
  Serial.println(on ? "on" : "off");
}

void setFrontModule(bool on) {
  frontModuleOn = on;
  motorsRunning = driveMode != DriveMode::stop || frontModuleOn;
  applyOutputs();
  Serial.print("[front] ");
  Serial.println(on ? "on" : "off");
}

void setSpeed(bool front, int percent) {
  percent = constrain(percent, SPEED_MIN, SPEED_MAX);
  if (front) {
    frontSpeed = percent;
  } else {
    rearSpeed = percent;
  }
  applyOutputs();
  Serial.print("[spd] front=");
  Serial.print(frontSpeed);
  Serial.print(" rear=");
  Serial.println(rearSpeed);
}

void setDriveMode(DriveMode mode) {
  driveMode = mode;
  motorsRunning = driveMode != DriveMode::stop || frontModuleOn;
  applyOutputs();
}

void applyOutputs() {
  int leftPercent = 0;
  int rightPercent = 0;
  bool leftForward = true;
  bool rightForward = true;

  switch (driveMode) {
    case DriveMode::stop:
      break;
    case DriveMode::forward:
      leftPercent = rearSpeed;
      rightPercent = rearSpeed;
      break;
    case DriveMode::backward:
      leftPercent = rearSpeed;
      rightPercent = rearSpeed;
      leftForward = false;
      rightForward = false;
      break;
    case DriveMode::turnLeft:
      leftPercent = rearSpeed;
      rightPercent = rearSpeed;
      leftForward = false;
      rightForward = true;
      break;
    case DriveMode::turnRight:
      leftPercent = rearSpeed;
      rightPercent = rearSpeed;
      leftForward = true;
      rightForward = false;
      break;
    case DriveMode::strafeLeft:
      leftPercent = rearSpeed;
      rightPercent = rearSpeed;
      leftForward = false;
      rightForward = true;
      break;
    case DriveMode::strafeRight:
      leftPercent = rearSpeed;
      rightPercent = rearSpeed;
      leftForward = true;
      rightForward = false;
      break;
  }

  // Module 2 drives the two main (rear) wheels.
  driveMotor(MOTORS[2], PWM_CHANNELS[2], leftForward, leftPercent);
  driveMotor(MOTORS[3], PWM_CHANNELS[3], rightForward, rightPercent);

  // Module 1 drives the suction brush and runs continuously while toggled on.
  // It spins in reverse, the direction that pulls debris into the intake.
  const int brushPercent = frontModuleOn ? frontSpeed : 0;
  driveMotor(MOTORS[0], PWM_CHANNELS[0], false, brushPercent);
  driveMotor(MOTORS[1], PWM_CHANNELS[1], false, brushPercent);
}

void applyCommand(const char* command) {
  lastCommandMs = millis();
  switch (command[0]) {
    // Upper case drives. Lower case 'f'/'r' are the speed setters, so those two
    // letters are the only drive commands that are not accepted lower case.
    case 'F':
      setDriveMode(DriveMode::backward);
      break;
    case 'f':
      setSpeed(true, atoi(command + 1));
      break;
    case 'B':
      setDriveMode(DriveMode::forward);
      break;
    case 'L':
      setDriveMode(DriveMode::turnLeft);
      break;
    case 'R':
      setDriveMode(DriveMode::turnRight);
      break;
    case 'X':
      setDriveMode(DriveMode::strafeLeft);
      break;
    case 'Z':
      setDriveMode(DriveMode::strafeRight);
      break;
    case 'r':
      setSpeed(false, atoi(command + 1));
      break;
    case 'S':
    case 's':
      // Stop the rear main drive, but leave the suction brush to its own
      // absolute G1/G0 toggle. Safety stops use stopAll() instead.
      stopDrive();
      break;
    case 'G':
    case 'g':
      // Absolute on/off, not a toggle: "G1" enables the suction brush, anything
      // else ("G0") disables it.
      setFrontModule(command[1] != '0');
      break;
    case 'Y':
    case 'y':
      // Absolute on/off, not a toggle: "Y1" closes the relay, anything else
      // ("Y0") opens it, so a reconnect cannot leave the app out of sync.
      setRelay(command[1] != '0');
      break;
    default:
      break;
  }
}

void stopForSafety(const char* reason) {
  if (!motorsRunning) {
    return;
  }
  stopAll();
  Serial.print("[safety] stopped: ");
  Serial.println(reason);
}

void readCommandStream(Stream& stream, char* line, size_t& length,
                       CommandSource source) {
  while (stream.available() > 0) {
    const char byte = static_cast<char>(stream.read());
    if (byte == '\n' || byte == '\r') {
      if (length > 0) {
        line[length] = '\0';
        Serial.print("[cmd] ");
        Serial.println(line);
        lastCommandSource = source;
        applyCommand(line);
        length = 0;
      }
      continue;
    }
    if (length < COMMAND_LINE_SIZE - 1) {
      line[length++] = byte;
    }
  }
}

void readCommands() {
  // Bluetooth is the phone app; Serial is the USB (CP2102) link the Pi's
  // auto.py writes to. The same F/B/L/R/S, r<0-100>, G1/G0, Y1/Y0 commands
  // work on either link.
  readCommandStream(serialBt, btCommandLine, btCommandLength,
                    CommandSource::bluetooth);
  readCommandStream(Serial, usbCommandLine, usbCommandLength,
                    CommandSource::usb);
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
  for (size_t i = 0; i < MOTOR_COUNT; i++) {
    pinMode(MOTORS[i].inA, OUTPUT);
    pinMode(MOTORS[i].inB, OUTPUT);
    pinMode(MOTORS[i].enable, OUTPUT);
    ledcSetup(PWM_CHANNELS[i], PWM_FREQUENCY, PWM_RESOLUTION);
    ledcAttachPin(MOTORS[i].enable, PWM_CHANNELS[i]);
  }
  stopAll();

  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, LOW);

  Serial.begin(115200);
  Serial.println("[boot] ESP32 robot controller (Bluetooth)");
  Serial.print("[boot] speeds front=");
  Serial.print(frontSpeed);
  Serial.print(" rear=");
  Serial.println(rearSpeed);

  // setPin() must come before begin(): _init_bt() only forwards the PIN to the
  // GAP layer if the flag is already set, and there is no later hook to redo it.
  serialBt.setPin(BLUETOOTH_PIN);
  serialBt.begin(BLUETOOTH_DEVICE_NAME);
}

void loop() {
  // hasClient() flips false as soon as the RFCOMM socket goes away. A phone
  // that walks out of range must stop phone-driven motion immediately, but it
  // must not stop the Pi: the Pi drives over the USB serial link and its own
  // 600 ms command timeout is the safety net there.
  if (!serialBt.hasClient()) {
    // The relay is as dangerous as a spinning wheel to whoever is standing
    // next to the robot, so a dead phone link drops it too. While the Pi is
    // driving over USB it resends "Y1" every 200 ms; keep the relay closed
    // only while that keep-alive is fresh, so a dead Pi still drops it.
    const bool usbCommandFresh =
        lastCommandSource == CommandSource::usb &&
        millis() - lastCommandMs <= COMMAND_TIMEOUT_MS;
    if (relayOn && !usbCommandFresh) {
      setRelay(false);
    }
    if (lastCommandSource == CommandSource::bluetooth) {
      stopForSafety("app disconnected");
    }
  }

  if (motorsRunning && millis() - lastCommandMs > COMMAND_TIMEOUT_MS) {
    stopForSafety("command timeout");
  }

  readCommands();
  announceLink();
  delay(IDLE_DELAY_MS);
}

// One wheel: drives the IN pair for direction and the enable pin for speed.
// A zero speed coasts the motor (both IN lines LOW) instead of braking it.
void driveMotor(const Channel& motor, uint8_t pwmChannel, bool forward,
                int percent) {
  if (percent <= SPEED_MIN) {
    digitalWrite(motor.inA, LOW);
    digitalWrite(motor.inB, LOW);
    ledcWrite(pwmChannel, 0);
    return;
  }
  percent = constrain(percent, SPEED_MIN, SPEED_MAX);
  const bool aHigh = forward != motor.reversed;
  digitalWrite(motor.inA, aHigh ? HIGH : LOW);
  digitalWrite(motor.inB, aHigh ? LOW : HIGH);
  const uint32_t duty = (uint32_t)percent * PWM_MAX_DUTY / SPEED_MAX;
  ledcWrite(pwmChannel, duty);
}

// Full safety stop: rear drive off, suction brush off. Used on link loss and
// watchdogs. Do not use it for a normal S command, which must leave the brush
// toggle alone.
void stopAll() {
  driveMode = DriveMode::stop;
  frontModuleOn = false;
  motorsRunning = false;
  applyOutputs();
}

// Stop the rear main drive only. The suction brush keeps running if its toggle
// is on, so releasing a direction key does not kill it.
void stopDrive() {
  driveMode = DriveMode::stop;
  motorsRunning = frontModuleOn;
  applyOutputs();
}
