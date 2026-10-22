"""
NWN Animation Tool — AI Pose Detector
Called by Godot via OS.execute(). Reads an image file, runs MediaPipe
Pose Landmarker, and prints a single JSON object to stdout.

Usage:
    python detect_pose.py <image_path>

Output (stdout):
    {"world_landmarks": [...]}   on success
    {"error": "..."}             on failure
"""

import sys
import os
import json
import urllib.request

MODEL_PATH = os.environ.get("NWN_POSE_MODEL", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pose_landmarker_full.task"))
MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/"
    "pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task"
)

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


def download_model():
    if os.path.exists(MODEL_PATH):
        return
    urllib.request.urlretrieve(MODEL_URL, MODEL_PATH)


def decode_image(path: str):
    from PIL import Image, ImageOps
    import numpy as np
    with Image.open(path) as source:
        image = ImageOps.exif_transpose(source).convert("RGBA")
        background = Image.new("RGBA", image.size, "white")
        background.alpha_composite(image)
        return np.array(background.convert("RGB"))


def run(image_path: str) -> dict:
    import mediapipe as mp

    download_model()

    BaseOptions = mp.tasks.BaseOptions
    PoseLandmarker = mp.tasks.vision.PoseLandmarker
    PoseLandmarkerOptions = mp.tasks.vision.PoseLandmarkerOptions
    VisionRunningMode = mp.tasks.vision.RunningMode

    options = PoseLandmarkerOptions(
        base_options=BaseOptions(model_asset_path=MODEL_PATH),
        running_mode=VisionRunningMode.IMAGE,
        output_segmentation_masks=False,
    )

    rgb = decode_image(image_path)
    mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

    with PoseLandmarker.create_from_options(options) as detector:
        result = detector.detect(mp_image)

    fallback = False
    if not result.pose_world_landmarks:
        # Drawn silhouettes can score below the photographic detector threshold.
        options = PoseLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=MODEL_PATH),
            running_mode=VisionRunningMode.IMAGE,
            min_pose_detection_confidence=0.15,
            min_pose_presence_confidence=0.15,
            output_segmentation_masks=False,
        )
        with PoseLandmarker.create_from_options(options) as detector:
            result = detector.detect(mp_image)
        fallback = True
    if not result.pose_world_landmarks:
        return {"error": "No person detected. Try a clearer full-body image; drawings may need manual posing."}

    lm3d = []
    for i, lm in enumerate(result.pose_world_landmarks[0]):
        lm3d.append({
            "name": LANDMARK_NAMES[i] if i < len(LANDMARK_NAMES) else str(i),
            "x": lm.x,
            "y": lm.y,
            "z": lm.z,
            "visibility": lm.visibility,
            "image_x": result.pose_landmarks[0][i].x * rgb.shape[1] / rgb.shape[0],
            "image_y": result.pose_landmarks[0][i].y,
        })

    return {"world_landmarks": lm3d, "warning": "Illustration fallback: check the green skeleton before Apply Pose." if fallback else ""}


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: detect_pose.py <image_path>"}))
        sys.exit(1)

    image_path = sys.argv[1]
    if not os.path.exists(image_path):
        print(json.dumps({"error": "File not found: %s" % image_path}))
        sys.exit(1)

    try:
        result = run(image_path)
    except Exception as e:
        result = {"error": str(e)}

    # Single line of JSON to stdout — Godot reads the whole output array
    print(json.dumps(result))
