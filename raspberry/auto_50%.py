

"""
Camera AI + Pickleball auto-search cho Raspberry Pi 5.

Chay: python3 auto_50%.py
Xem: http://<IP_CUA_PI>:8000/

File nay thay the pickleball.py khi muon xe tu tim bong:
- Van phuc vu /stream.mjpg va /stats de app Flutter hien thi hinh camera.
- Nhan dien bong pickleball bang NCNN va ve khung bong len hinh.
- Dieu khien ESP32 qua USB (CP2102, mac dinh /dev/ttyUSB0, 115200 8N1):
    * Khong thay bong -> gui "r50" + "R" lap lai (quay phai 50%).
    * Thay bong -> chi quay "L"/"R" tai cho de dua tam bong vao vung 85-95 do
      (khung hinh tinh theo goc: mep trai 0 do, chinh dien 90 do, mep phai
      180 do). Khong tien toi khi bong con lech.
    * Bong trong vung 85-95 do -> dung yen giu tam ~2 s cho xe on dinh, sau do
      moi gui "F" de tien toi va "G1" de bat hut, giu den khi bong mat khoi
      khung hinh; xe dung lai nhung van hut them ~1 s roi moi quay tim.
    * Luon bat relay GPIO 32 ("Y1") trong suot thoi gian chay.

Luu y: firmware trong esp32/src/main.cpp doc lenh tren ca Bluetooth lan USB
serial (Serial), nen Pi co the dieu khien xe qua USB ma khong can app ket noi
Bluetooth. App Flutter chi can ket noi khi muon dieu khien tay.
"""

import json
import logging
import os
import socketserver
import termios
import time
from http import server
from threading import Condition, Event, RLock, Thread

import cv2
import numpy as np
from picamera2 import Picamera2
from picamera2.devices.imx500 import IMX500

try:
    import ncnn
except ImportError as exc:
    raise ImportError("Can cai dat goi ncnn de chay model pickleball") from exc


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CAM_SIZE = (640, 480)
# Camera tren robot duoc lap nguoc chieu, nen khung hinh bi lat 180 do.
CAMERA_ROTATE_180 = True
HTTP_PORT = 8000
JPEG_QUALITY = 80
# How long /stream.mjpg waits for a new camera frame before hanging up.
STREAM_STALL_TIMEOUT_S = 8.0

# ESP32 USB serial link (CP2102). Override with ROBOT_SERIAL_PORT if the board
# enumerates somewhere else (e.g. /dev/ttyACM0).
SERIAL_PORT = os.environ.get('ROBOT_SERIAL_PORT', '/dev/ttyUSB0')
SERIAL_BAUDRATE = 115200
SERIAL_RETRY_S = 2.0

# Search behaviour: while no ball is visible, keep the rear drive turning right
# at 50%. The firmware stops the motors after 600 ms without a byte, so the
# turn command must be re-sent faster than that.
SEARCH_SPEED = 50
DRIVE_KEEPALIVE_S = 0.2
# Re-send "r50" occasionally so a speed change made from the app cannot make
# the search turn faster or slower than 50%.
SPEED_REFRESH_S = 1.0
# A single missed detection must not make the robot stutter, so wait a moment
# after the last visible ball before starting the search again.
BALL_LOST_GRACE_S = 0.3
# Keep the GPIO 32 relay closed for the whole run. The firmware drops it after
# COMMAND_TIMEOUT_MS without a byte, so it must be refreshed.
RELAY_KEEPALIVE_S = 0.2

# Ball tracking: the camera frame spans 0 deg (left edge) to 180 deg (right
# edge), so straight ahead is 90 deg. Rotate in place until the ball centre is
# inside the 85-95 deg band; only then drive forward and suck. Moving forward
# while the ball is still off-centre makes the intake miss it.
BALL_ALIGN_MIN_DEG = 85.0
BALL_ALIGN_MAX_DEG = 95.0
# Once the ball is inside the band, stop the chassis and hold it there for this
# long before driving forward, so any residual rotation has settled and the
# ball is confirmed centred. If the ball leaves the band, alignment resumes.
CENTER_HOLD_S = 2.0
TRACK_TURN_SPEED = 50
APPROACH_SPEED = 60
# Once the ball is gone from frame, keep the brush spinning a little longer to
# finish pulling it into the intake before giving up and searching again.
SUCTION_AFTER_LOSS_S = 1.0
BRUSH_KEEPALIVE_S = 1.0

MODEL_PATH = '/usr/share/imx500-models/imx500_network_ssd_mobilenetv2_fpnlite_320x320_pp.rpk'
PICKLEBALL_THRESHOLD = 0.5
PICKLEBALL_NMS_THRESHOLD = 0.45
PICKLEBALL_INPUT_SIZE = 640
PICKLEBALL_LABEL = 'pickleball'
NCNN_MODEL_DIR = os.path.join(BASE_DIR, 'pickleball_Yolo11n_ncnn_model')
NCNN_PARAM_PATH = os.path.join(NCNN_MODEL_DIR, 'model.ncnn.param')
NCNN_BIN_PATH = os.path.join(NCNN_MODEL_DIR, 'model.ncnn.bin')

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
)

PAGE = """\
<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Robot Pickleball - Auto</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    padding: 24px;
    color: #edf6ff;
    font-family: Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    background: radial-gradient(circle at 10% 0%, rgba(37,119,170,.28), transparent 34rem),
                linear-gradient(135deg, #07111f 0%, #0b1829 52%, #081321 100%);
  }
  main { width: min(760px, 100%); margin: 0 auto; }
  h1 { margin: 0 0 6px; font-size: clamp(24px, 4vw, 36px); letter-spacing: -.03em; }
  p { margin: 0 0 18px; color: #9eb3c9; }
  .frame { overflow: hidden; border: 1px solid rgba(255,255,255,.1); border-radius: 18px; background: #03070d; }
  .frame img { display: block; width: 100%; height: auto; aspect-ratio: 4 / 3; object-fit: contain; }
  .stats { display: flex; gap: 10px; margin-top: 14px; flex-wrap: wrap; }
  .stat { padding: 8px 12px; border: 1px solid rgba(148,183,216,.18); border-radius: 10px; background: rgba(255,255,255,.035); font-size: 13px; }
  .stat b { color: #5ee7f7; }
</style>
</head>
<body>
<main>
  <h1>Robot Pickleball - Auto</h1>
  <p>Khong thay bong: quay phai 50%. Thay bong: quay trai/phai tai cho de dua tam bong vao vung 85-95 do, dung yen ~2 s roi moi tien toi va hut; mat bong van hut them ~1 s roi moi tim lai.</p>
  <div class="frame"><img src="stream.mjpg" width="640" height="480" alt="Camera AI"></div>
  <div class="stats">
    <span class="stat">Pickleball <b id="stat-ball">0</b></span>
    <span class="stat">FPS <b id="stat-fps">0</b></span>
  </div>
</main>
<script>
const statBall = document.getElementById('stat-ball');
const statFps = document.getElementById('stat-fps');

async function updateStats() {
  try {
    const response = await fetch('/stats', {cache: 'no-store'});
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const stats = await response.json();
    statBall.textContent = Number(stats.pickleball) || 0;
    statFps.textContent = Number(stats.fps) || 0;
  } catch (error) {
    console.error(error);
  }
  window.setTimeout(updateStats, 500);
}

updateStats();
</script>
</body>
</html>
"""


class EspDriveLink:
    """Gui lenh lai xe sang ESP32 qua USB serial.

    ESP32 (CP2102) hien len /dev/ttyUSB0. Chi ghi, khong doc. Neu chua mo duoc
    cong (chua cam board, hoac dang bi serial monitor chiem) thi chi canh bao;
    phan camera va nhan dien bong van chay.
    """

    def __init__(self, port=SERIAL_PORT, baudrate=SERIAL_BAUDRATE):
        self.port = port
        self.baudrate = baudrate
        self._fd = None
        self._next_open_at = 0.0
        # The relay bootstrap thread and the camera thread both write to the
        # port during startup, so serialise access.
        self._lock = RLock()

    def _ensure_open(self):
        if self._fd is not None:
            return True
        now = time.monotonic()
        if now < self._next_open_at:
            return False
        self._next_open_at = now + SERIAL_RETRY_S
        try:
            fd = os.open(self.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError as exc:
            logging.warning('Khong mo duoc USB serial %s: %s', self.port, exc)
            return False

        # Open the tty directly with termios instead of pyserial: pyserial
        # asserts DTR/RTS on open, which toggles the ESP32 auto-reset circuit
        # and reboots the board (dropping the app's Bluetooth link). A plain
        # os.open leaves those modem lines alone.
        try:
            attrs = termios.tcgetattr(fd)
            attrs[0] = 0  # iflag: no CR/NL translation
            attrs[1] = 0  # oflag: raw output
            attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
            attrs[3] = 0  # lflag: no echo, no canonical mode
            speed = getattr(termios, f'B{self.baudrate}')
            attrs[4] = speed
            attrs[5] = speed
            attrs[6][termios.VMIN] = 0
            attrs[6][termios.VTIME] = 0
            attrs[2] &= ~termios.HUPCL  # do not drop DTR on close
            termios.tcsetattr(fd, termios.TCSANOW, attrs)
        except Exception as exc:
            logging.warning('Khong cau hinh duoc USB serial %s: %s', self.port, exc)
            os.close(fd)
            return False

        self._fd = fd
        logging.info('USB ESP32: %s @ %d (raw termios)', self.port, self.baudrate)
        return True

    def _drain(self):
        # The ESP32 logs over the same UART. Discard those bytes so the Pi's
        # tty buffer cannot fill up; nothing here needs the log text.
        if self._fd is None:
            return
        try:
            while os.read(self._fd, 4096):
                pass
        except BlockingIOError:
            pass
        except OSError as exc:
            logging.warning('Loi doc USB serial: %s', exc)
            self.close()

    def _write(self, line):
        with self._lock:
            if not self._ensure_open():
                return
            self._drain()
            try:
                os.write(self._fd, line.encode('ascii'))
            except Exception as exc:
                logging.warning('Loi ghi USB serial: %s', exc)
                self.close()

    def set_drive_speed(self, percent=SEARCH_SPEED):
        percent = max(0, min(100, int(percent)))
        self._write(f'r{percent}\n')

    def turn_right(self):
        self._write('R\n')

    def turn_left(self):
        self._write('L\n')

    def forward(self):
        self._write('F\n')

    def suction_on(self):
        self._write('G1\n')

    def suction_off(self):
        self._write('G0\n')

    def stop(self):
        self._write('S\n')

    def relay_on(self):
        self._write('Y1\n')

    def relay_off(self):
        self._write('Y0\n')

    def close(self):
        with self._lock:
            if self._fd is None:
                return
            try:
                os.close(self._fd)
            except Exception:
                pass
            self._fd = None


class StreamingOutput:
    """Latest JPEG plus the counts belonging to it."""

    def __init__(self):
        self.frame = None
        self.person_count = 0
        self.pickleball_count = 0
        self.fps = 0.0
        self.sequence = 0
        self.updated_at = 0.0
        self.condition = Condition()


output = StreamingOutput()


def draw_detection(frame, box, label, confidence, color):
    frame_height, frame_width = frame.shape[:2]
    x1, y1, x2, y2 = box
    x1 = max(0, min(int(x1), frame_width - 1))
    y1 = max(0, min(int(y1), frame_height - 1))
    x2 = max(0, min(int(x2), frame_width - 1))
    y2 = max(0, min(int(y2), frame_height - 1))
    if x2 <= x1 or y2 <= y1:
        return
    cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
    text = f'{label} {confidence:.1%}'
    font = cv2.FONT_HERSHEY_SIMPLEX
    font_scale = 0.55
    thickness = 2
    (text_width, text_height), baseline = cv2.getTextSize(
        text, font, font_scale, thickness
    )
    text_x = max(0, min(x1, frame_width - text_width - 8))
    text_y = max(text_height + 8, y1)
    cv2.rectangle(
        frame,
        (text_x, text_y - text_height - 6),
        (text_x + text_width + 8, text_y + baseline),
        color,
        -1,
    )
    cv2.putText(
        frame,
        text,
        (text_x + 4, text_y - 4),
        font,
        font_scale,
        (255, 255, 255),
        thickness,
        cv2.LINE_AA,
    )


def draw_stats(frame, fps):
    panel = frame.copy()
    cv2.rectangle(panel, (10, 10), (170, 50), (12, 22, 36), -1)
    cv2.addWeighted(panel, 0.78, frame, 0.22, 0, frame)
    font = cv2.FONT_HERSHEY_SIMPLEX
    cv2.putText(frame, f'FPS: {fps:.1f}', (24, 38), font, 0.58, (94, 231, 247), 2, cv2.LINE_AA)


def ball_angle_deg(centre_x, frame_width):
    """Map a pixel column to the on-screen 0..180 deg scale (90 = straight)."""
    if frame_width <= 0:
        return 90.0
    return max(0.0, min(180.0, centre_x / frame_width * 180.0))


def ball_in_center_band(angle):
    return BALL_ALIGN_MIN_DEG <= angle <= BALL_ALIGN_MAX_DEG


def draw_alignment_guide(frame, target_angle=None):
    """Draw the two guide bars that delimit the 85-95 deg centre band."""
    frame_height, frame_width = frame.shape[:2]
    x_min = int(round(frame_width * BALL_ALIGN_MIN_DEG / 180.0))
    x_max = int(round(frame_width * BALL_ALIGN_MAX_DEG / 180.0))
    x_min = max(0, min(x_min, frame_width - 1))
    x_max = max(0, min(x_max, frame_width - 1))
    aligned = target_angle is not None and ball_in_center_band(target_angle)
    color = (0, 255, 0) if aligned else (0, 0, 255)
    overlay = frame.copy()
    cv2.rectangle(overlay, (x_min, 0), (x_max, frame_height - 1), color, -1)
    cv2.addWeighted(overlay, 0.14, frame, 0.86, 0, frame)
    cv2.line(frame, (x_min, 0), (x_min, frame_height - 1), color, 2)
    cv2.line(frame, (x_max, 0), (x_max, frame_height - 1), color, 2)
    font = cv2.FONT_HERSHEY_SIMPLEX
    cv2.putText(frame, '85', (max(0, x_min - 26), 18), font, 0.45, color, 1, cv2.LINE_AA)
    cv2.putText(
        frame,
        '95',
        (min(frame_width - 18, x_max + 4), 18),
        font,
        0.45,
        color,
        1,
        cv2.LINE_AA,
    )


def draw_ball_center(frame, centre_x, centre_y, angle):
    """Mark the ball centre and print its angle on the guide scale."""
    frame_height, frame_width = frame.shape[:2]
    cx = max(0, min(int(round(centre_x)), frame_width - 1))
    cy = max(0, min(int(round(centre_y)), frame_height - 1))
    color = (0, 255, 0) if ball_in_center_band(angle) else (0, 0, 255)
    cv2.circle(frame, (cx, cy), 4, color, -1)
    cv2.line(frame, (cx - 12, cy), (cx + 12, cy), color, 1)
    cv2.line(frame, (cx, cy - 12), (cx, cy + 12), color, 1)
    text = f'{angle:.0f} deg'
    font = cv2.FONT_HERSHEY_SIMPLEX
    (text_width, _), _ = cv2.getTextSize(text, font, 0.45, 1)
    text_x = cx + 14
    if text_x + text_width >= frame_width:
        text_x = cx - 14 - text_width
    cv2.putText(
        frame,
        text,
        (max(0, text_x), max(14, cy - 10)),
        font,
        0.45,
        color,
        1,
        cv2.LINE_AA,
    )


class NCNNPickleballDetector:
    def __init__(self, param_path, bin_path):
        for path in (param_path, bin_path):
            if not os.path.isfile(path):
                raise FileNotFoundError(path)
        self.net = ncnn.Net()
        if self.net.load_param(param_path) != 0:
            raise RuntimeError(f'Khong tai duoc file NCNN: {param_path}')
        if self.net.load_model(bin_path) != 0:
            raise RuntimeError(f'Khong tai duoc file NCNN: {bin_path}')

    @staticmethod
    def _prepare_frame(frame):
        frame_height, frame_width = frame.shape[:2]
        scale = min(PICKLEBALL_INPUT_SIZE / frame_width, PICKLEBALL_INPUT_SIZE / frame_height)
        resized_width = max(1, int(round(frame_width * scale)))
        resized_height = max(1, int(round(frame_height * scale)))
        resized = cv2.resize(
            frame,
            (resized_width, resized_height),
            interpolation=cv2.INTER_LINEAR,
        )
        canvas = np.full(
            (PICKLEBALL_INPUT_SIZE, PICKLEBALL_INPUT_SIZE, 3),
            114,
            dtype=np.uint8,
        )
        pad_x = (PICKLEBALL_INPUT_SIZE - resized_width) // 2
        pad_y = (PICKLEBALL_INPUT_SIZE - resized_height) // 2
        canvas[pad_y:pad_y + resized_height, pad_x:pad_x + resized_width] = resized
        rgb = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB)
        chw = np.ascontiguousarray(rgb.transpose(2, 0, 1)).astype(np.float32) / 255.0
        return chw, scale, pad_x, pad_y

    def detect(self, frame):
        input_data, scale, pad_x, pad_y = self._prepare_frame(frame)
        try:
            with self.net.create_extractor() as extractor:
                extractor.input('in0', ncnn.Mat(input_data).clone())
                _, output_data = extractor.extract('out0')
            output_data = np.array(output_data, copy=True)
        except Exception as exc:
            raise RuntimeError('Khong chay duoc inference NCNN') from exc

        if output_data.ndim == 3 and output_data.shape[0] == 1:
            output_data = output_data[0]
        if output_data.ndim != 2:
            raise RuntimeError(f'Dinh dang output NCNN khong mong doi: {output_data.shape}')
        if output_data.shape[0] == 5:
            predictions = output_data.T
        elif output_data.shape[1] == 5:
            predictions = output_data
        else:
            raise RuntimeError(f'Output NCNN khong co 5 kenh: {output_data.shape}')

        frame_height, frame_width = frame.shape[:2]
        boxes = []
        scores = []
        for prediction in predictions:
            if len(prediction) < 5:
                continue
            score = float(prediction[4])
            if not np.isfinite(score) or score < PICKLEBALL_THRESHOLD:
                continue
            center_x, center_y, width, height = map(float, prediction[:4])
            if not np.isfinite([center_x, center_y, width, height]).all():
                continue
            x1 = (center_x - width / 2 - pad_x) / scale
            y1 = (center_y - height / 2 - pad_y) / scale
            x2 = (center_x + width / 2 - pad_x) / scale
            y2 = (center_y + height / 2 - pad_y) / scale
            x1 = max(0, min(int(round(x1)), frame_width - 1))
            y1 = max(0, min(int(round(y1)), frame_height - 1))
            x2 = max(0, min(int(round(x2)), frame_width - 1))
            y2 = max(0, min(int(round(y2)), frame_height - 1))
            if x2 <= x1 or y2 <= y1:
                continue
            boxes.append([x1, y1, x2 - x1, y2 - y1])
            scores.append(score)

        if not boxes:
            return []
        indices = cv2.dnn.NMSBoxes(
            boxes,
            scores,
            PICKLEBALL_THRESHOLD,
            PICKLEBALL_NMS_THRESHOLD,
        )
        indices = np.asarray(indices).reshape(-1)
        detections = []
        for index in indices:
            index = int(index)
            x, y, width, height = boxes[index]
            detections.append((x, y, x + width, y + height, scores[index]))
        return detections


def camera_worker(pickleball_detector, drive_link, relay_bootstrap_stop=None):
    imx500 = IMX500(MODEL_PATH)
    picam2 = Picamera2(imx500.camera_num)
    config = picam2.create_video_configuration(
        main={'size': CAM_SIZE, 'format': 'RGB888'},
        buffer_count=12,
    )
    try:
        imx500.show_network_fw_progress_bar()
    except Exception:
        pass
    picam2.start(config)
    logging.info(
        'Camera san sang - NCNN pickleball: ON, USB ESP32: %s', drive_link.port
    )

    fps = 0.0
    frame_count = 0
    fps_start_time = time.monotonic()

    last_ball_at = time.monotonic()
    drive_mode = None
    align_hold_since = 0.0
    last_command_at = 0.0
    last_speed_at = 0.0
    last_brush_at = 0.0
    suck_until = 0.0
    last_relay_at = 0.0
    first_frame = True

    def send_mode_command(mode):
        if mode in ('search', 'align_right'):
            drive_link.turn_right()
        elif mode == 'align_left':
            drive_link.turn_left()
        elif mode == 'hold_center':
            drive_link.stop()
        elif mode == 'approach':
            drive_link.forward()

    while True:
        request = None
        try:
            request = picam2.capture_request()
            frame = request.make_array('main')
            if CAMERA_ROTATE_180:
                frame = cv2.rotate(frame, cv2.ROTATE_180)

            try:
                detections = pickleball_detector.detect(frame)
            except Exception as exc:
                logging.warning('Loi nhan dien pickleball NCNN: %s', exc)
                detections = []

            frame_width = frame.shape[1]
            ball_angle = None
            if detections:
                best = max(detections, key=lambda detection: detection[4])
                best_centre_x = (best[0] + best[2]) / 2.0
                ball_angle = ball_angle_deg(best_centre_x, frame_width)

            # The two bars are the 85/95 deg limits of the centre band; the
            # ball's centre is marked so the alignment can be checked visually.
            draw_alignment_guide(frame, ball_angle)
            for x1, y1, x2, y2, confidence in detections:
                draw_detection(
                    frame,
                    (x1, y1, x2, y2),
                    PICKLEBALL_LABEL,
                    confidence,
                    (0, 255, 255),
                )
                centre_x = (x1 + x2) / 2.0
                centre_y = (y1 + y2) / 2.0
                draw_ball_center(
                    frame,
                    centre_x,
                    centre_y,
                    ball_angle_deg(centre_x, frame_width),
                )

            # Keep the firmware's 600 ms watchdog fed. While aligning, only
            # turn commands are sent; once the ball is inside the 85-95 deg
            # band the robot stands still for CENTER_HOLD_S before approaching.
            now = time.monotonic()
            if now - last_relay_at >= RELAY_KEEPALIVE_S:
                drive_link.relay_on()
                last_relay_at = now
            if first_frame:
                first_frame = False
                if relay_bootstrap_stop is not None:
                    relay_bootstrap_stop.set()

            ball_visible = bool(detections)
            if ball_visible:
                last_ball_at = now
                if drive_mode == 'suck_only' and now < suck_until:
                    requested_mode = 'suck_only'
                elif ball_angle < BALL_ALIGN_MIN_DEG:
                    requested_mode = 'align_left'
                elif ball_angle > BALL_ALIGN_MAX_DEG:
                    requested_mode = 'align_right'
                elif drive_mode == 'approach':
                    requested_mode = 'approach'
                elif drive_mode == 'hold_center':
                    if now - align_hold_since >= CENTER_HOLD_S:
                        requested_mode = 'approach'
                    else:
                        requested_mode = 'hold_center'
                else:
                    requested_mode = 'hold_center'
            elif now - last_ball_at < BALL_LOST_GRACE_S:
                requested_mode = drive_mode
            elif drive_mode == 'suck_only' and now < suck_until:
                requested_mode = 'suck_only'
            elif drive_mode == 'approach':
                requested_mode = 'suck_only'
            else:
                requested_mode = 'search'

            if requested_mode != drive_mode:
                drive_mode = requested_mode
                if drive_mode is None:
                    drive_link.suction_off()
                    drive_link.stop()
                    logging.info('Mat bong - dung xe')
                elif drive_mode == 'search':
                    drive_link.suction_off()
                    drive_link.set_drive_speed(SEARCH_SPEED)
                    drive_link.turn_right()
                    logging.info('Khong thay bong - quay phai %d%%', SEARCH_SPEED)
                elif drive_mode == 'align_left':
                    drive_link.suction_off()
                    drive_link.set_drive_speed(TRACK_TURN_SPEED)
                    drive_link.turn_left()
                    logging.info(
                        'Bong lech trai %.0f do (can 85-95) - quay trai %d%%',
                        ball_angle,
                        TRACK_TURN_SPEED,
                    )
                elif drive_mode == 'align_right':
                    drive_link.suction_off()
                    drive_link.set_drive_speed(TRACK_TURN_SPEED)
                    drive_link.turn_right()
                    logging.info(
                        'Bong lech phai %.0f do (can 85-95) - quay phai %d%%',
                        ball_angle,
                        TRACK_TURN_SPEED,
                    )
                elif drive_mode == 'hold_center':
                    drive_link.suction_off()
                    drive_link.stop()
                    align_hold_since = now
                    logging.info(
                        'Bong trong vung 85-95 do (%.0f do) - dung yen giu tam %.1f s',
                        ball_angle,
                        CENTER_HOLD_S,
                    )
                elif drive_mode == 'suck_only':
                    drive_link.stop()
                    drive_link.suction_on()
                    suck_until = now + SUCTION_AFTER_LOSS_S
                    last_brush_at = now
                    logging.info('Mat bong - van hut them %.1f s', SUCTION_AFTER_LOSS_S)
                else:
                    drive_link.suction_on()
                    drive_link.set_drive_speed(APPROACH_SPEED)
                    drive_link.forward()
                    last_brush_at = now
                    logging.info(
                        'Bong trong vung 85-95 do (%.0f do) - tien toi %d%% va bat hut',
                        ball_angle,
                        APPROACH_SPEED,
                    )
                last_command_at = now
                last_speed_at = now
            elif drive_mode is not None:
                if now - last_command_at >= DRIVE_KEEPALIVE_S:
                    send_mode_command(drive_mode)
                    last_command_at = now
                if now - last_speed_at >= SPEED_REFRESH_S:
                    if drive_mode == 'search':
                        speed = SEARCH_SPEED
                    elif drive_mode in ('align_left', 'align_right'):
                        speed = TRACK_TURN_SPEED
                    elif drive_mode == 'approach':
                        speed = APPROACH_SPEED
                    else:
                        speed = None
                    if speed is not None:
                        drive_link.set_drive_speed(speed)
                    last_speed_at = now
                if drive_mode in ('approach', 'suck_only') and now - last_brush_at >= BRUSH_KEEPALIVE_S:
                    drive_link.suction_on()
                    if drive_mode == 'approach':
                        drive_link.forward()
                        last_command_at = now
                    last_brush_at = now

            frame_count += 1
            elapsed = now - fps_start_time
            if elapsed >= 1.0:
                fps = frame_count / elapsed
                frame_count = 0
                fps_start_time = now

            draw_stats(frame, fps)
            if drive_mode == 'hold_center':
                hold_left = max(0.0, CENTER_HOLD_S - (now - align_hold_since))
                cv2.putText(
                    frame,
                    f'HOLD {hold_left:.1f}s',
                    (24, 80),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.6,
                    (0, 255, 0),
                    2,
                    cv2.LINE_AA,
                )

            ok, jpeg = cv2.imencode(
                '.jpg',
                frame,
                [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY],
            )
            if ok:
                with output.condition:
                    output.frame = jpeg.tobytes()
                    output.person_count = 0
                    output.pickleball_count = len(detections)
                    output.fps = fps
                    output.sequence += 1
                    output.updated_at = time.time()
                    output.condition.notify_all()
        except Exception as exc:
            logging.warning('Loi xu ly camera: %s', exc)
            time.sleep(1)
        finally:
            if request is not None:
                request.release()


class StreamingHandler(server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            content = PAGE.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        elif self.path == '/stream.mjpg':
            self.send_response(200)
            self.send_header('Age', '0')
            self.send_header('Cache-Control', 'no-cache, private')
            self.send_header('Pragma', 'no-cache')
            self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=FRAME')
            self.end_headers()
            last_sequence = -1
            try:
                while True:
                    with output.condition:
                        while output.sequence == last_sequence:
                            if not output.condition.wait(timeout=STREAM_STALL_TIMEOUT_S):
                                raise TimeoutError(
                                    'camera khong tao khung moi trong %.0fs'
                                    % STREAM_STALL_TIMEOUT_S
                                )
                        last_sequence = output.sequence
                        frame = output.frame
                    if frame is None:
                        continue
                    self.wfile.write(b'--FRAME\r\n')
                    self.send_header('Content-Type', 'image/jpeg')
                    self.send_header('Content-Length', str(len(frame)))
                    self.end_headers()
                    self.wfile.write(frame)
                    self.wfile.write(b'\r\n')
            except TimeoutError as exc:
                logging.warning('Dong stream camera: %s', exc)
            except Exception as exc:
                logging.warning('Client camera ngat: %s', exc)
        elif self.path == '/stats':
            with output.condition:
                data = json.dumps(
                    {
                        'person': output.person_count,
                        'pickleball': output.pickleball_count,
                        'fps': round(output.fps, 1),
                        'sequence': output.sequence,
                        'frameAge': (
                            round(time.time() - output.updated_at, 2)
                            if output.updated_at
                            else None
                        ),
                    }
                ).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_error(404)
            self.end_headers()


class StreamingServer(socketserver.ThreadingMixIn, server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def relay_bootstrap(drive_link, stop_event):
    # The IMX500 firmware upload takes a few seconds before the camera loop can
    # send its own keep-alive, so hold the relay closed during startup too.
    deadline = time.monotonic() + 15.0
    while not stop_event.is_set() and time.monotonic() < deadline:
        drive_link.relay_on()
        stop_event.wait(RELAY_KEEPALIVE_S)


if __name__ == '__main__':
    logging.info('Dang tai model pickleball NCNN tu %s', NCNN_BIN_PATH)
    pickleball_detector = NCNNPickleballDetector(NCNN_PARAM_PATH, NCNN_BIN_PATH)
    logging.info('Da tai xong model pickleball NCNN')

    drive_link = EspDriveLink()
    drive_link.stop()
    drive_link.relay_on()

    relay_bootstrap_stop = Event()
    relay_bootstrap_thread = Thread(
        target=relay_bootstrap,
        args=(drive_link, relay_bootstrap_stop),
        daemon=True,
    )
    relay_bootstrap_thread.start()

    camera_thread = Thread(
        target=camera_worker,
        args=(pickleball_detector, drive_link, relay_bootstrap_stop),
        daemon=True,
    )
    camera_thread.start()

    try:
        srv = StreamingServer(('', HTTP_PORT), StreamingHandler)
        print(f'Server dang chay -> http://<IP_CUA_PI>:{HTTP_PORT}')
        srv.serve_forever()
    except KeyboardInterrupt:
        print('Dang dung server...')
    finally:
        relay_bootstrap_stop.set()
        relay_bootstrap_thread.join(timeout=1.0)
        drive_link.stop()
        drive_link.relay_off()
        drive_link.close()
