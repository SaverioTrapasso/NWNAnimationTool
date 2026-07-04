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

def run(video_path: str, sample_fps: float = 10.0, smooth_window: int = 3) -> dict:
    import cv2

    try:
        import mediapipe as mp
        from mediapipe.tasks import python as mp_python
        from mediapipe.tasks.python import vision as mp_vision
    except ImportError:
        return {"error": "mediapipe not installed. Run ai_pose/install.bat"}

    model_path = os.path.join(os.path.dirname(__file__), "pose_landmarker.task")
    if not os.path.exists(model_path):
        import urllib.request
        url = "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/latest/pose_landmarker_lite.task"
        urllib.request.urlretrieve(url, model_path)

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        return {"error": "Could not open video: %s" % video_path}

    video_fps   = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    duration    = total_frames / video_fps

    # How many source frames to skip between each sample
    frame_step = max(1, int(round(video_fps / sample_fps)))

    base_opts = mp_python.BaseOptions(model_asset_path=model_path)
    opts = mp_vision.PoseLandmarkerOptions(
        base_options=base_opts,
        output_segmentation_masks=False,
        num_poses=1,
    )
    detector = mp_vision.PoseLandmarker.create_from_options(opts)

    raw_frames = []   # list of (time, landmarks_list) — only detected frames
    frame_idx  = 0

    while True:
        ret, frame_bgr = cap.read()
        if not ret:
            break

        if frame_idx % frame_step == 0:
            timestamp_sec = frame_idx / video_fps
            rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            result = detector.detect(mp_image)

            if result.pose_world_landmarks:
                lms = result.pose_world_landmarks[0]
                landmarks = [
                    {"x": lm.x, "y": lm.y, "z": lm.z, "visibility": lm.visibility}
                    for lm in lms
                ]
                raw_frames.append((timestamp_sec, landmarks))

        frame_idx += 1

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

    result = run(video_path, sample_fps, smooth_window)
    print(json.dumps(result))
