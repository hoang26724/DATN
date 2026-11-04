#!/usr/bin/env python3
import argparse
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("Thieu pyserial. Cai bang: pip install pyserial")


def wait_for(ser, prefix, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = ser.readline().decode(errors="replace").strip()
        if not line:
            continue
        print("  ESP32:", line)
        if line.startswith(prefix):
            return line
    return None


def main():
    parser = argparse.ArgumentParser(description="ESP32 gui 1 bit, Rasp kiem tra va yeu cau relay GPIO32")
    parser.add_argument("-p", "--port", default="/dev/ttyAMA0", help="Pi 5: /dev/ttyAMA0, Pi 4: /dev/serial0, USB: /dev/ttyUSB0")
    parser.add_argument("-b", "--baud", type=int, default=115200)
    parser.add_argument("-e", "--expected", type=int, choices=[0, 1], default=1, help="bit dung de so sanh")
    parser.add_argument("-n", "--count", type=int, default=0, help="so bit can test (0 = vo han)")
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=6) as ser:
        time.sleep(1.5)
        ser.reset_input_buffer()
        ser.write(b"RESETSEQ\n")
        ser.flush()
        print("Ket noi %s @ %d | bit dung = %d" % (args.port, args.baud, args.expected))

        tested = 0
        try:
            while args.count == 0 or tested < args.count:
                line = ser.readline().decode(errors="replace").strip()
                if not line:
                    continue
                print("ESP32:", line)

                if not line.startswith("BIT:"):
                    continue

                try:
                    bit = int(line.split(":", 1)[1])
                except ValueError:
                    print("  -> Khung bit khong hop le, bo qua")
                    continue

                correct = (bit == args.expected)
                pulses = 1 if correct else 2
                verdict = "DUNG" if correct else "SAI"
                print("  -> bit #%d: nhan=%d, ky vong=%d => %s, yeu cau PULSE:%d"
                      % (tested + 1, bit, args.expected, verdict, pulses))

                ser.write(("PULSE:%d\n" % pulses).encode())
                ser.flush()

                done = wait_for(ser, "PULSE_DONE:", 3.0 * pulses + 3.0)
                if done is None:
                    print("  -> Khong nhan PULSE_DONE")
                tested += 1
        except KeyboardInterrupt:
            ser.write(b"OFF\n")
            ser.flush()
            print("\nDa dung, relay OFF")


if __name__ == "__main__":
    main()
