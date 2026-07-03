"""
NWN Animation Tool — AI Pose Server
Receives a PNG/JPG image via HTTP POST, runs MediaPipe Pose Landmarker,
and returns the 33 world-space 3D landmarks as JSON.

Usage:
    python pose_server.py

Then from Godot (or a browser): POST http://localhost:7842/pose
Body: raw image bytes (Content-Type: image/png or image/jpeg)
"""

import sys
import os
import io
import json
import struct
import base64
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 7842
MODEL_PATH = os.path.join(os.path.dirname(__file__), "pose_landmarker.task")
MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/"
    "pose_landmarker/pose_landmarker_lite/float16/latest/pose_landmarker_lite.task"
)

# ---------------------------------------------------------------------------
# Lazy-load mediapipe so the import error is readable
# ---------------------------------------------------------------------------
mp = None
landmarker = None


def _download_model():
    if os.path.exists(MODEL_PATH):
        return
    print(f"Downloading MediaPipe model to {MODEL_PATH} ...")
    urllib.request.urlretrieve(MODEL_URL, MODEL_PATH)
    print("Download complete.")


def _init_mediapipe():
    global mp, landmarker
    try:
        import mediapipe as _mp
        mp = _mp
    except ImportError:
        print("ERROR: mediapipe not installed. Run:  pip install mediapipe", file=sys.stderr)
        sys.exit(1)

    _download_model()

    BaseOptions = mp.tasks.BaseOptions
    PoseLandmarker = mp.tasks.vision.PoseLandmarker
    PoseLandmarkerOptions = mp.tasks.vision.PoseLandmarkerOptions
    VisionRunningMode = mp.tasks.vision.RunningMode

    options = PoseLandmarkerOptions(
        base_options=BaseOptions(model_asset_path=MODEL_PATH),
        running_mode=VisionRunningMode.IMAGE,
        output_segmentation_masks=False,
    )
    landmarker = PoseLandmarker.create_from_options(options)
    print(f"MediaPipe Pose Landmarker ready. Listening on http://localhost:{PORT}")


# ---------------------------------------------------------------------------
# Landmark index → human-readable name (MediaPipe 33-point convention)
# ---------------------------------------------------------------------------
LANDMARK_NAMES = [
    "nose", "left_eye_inner", "left_eye", "left_eye_outer",
    "right_eye_inner", "right_eye", "right_eye_outer",
    "left_ear", "right_ear",
    "mouth_left", "mouth_right",
    "left_shoulder", "right_shoulder",
    "left_elbow", "right_elbow",
    "left_wrist", "right_wrist",
    "left_pinky", "right_pinky",
    "left_index", "right_index",
    "left_thumb", "right_thumb",
    "left_hip", "right_hip",
    "left_knee", "right_knee",
    "left_ankle", "right_ankle",
    "left_heel", "right_heel",
    "left_foot_index", "right_foot_index",
]


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Suppress per-request noise; only print errors
        pass

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        else:
            self._respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/pose":
            self._respond(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self._respond(400, {"error": "empty body"})
            return

        image_bytes = self.rfile.read(length)
        try:
            result = _run_mediapipe(image_bytes)
            self._respond(200, result)
        except Exception as e:
            self._respond(500, {"error": str(e)})

    def _respond(self, code: int, data: dict):
        body = json.dumps(data).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)


def _run_mediapipe(image_bytes: bytes) -> dict:
    mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=_decode_image(image_bytes))
    result = landmarker.detect(mp_image)

    if not result.pose_landmarks:
        return {"landmarks": [], "world_landmarks": []}

    # Normalized image landmarks (2D, 0..1)
    lm2d = []
    for lm in result.pose_landmarks[0]:
        lm2d.append({"x": lm.x, "y": lm.y, "z": lm.z, "visibility": lm.visibility})

    # World landmarks (3D in metres, origin at hip centre)
    lm3d = []
    for i, lm in enumerate(result.pose_world_landmarks[0]):
        lm3d.append({
            "name": LANDMARK_NAMES[i] if i < len(LANDMARK_NAMES) else str(i),
            "x": lm.x,
            "y": lm.y,
            "z": lm.z,
            "visibility": lm.visibility,
        })

    return {"landmarks": lm2d, "world_landmarks": lm3d}


def _decode_image(data: bytes):
    """Decode PNG/JPG bytes to a numpy RGB array without PIL dependency."""
    try:
        import numpy as np
        import struct, zlib

        # Try numpy via mediapipe's own cv2 if available
        try:
            import cv2
            buf = np.frombuffer(data, dtype=np.uint8)
            img_bgr = cv2.imdecode(buf, cv2.IMREAD_COLOR)
            return cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
        except ImportError:
            pass

        # Fallback: PIL
        try:
            from PIL import Image
            import numpy as np
            img = Image.open(io.BytesIO(data)).convert("RGB")
            return np.array(img)
        except ImportError:
            pass

        raise RuntimeError(
            "No image decoder found. Install opencv-python or Pillow:\n"
            "  pip install opencv-python\n"
            "  # or\n"
            "  pip install Pillow"
        )
    except Exception as e:
        raise RuntimeError(f"Image decode failed: {e}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    _init_mediapipe()
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")
        landmarker.close()
