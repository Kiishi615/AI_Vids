"""
Generate a custom LivePortrait driving pickle (.pkl) with natural blink + micro head movement.
No driving video needed — this creates motion data from pure math.

Usage (run on your RunPod pod):
  1. Upload this script to /workspace/LivePortrait/
  2. Run: python generate_blink_pickle.py
  3. The output file natural_blink.pkl will appear in the same directory
  4. In the Gradio UI, go to the "Driving Pickle" tab and upload natural_blink.pkl

Customize:
  - DURATION_SECONDS: total length of the animation
  - FPS: frames per second
  - BLINK_TIMES: list of times (in seconds) when blinks occur
  - HEAD_DRIFT_AMPLITUDE: how much the head drifts (degrees)
"""

import numpy as np
import pickle
import math

# ============================================================
# SETTINGS — Tweak these to your taste
# ============================================================
DURATION_SECONDS = 6.0      # Total animation length
FPS = 30                     # Frames per second
BLINK_TIMES = [1.8, 4.3]    # When blinks happen (seconds) — irregular spacing feels natural
BLINK_DURATION = 0.15        # How long a blink takes (seconds) — 150ms is realistic
HEAD_DRIFT_AMPLITUDE = 1.5   # Max head drift in degrees (keep under 3 for subtle)
HEAD_DRIFT_SPEED = 0.4       # How fast the head drifts (Hz) — slow = natural
BREATHE_AMPLITUDE = 0.3      # Subtle vertical "breathing" motion (degrees)
BREATHE_SPEED = 0.25         # Breathing frequency (Hz) — ~15 breaths/min


# ============================================================
# GENERATION — Don't need to touch below unless you're curious
# ============================================================

n_frames = int(DURATION_SECONDS * FPS)

def make_rotation_matrix(pitch_deg, yaw_deg, roll_deg):
    """Create a 3x3 rotation matrix from pitch/yaw/roll in degrees."""
    pitch = math.radians(pitch_deg)
    yaw = math.radians(yaw_deg)
    roll = math.radians(roll_deg)

    # Rotation matrices for each axis
    Rx = np.array([
        [1, 0, 0],
        [0, math.cos(pitch), -math.sin(pitch)],
        [0, math.sin(pitch), math.cos(pitch)]
    ], dtype=np.float32)

    Ry = np.array([
        [math.cos(yaw), 0, math.sin(yaw)],
        [0, 1, 0],
        [-math.sin(yaw), 0, math.cos(yaw)]
    ], dtype=np.float32)

    Rz = np.array([
        [math.cos(roll), -math.sin(roll), 0],
        [math.sin(roll), math.cos(roll), 0],
        [0, 0, 1]
    ], dtype=np.float32)

    return (Rz @ Ry @ Rx).reshape(1, 3, 3)


def smooth_blink_curve(t, blink_center, blink_half_duration):
    """
    Returns a value 0-1 representing eye closure.
    0 = fully open, 1 = fully closed.
    Uses a smooth cosine curve so the blink looks natural.
    """
    dist = abs(t - blink_center)
    if dist > blink_half_duration:
        return 0.0
    # Smooth cosine transition
    return 0.5 * (1 + math.cos(math.pi * dist / blink_half_duration))


def generate_motion_template():
    """Build the driving pickle data structure that LivePortrait expects."""

    template = {
        'n_frames': n_frames,
        'output_fps': FPS,
        'motion': [],
        'c_eyes_lst': [],
        'c_lip_lst': [],
    }

    # Neutral expression baseline (21 keypoints × 3 dimensions)
    # This is the "zero" expression — LivePortrait uses relative motion,
    # so frame 0 should be neutral (all zeros)
    neutral_exp = np.zeros((1, 21, 3), dtype=np.float32)
    neutral_kp = np.zeros((1, 21, 3), dtype=np.float32)
    neutral_scale = np.ones((1, 1), dtype=np.float32)
    neutral_t = np.zeros((1, 1, 3), dtype=np.float32)

    for i in range(n_frames):
        t = i / FPS  # current time in seconds

        # ---- HEAD DRIFT (Perlin-like smooth wander) ----
        # Use sine waves at different frequencies for organic-feeling drift
        yaw = HEAD_DRIFT_AMPLITUDE * math.sin(2 * math.pi * HEAD_DRIFT_SPEED * t)
        pitch = (BREATHE_AMPLITUDE * math.sin(2 * math.pi * BREATHE_SPEED * t)
                 + HEAD_DRIFT_AMPLITUDE * 0.3 * math.sin(2 * math.pi * HEAD_DRIFT_SPEED * 0.7 * t))
        roll = HEAD_DRIFT_AMPLITUDE * 0.15 * math.sin(2 * math.pi * HEAD_DRIFT_SPEED * 1.3 * t + 0.5)

        R = make_rotation_matrix(pitch, yaw, roll)

        # ---- BLINK ----
        blink_intensity = 0.0
        for bt in BLINK_TIMES:
            blink_intensity = max(blink_intensity, smooth_blink_curve(t, bt, BLINK_DURATION))

        # Expression deltas for blink — affect keypoints 11, 13, 15, 16 (eye-related)
        exp = neutral_exp.copy()
        if blink_intensity > 0:
            # These keypoint indices control the eyes in LivePortrait's implicit keypoint space
            # Index 11: right eye upper
            # Index 13: right eye lower
            # Index 15: left eye upper
            # Index 16: left eye lower
            # Y-axis (index 1) controls vertical position
            eye_close_amount = blink_intensity * 0.015  # calibrated for natural blink
            exp[0, 11, 1] += eye_close_amount      # right upper lid down
            exp[0, 13, 1] -= eye_close_amount * 0.3  # right lower lid up (less movement)
            exp[0, 15, 1] += eye_close_amount      # left upper lid down
            exp[0, 16, 1] -= eye_close_amount * 0.3  # left lower lid up

        # Subtle translation drift (matches head drift for realism)
        t_vec = neutral_t.copy()
        t_vec[0, 0, 0] = yaw * 0.001    # tiny x-shift with yaw
        t_vec[0, 0, 1] = pitch * 0.001   # tiny y-shift with pitch

        item = {
            'scale': neutral_scale.copy(),
            'R': R,
            'exp': exp,
            't': t_vec,
            'kp': neutral_kp.copy(),
            'x_s': neutral_kp.copy(),  # will be recomputed by LivePortrait
        }
        template['motion'].append(item)

        # Eye ratio: 0.3-0.4 = natural open, 0.0 = closed
        # LivePortrait uses this for its retargeting system
        eye_ratio = max(0.0, 0.35 * (1 - blink_intensity))
        template['c_eyes_lst'].append(
            np.array([[eye_ratio, eye_ratio]], dtype=np.float32)
        )

        # Lip ratio: keep closed (0.0) throughout
        template['c_lip_lst'].append(
            np.array([[0.0]], dtype=np.float32)
        )

    return template


if __name__ == '__main__':
    print(f"Generating {DURATION_SECONDS}s animation at {FPS}fps ({n_frames} frames)")
    print(f"Blinks at: {BLINK_TIMES}s")
    print(f"Head drift: ±{HEAD_DRIFT_AMPLITUDE}° yaw, breathing at {BREATHE_SPEED}Hz")

    template = generate_motion_template()

    output_path = 'natural_blink.pkl'
    with open(output_path, 'wb') as f:
        pickle.dump(template, f)

    print(f"\n✅ Saved to: {output_path}")
    print(f"   {template['n_frames']} frames at {template['output_fps']} fps")
    print(f"\nTo use in LivePortrait Gradio UI:")
    print(f"  1. Upload your portrait to 'Source Image' (top-left)")
    print(f"  2. Click the '📁 Driving Pickle' tab (top-right)")
    print(f"  3. Upload {output_path}")
    print(f"  4. Click '🚀 Animate'")
    print(f"\nTo use via command line:")
    print(f"  python inference.py -s your_portrait.jpg -d {output_path}")
