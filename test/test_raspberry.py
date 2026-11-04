import serial
import time

ser = serial.Serial("/dev/ttyAMA0", 115200, timeout=1)
expected = "1"   # bit dung la 1

print("Dang cho du lieu tu ESP...")
ser.reset_input_buffer()
ser.write(b"RESET\n")
time.sleep(0.2)

while True:
    line = ser.readline().decode(errors="ignore").strip()
    if not line:
        continue
    print("ESP32:", line)

    # Chi xu ly dong BIT:x, bo qua ACK, PULSE_START, PULSE_DONE
    if line.startswith("BIT:"):
        bit = line.split(":")[1]
        if bit == expected:
            print(f"  nhan={bit}, ky vong={expected} => DUNG, gui PULSE:1")
            ser.write(b"PULSE:1\n")
        else:
            print(f"  nhan={bit}, ky vong={expected} => SAI, gui PULSE:2")
            ser.write(b"PULSE:2\n")

