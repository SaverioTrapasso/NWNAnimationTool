"""
Extract per-frame pose landmarks from a video file using MediaPipe.

Usage:
    python extract_video_poses.py <video_path> [sample_fps] [smooth_window]

Output (stdout): JSON
    {
        "duration": <float seconds>,
        "sample_fps": <float>,
        "frames": [
            {"time": <float>, "world_landmarks": [{x,y,z,visibility}, ...]},
            ...
        ]
    }

Only frames where a pose is detected are included.
"""

import sys
import os
import json
import math


class GifCapture:
    """Decode composited GIF frames while retaining per-frame timing."""
    def __init__(self, path):
        from PIL import Image
        self.image = Image.open(path)
        self.index = 0
        self.timestamp = 0.0
        self.elapsed = 0.0
        self.durations = []
        for i in range(self.image.n_frames):
            self.image.seek(i)
            self.durations.append(max(10, self.image.info.get("duration", 100)))
        self.duration = sum(self.durations) / 1000.0
    def isOpened(self): return True
    def read(self):
        import numpy as np
        if self.index >= len(self.durations): return False, None
        self.image.seek(self.index)
        self.timestamp = self.elapsed
        self.elapsed += self.durations[self.index] / 1000.0
        self.index += 1
        return True, np.asarray(self.image.convert("RGB"))[:, :, ::-1].copy()
    def release(self): self.image.close()

def run(video_path: str, sample_fps: float = 10.0, smooth_window: int = 3) -> dict:
    if not math.isfinite(sample_fps) or sample_fps <= 0:
        return {"error": "Sample FPS must be a positive finite number"}
    if not os.path.isfile(video_path):
        return {"error": "Video file does not exist: " + video_path}
    import cv2

    try:
        import mediapipe as mp
        from mediapipe.tasks import python as mp_python
        from mediapipe.tasks.python import vision as mp_vision
    except ImportError:
        return {"error": "mediapipe not installed. Run: pip install mediapipe opencv-python"}

    model_path = os.environ.get("NWN_POSE_MODEL", os.path.join(os.path.dirname(__file__), "pose_landmarker_full.task"))
    if not os.path.exists(model_path):
        import urllib.request
        url = "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task"
        urllib.request.urlretrieve(url, model_path)

    is_gif = video_path.lower().endswith(".gif")
    cap = GifCapture(video_path) if is_gif else cv2.VideoCapture(video_path)
    if not cap.isOpened():
        return {"error": "Could not open video: %s" % video_path}

    video_fps = sample_fps if is_gif else (cap.get(cv2.CAP_PROP_FPS) or 30.0)
    total_frames = len(cap.durations) if is_gif else int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    duration = cap.duration if is_gif else total_frames / video_fps

    # How many source frames to skip between each sample
    frame_step = max(1, int(round(video_fps / sample_fps)))

    base_opts = mp_python.BaseOptions(model_asset_path=model_path)
    opts = mp_vision.PoseLandmarkerOptions(
        base_options=base_opts,
        output_segmentation_masks=False,
        running_mode=mp_vision.RunningMode.VIDEO,
        num_poses=1,
    )
    detector = mp_vision.PoseLandmarker.create_from_options(opts)

    raw_frames = []   # list of (time, landmarks_list) — only detected frames
    frame_idx  = 0
    next_sample = 0.0

    try:
        while True:
            ret, frame_bgr = cap.read()
            if not ret:
                break

            timestamp_sec = cap.timestamp if is_gif else frame_idx / video_fps
            should_sample = timestamp_sec + 1e-8 >= next_sample if is_gif else frame_idx % frame_step == 0
            if should_sample:
                next_sample = timestamp_sec + 1.0 / sample_fps
                rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
                mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
                result = detector.detect_for_video(mp_image, round(timestamp_sec * 1000))

                if result.pose_world_landmarks:
                    lms = result.pose_world_landmarks[0]
                    landmarks = [
                        {"x": lm.x, "y": lm.y, "z": lm.z, "visibility": lm.visibility}
                        for lm in lms
                    ]
                    raw_frames.append((timestamp_sec, landmarks))

            frame_idx += 1

    finally:
        cap.release()
        detector.close()

    if not raw_frames:
        return {"error": "No pose detected in any frame"}

    # Temporal smoothing: moving average over landmark positions.
    # Window is applied per landmark per axis independently.
    smooth_window = max(1, smooth_window)
    smoothed = []
    n = len(raw_frames)

    for i, (t, lms) in enumerate(raw_frames):
        half = smooth_window // 2
        lo = max(0, i - half)
        hi = min(n, i + half + 1)
        count = hi - lo

        avg_lms = []
        for lm_idx in range(len(lms)):
            ax = sum(raw_frames[j][1][lm_idx]["x"] for j in range(lo, hi)) / count
            ay = sum(raw_frames[j][1][lm_idx]["y"] for j in range(lo, hi)) / count
            az = sum(raw_frames[j][1][lm_idx]["z"] for j in range(lo, hi)) / count
            av = sum(raw_frames[j][1][lm_idx]["visibility"] for j in range(lo, hi)) / count
            avg_lms.append({"x": ax, "y": ay, "z": az, "visibility": av})

        smoothed.append({"time": round(t, 4), "world_landmarks": avg_lms})

    return {
        "duration": round(duration, 4),
        "sample_fps": sample_fps,
        "frames": smoothed,
    }


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: extract_video_poses.py <video> [fps] [smooth]"}))
        sys.exit(1)

    video_path   = sys.argv[1]
    sample_fps   = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
    smooth_window = int(sys.argv[3])  if len(sys.argv) > 3 else 3

    try:
        result = run(video_path, sample_fps, smooth_window)
    except Exception as exc:
        result = {"error": str(exc)}
    print(json.dumps(result))
