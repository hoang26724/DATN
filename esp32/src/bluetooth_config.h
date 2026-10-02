#pragma once

// Classic Bluetooth (SPP) identity of this robot.
//
// BLUETOOTH_DEVICE_NAME is what shows up in the phone's paired-device list.
// BLUETOOTH_PIN is the Simple Pairing Key: the phone must enter the exact same
// digits while pairing, otherwise the RFCOMM socket never opens.
constexpr char BLUETOOTH_DEVICE_NAME[] = "ESP32_ROBOT";
constexpr char BLUETOOTH_PIN[] = "1234";
