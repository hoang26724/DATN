#!/usr/bin/env python3
"""
Camera AI IMX500 + Pickleball NCNN + RPLIDAR web viewer cho Raspberry Pi.
Chay: python3 pickleball.py
Xem: http://<IP_CUA_PI>:8000/
"""

import json
import logging
import os
import socketserver
import time
from http import server
from threading import Condition, Lock, Thread

import cv2
import numpy as np
from picamera2 import Picamera2
from picamera2.devices.imx500 import IMX500
from rplidar import RPLidar

try:
    import ncnn
except ImportError as exc:
    raise ImportError("Can cai dat goi ncnn de chay model pickleball") from exc


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LIDAR_PORT = '/dev/ttyUSB0'
LIDAR_BAUDRATE = 115200
CAM_SIZE = (640, 480)
MAX_DIST_MM = 6000
MAX_DIST_M = MAX_DIST_MM / 1000
HTTP_PORT = 8000
JPEG_QUALITY = 80

MODEL_PATH = '/usr/share/imx500-models/imx500_network_ssd_mobilenetv2_fpnlite_320x320_pp.rpk'
OBJ_THRESHOLD = 0.55
PERSON_LABEL_NAME = 'person'
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
<title>Pi Vision - Camera AI, Pickleball va LIDAR</title>
<style>
:root {
  color-scheme: dark;
  --bg: #07111f;
  --panel: rgba(14, 29, 48, 0.88);
  --panel-strong: #10243a;
  --border: rgba(148, 183, 216, 0.18);
  --text: #edf6ff;
  --muted: #9eb3c9;
  --cyan: #5ee7f7;
  --green: #35d07f;
  --yellow: #ffd34e;
  --red: #ff6b6b;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  min-height: 100vh;
  color: var(--text);
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background:
    radial-gradient(circle at 10% 0%, rgba(37, 119, 170, 0.28), transparent 34rem),
    radial-gradient(circle at 100% 20%, rgba(30, 181, 145, 0.14), transparent 28rem),
    linear-gradient(135deg, #07111f 0%, #0b1829 52%, #081321 100%);
}
body::before {
  content: "";
  position: fixed;
  inset: 0;
  pointer-events: none;
  opacity: 0.12;
  background-image: linear-gradient(rgba(255,255,255,.08) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,.08) 1px, transparent 1px);
  background-size: 32px 32px;
  mask-image: linear-gradient(to bottom, black, transparent 75%);
}
.app { position: relative; width: min(1280px, calc(100% - 32px)); margin: 0 auto; padding: 30px 0 42px; }
.topbar { display: flex; align-items: flex-end; justify-content: space-between; gap: 24px; margin-bottom: 24px; }
.eyebrow { color: var(--cyan); font-size: 12px; font-weight: 700; letter-spacing: .18em; text-transform: uppercase; }
h1 { margin: 6px 0 0; font-size: clamp(26px, 4vw, 42px); letter-spacing: -.04em; }
.subtitle { margin: 8px 0 0; color: var(--muted); font-size: 14px; }
.badges { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 8px; }
.badge { display: inline-flex; align-items: center; gap: 7px; padding: 8px 11px; border: 1px solid var(--border); border-radius: 999px; background: rgba(12, 28, 46, .72); color: #cfe6fa; font-size: 11px; font-weight: 700; letter-spacing: .08em; }
.badge::before { content: ""; width: 7px; height: 7px; border-radius: 50%; background: var(--green); box-shadow: 0 0 12px var(--green); }
.dashboard { display: grid; grid-template-columns: minmax(0, 1.35fr) minmax(340px, .9fr); gap: 20px; align-items: start; }
.panel { border: 1px solid var(--border); border-radius: 22px; background: var(--panel); box-shadow: 0 24px 70px rgba(0,0,0,.28); backdrop-filter: blur(18px); overflow: hidden; }
.panel-head { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 17px 20px; border-bottom: 1px solid var(--border); }
.panel-title { display: flex; align-items: center; gap: 10px; font-weight: 750; }
.panel-title span:first-child { display: grid; place-items: center; width: 30px; height: 30px; border-radius: 10px; color: #06131f; background: linear-gradient(135deg, var(--cyan), #8bf4d0); font-size: 15px; }
.panel-title small { display: block; margin-top: 2px; color: var(--muted); font-size: 11px; font-weight: 500; }
.live { color: var(--green); font-size: 10px; font-weight: 800; letter-spacing: .14em; }
.camera-body { padding: 16px; }
.camera-frame { position: relative; overflow: hidden; border: 1px solid rgba(255,255,255,.09); border-radius: 16px; background: #03070d; box-shadow: inset 0 0 0 1px rgba(0,0,0,.4); }
.camera-frame img { display: block; width: 100%; height: auto; aspect-ratio: 4 / 3; object-fit: contain; }
.camera-frame::after { content: "LIVE"; position: absolute; top: 12px; right: 12px; padding: 5px 8px; border: 1px solid rgba(255,255,255,.18); border-radius: 7px; color: #fff; background: rgba(0,0,0,.45); font-size: 10px; font-weight: 800; letter-spacing: .12em; }
.legend { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 14px; }
.legend span { display: inline-flex; align-items: center; gap: 7px; padding: 7px 10px; border: 1px solid var(--border); border-radius: 9px; color: #c8d8e8; background: rgba(255,255,255,.035); font-size: 12px; }
.legend i { width: 8px; height: 8px; border-radius: 50%; }
.legend .person i { background: var(--red); box-shadow: 0 0 9px rgba(255,107,107,.8); }
.legend .ball i { background: var(--yellow); box-shadow: 0 0 9px rgba(255,211,78,.8); }
.lidar-body { padding: 16px 18px 20px; }
.range-row { display: flex; justify-content: space-between; align-items: center; gap: 14px; margin-bottom: 12px; color: var(--muted); font-size: 12px; }
.range-row strong { color: var(--text); font-size: 15px; }
#observed-range { color: var(--cyan); font-weight: 700; }
.radar-wrap { position: relative; overflow: hidden; border: 1px solid rgba(94,231,247,.13); border-radius: 18px; background: radial-gradient(circle, rgba(22, 62, 87, .8), rgba(4, 13, 23, .95) 70%); }
#radar { display: block; width: 100%; height: auto; aspect-ratio: 1; }
.distance-scale { margin-top: 16px; }
.distance-bar { height: 8px; border-radius: 99px; background: linear-gradient(90deg, #2bd576 0%, #ffd400 50%, #ef4444 100%); box-shadow: 0 0 18px rgba(255,212,0,.18); }
.distance-labels { display: flex; justify-content: space-between; margin-top: 7px; color: var(--muted); font-size: 11px; }
.footer-note { margin-top: 18px; color: var(--muted); font-size: 12px; text-align: center; }
@media (max-width: 900px) {
  .topbar { align-items: flex-start; flex-direction: column; }
  .badges { justify-content: flex-start; }
  .dashboard { grid-template-columns: 1fr; }
}
@media (max-width: 520px) {
  .app { width: min(100% - 20px, 1280px); padding-top: 20px; }
  .panel { border-radius: 16px; }
  .panel-head { padding: 14px 15px; }
  .camera-body, .lidar-body { padding: 10px; }
  .range-row { align-items: flex-start; flex-direction: column; gap: 4px; }
}
</style>
</head>
<body>
<main class="app">
  <header class="topbar">
    <div>
      <div class="eyebrow">Raspberry Pi Vision</div>
      <h1>Camera AI &amp; LIDAR</h1>
      <p class="subtitle">Theo doi nguoi va bong pickleball theo thoi gian thuc.</p>
    </div>
    <div class="badges">
      <span class="badge">IMX500</span>
      <span class="badge">NCNN</span>
      <span class="badge">LIDAR</span>
    </div>
  </header>
  <section class="dashboard">
    <article class="panel">
      <div class="panel-head">
        <div class="panel-title"><span>◉</span><div>Camera AI<small>Nhan dien ngay tren Raspberry Pi</small></div></div>
        <div class="live">STREAMING</div>
      </div>
      <div class="camera-body">
        <div class="camera-frame"><img src="stream.mjpg" width="640" height="480" alt="Camera AI stream"></div>
        <div class="legend">
          <span class="person"><i></i>Nguoi</span>
          <span class="ball"><i></i>Pickleball</span>
        </div>
      </div>
    </article>
    <article class="panel">
      <div class="panel-head">
        <div class="panel-title"><span>⌁</span><div>Radar LIDAR<small>Mau theo khoang cach do</small></div></div>
        <div class="live">SCANNING</div>
      </div>
      <div class="lidar-body">
        <div class="range-row"><span>Quet toi daa <strong>__MAX_DIST_M__ m</strong></span><span id="observed-range">Diem xa nhat: 0.0 m</span></div>
        <div class="radar-wrap"><canvas id="radar" width="560" height="560"></canvas></div>
        <div class="distance-scale"><div class="distance-bar"></div><div class="distance-labels"><span>Gan: 0 m</span><span>Vua: __HALF_DIST_M__ m</span><span>Xa: __MAX_DIST_M__ m</span></div></div>
      </div>
    </article>
  </section>
  <p class="footer-note">Cac diem LIDAR cang xa se chuyen dan tu xanh sang vang va do.</p>
</main>
<script>
const canvas = document.getElementById('radar');
const ctx = canvas.getContext('2d');
const CX = 280;
const CY = 280;
const MAXR = 240;
const MAXDIST = __MAX_DIST_MM__;
const observedRange = document.getElementById('observed-range');

function mixColor(first, second, amount) {
  return `rgb(${Math.round(first[0] + (second[0] - first[0]) * amount)}, ${Math.round(first[1] + (second[1] - first[1]) * amount)}, ${Math.round(first[2] + (second[2] - first[2]) * amount)})`;
}

function distanceColor(distance) {
  const ratio = Math.min(Math.max(distance / MAXDIST, 0), 1);
  if (ratio <= 0.5) {
    return mixColor([43, 213, 118], [255, 212, 0], ratio * 2);
  }
  return mixColor([255, 212, 0], [239, 68, 68], (ratio - 0.5) * 2);
}

function drawGrid() {
  ctx.clearRect(0, 0, 560, 560);
  ctx.fillStyle = 'rgba(4, 13, 23, 0.2)';
  ctx.fillRect(0, 0, 560, 560);
  ctx.lineWidth = 1;
  ctx.font = '12px system-ui, sans-serif';
  ctx.textAlign = 'left';
  for (let ring = 1; ring <= 4; ring += 1) {
    const radius = MAXR * ring / 4;
    ctx.beginPath();
    ctx.arc(CX, CY, radius, 0, Math.PI * 2);
    ctx.strokeStyle = ring === 4 ? 'rgba(94,231,247,0.28)' : 'rgba(158,179,201,0.18)';
    ctx.stroke();
    ctx.fillStyle = 'rgba(202,224,241,0.72)';
    ctx.fillText(`${(MAXDIST * ring / 4 / 1000).toFixed(1)} m`, CX + 7, CY - radius + 15);
  }
  ctx.beginPath();
  ctx.moveTo(CX - MAXR, CY);
  ctx.lineTo(CX + MAXR, CY);
  ctx.moveTo(CX, CY - MAXR);
  ctx.lineTo(CX, CY + MAXR);
  ctx.strokeStyle = 'rgba(158,179,201,0.2)';
  ctx.stroke();
  ctx.fillStyle = 'rgba(234,246,255,0.9)';
  ctx.font = 'bold 12px system-ui, sans-serif';
  ctx.fillText('0°', CX - 8, 16);
  ctx.textAlign = 'right';
  ctx.fillText('90°', 552, CY + 4);
  ctx.fillText('180°', CX + 8, 552);
  ctx.textAlign = 'left';
  ctx.fillText('270°', 8, CY + 4);
  ctx.textAlign = 'left';
}

async function updateLidar() {
  try {
    const response = await fetch('/lidar_data', {cache: 'no-store'});
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const points = await response.json();
    drawGrid();
    let maxObserved = 0;
    points.forEach(function (point) {
      if (!Array.isArray(point) || point.length < 3) {
        return;
      }
      const angle = Number(point[1]);
      const distance = Number(point[2]);
      if (!Number.isFinite(angle) || !Number.isFinite(distance) || distance <= 0 || distance > MAXDIST) {
        return;
      }
      maxObserved = Math.max(maxObserved, distance);
      const angleRad = angle * Math.PI / 180;
      const x = CX + distance / MAXDIST * MAXR * Math.sin(angleRad);
      const y = CY - distance / MAXDIST * MAXR * Math.cos(angleRad);
      const color = distanceColor(distance);
      ctx.beginPath();
      ctx.arc(x, y, 3.2, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.shadowColor = color;
      ctx.shadowBlur = 7;
      ctx.fill();
      ctx.shadowBlur = 0;
    });
    observedRange.textContent = `Diem xa nhat: ${(maxObserved / 1000).toFixed(1)} m`;
  } catch (error) {
    drawGrid();
    observedRange.textContent = 'LIDAR: dang cho du lieu';
    console.error(error);
  }
  window.setTimeout(updateLidar, 200);
}

drawGrid();
updateLidar();
</script>
</body>
</html>
""".replace('__MAX_DIST_MM__', str(MAX_DIST_MM)).replace(
    '__MAX_DIST_M__', f'{MAX_DIST_M:.1f}'
).replace('__HALF_DIST_M__', f'{MAX_DIST_M / 2:.1f}')


class StreamingOutput:
    def __init__(self):
        self.frame = None
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


def draw_stats(frame, person_count, pickleball_count, fps):
    panel = frame.copy()
    cv2.rectangle(panel, (10, 10), (300, 96), (12, 22, 36), -1)
    cv2.addWeighted(panel, 0.78, frame, 0.22, 0, frame)
    font = cv2.FONT_HERSHEY_SIMPLEX
    cv2.putText(frame, f'Nguoi: {person_count}', (24, 35), font, 0.62, (255, 255, 255), 2, cv2.LINE_AA)
    cv2.putText(frame, f'Bong pickleball: {pickleball_count}', (24, 61), font, 0.62, (255, 255, 255), 2, cv2.LINE_AA)
    cv2.putText(frame, f'FPS: {fps:.1f}', (24, 87), font, 0.58, (94, 231, 247), 2, cv2.LINE_AA)


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


def camera_worker(pickleball_detector):
    imx500 = IMX500(MODEL_PATH)
    intrinsics = getattr(imx500, 'network_intrinsics', None)
    labels = getattr(intrinsics, 'labels', None) if intrinsics is not None else None

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

    label_count = len(labels) if labels is not None else 0
    logging.info('IMX500 labels (%d): %s', label_count, labels)
    if label_count == 0:
        logging.warning(
            'CANH BAO: khong doc duoc labels tu model imx500; '
            'chi hien thi nguoi khi ten nhan la "person".'
        )
    logging.info('Camera san sang - IMX500: ON, Pickleball NCNN: ON')

    last_debug_time = 0.0
    debug_log_interval = 2.0
    fps = 0.0
    frame_count = 0
    fps_start_time = time.time()

    while True:
        request = None
        try:
            request = picam2.capture_request()
            metadata = request.get_metadata()
            frame = request.make_array('main')
            person_count = 0
            pickleball_count = 0

            try:
                outputs = imx500.get_outputs(metadata)
            except Exception as exc:
                outputs = None
                logging.warning('imx500.get_outputs() bi loi: %s', exc)

            now = time.time()
            should_log_debug = now - last_debug_time > debug_log_interval
            if outputs is None:
                if should_log_debug:
                    last_debug_time = now
                    logging.info('DEBUG dinh ky: get_outputs()=None')
            else:
                try:
                    boxes, scores, classes = outputs[0], outputs[1], outputs[2]
                    scores_array = np.asarray(scores).reshape(-1)
                    if should_log_debug:
                        last_debug_time = now
                        count_total = len(scores_array)
                        count_above = int((scores_array >= OBJ_THRESHOLD).sum()) if count_total else 0
                        top_score = float(scores_array.max()) if count_total else 0.0
                        logging.info(
                            'DEBUG dinh ky: %d detection tho, diem cao nhat=%.3f, '
                            '%d/%d qua nguong %.2f',
                            count_total,
                            top_score,
                            count_above,
                            count_total,
                            OBJ_THRESHOLD,
                        )
                    for box, score_value, class_value in zip(boxes, scores, classes):
                        score = float(np.asarray(score_value).reshape(-1)[0])
                        if score < OBJ_THRESHOLD:
                            continue
                        class_index = int(np.asarray(class_value).reshape(-1)[0])
                        if isinstance(labels, dict):
                            name = str(labels.get(class_index, f'class{class_index}'))
                        elif labels is not None and class_index < len(labels):
                            name = str(labels[class_index])
                        else:
                            name = f'class{class_index}'
                        if name.strip().lower() != PERSON_LABEL_NAME:
                            continue

                        obj = imx500.convert_inference_coords(box, metadata, picam2)
                        if hasattr(obj, 'x'):
                            x, y, width, height = obj.x, obj.y, obj.width, obj.height
                        else:
                            x, y, width, height = obj
                        x, y, width, height = map(int, (x, y, width, height))
                        person_count += 1
                        draw_detection(
                            frame,
                            (x, y, x + width, y + height),
                            'Nguoi',
                            score,
                            (0, 0, 255),
                        )
                except Exception as exc:
                    if should_log_debug:
                        last_debug_time = now
                        logging.warning('Loi parse object detection: %s', exc)

            try:
                detections = pickleball_detector.detect(frame)
                for x1, y1, x2, y2, confidence in detections:
                    pickleball_count += 1
                    draw_detection(
                        frame,
                        (x1, y1, x2, y2),
                        PICKLEBALL_LABEL,
                        confidence,
                        (0, 255, 255),
                    )
            except Exception as exc:
                logging.warning('Loi nhan dien pickleball NCNN: %s', exc)

            frame_count += 1
            elapsed = time.time() - fps_start_time
            if elapsed >= 1.0:
                fps = frame_count / elapsed
                frame_count = 0
                fps_start_time = time.time()

            draw_stats(frame, person_count, pickleball_count, fps)

            ok, jpeg = cv2.imencode(
                '.jpg',
                frame,
                [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY],
            )
            if ok:
                with output.condition:
                    output.frame = jpeg.tobytes()
                    output.condition.notify_all()
        except Exception as exc:
            logging.warning('Loi xu ly camera: %s', exc)
            time.sleep(1)
        finally:
            if request is not None:
                request.release()


lidar_points = []
lidar_lock = Lock()


def lidar_worker():
    global lidar_points
    while True:
        lidar = None
        try:
            lidar = RPLidar(LIDAR_PORT, baudrate=LIDAR_BAUDRATE)
            time.sleep(0.5)
            lidar.clean_input()
            for scan in lidar.iter_scans():
                points = [[q, angle, dist] for q, angle, dist in scan]
                with lidar_lock:
                    lidar_points = points
        except Exception as exc:
            logging.warning('Loi LIDAR: %s - thu lai sau 5s', exc)
            time.sleep(5)
        finally:
            if lidar is not None:
                try:
                    lidar.stop()
                    lidar.stop_motor()
                    lidar.disconnect()
                except Exception:
                    pass


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
            try:
                while True:
                    with output.condition:
                        output.condition.wait()
                        frame = output.frame
                    if frame is None:
                        continue
                    self.wfile.write(b'--FRAME\r\n')
                    self.send_header('Content-Type', 'image/jpeg')
                    self.send_header('Content-Length', str(len(frame)))
                    self.end_headers()
                    self.wfile.write(frame)
                    self.wfile.write(b'\r\n')
            except Exception as exc:
                logging.warning('Client camera ngat: %s', exc)
        elif self.path == '/lidar_data':
            with lidar_lock:
                data = json.dumps(lidar_points).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_error(404)
            self.end_headers()


class StreamingServer(socketserver.ThreadingMixIn, server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == '__main__':
    logging.info('Dang tai model pickleball NCNN tu %s', NCNN_BIN_PATH)
    pickleball_detector = NCNNPickleballDetector(NCNN_PARAM_PATH, NCNN_BIN_PATH)
    logging.info('Da tai xong model pickleball NCNN')

    camera_thread = Thread(target=camera_worker, args=(pickleball_detector,), daemon=True)
    camera_thread.start()

    lidar_thread = Thread(target=lidar_worker, daemon=True)
    lidar_thread.start()

    try:
        srv = StreamingServer(('', HTTP_PORT), StreamingHandler)
        print(f'Server dang chay -> http://<IP_CUA_PI>:{HTTP_PORT}')
        srv.serve_forever()
    except KeyboardInterrupt:
        print('Dang dung server...')
