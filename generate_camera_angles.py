import os
import sys
from PIL import Image

def generate_angles(input_path):
    if not os.path.exists(input_path):
        print(f"❌ Original image not found at: {input_path}")
        return

    base_dir = os.path.dirname(input_path)
    base_name = os.path.basename(input_path).split('.')[0]
    
    # Check if we already generated them or if the user provided multiple
    existing_files = [f for f in os.listdir(base_dir) if f.startswith(base_name) and f != os.path.basename(input_path)]
    if len(existing_files) > 1:
        print("✅ Multiple camera angles already detected. Skipping auto-generation.")
        return

    print("📸 Auto-generating virtual camera angles from original portrait...")
    img = Image.open(input_path).convert("RGB")
    w, h = img.size

    # Angle 1: Main (Original)
    img.save(os.path.join(base_dir, f"{base_name}_1_main.png"))
    print("  - Generated Main Camera")
    
    # Angle 2: Close Up (10% Zoom)
    crop_w, crop_h = w * 0.90, h * 0.90
    left = (w - crop_w) / 2
    top = (h - crop_h) / 2
    right = (w + crop_w) / 2
    bottom = (h + crop_h) / 2
    img_zoom = img.crop((left, top, right, bottom)).resize((w, h), Image.Resampling.LANCZOS)
    img_zoom.save(os.path.join(base_dir, f"{base_name}_2_closeup.png"))
    print("  - Generated Close-Up Camera")
    
    # Angle 3: Medium Left (5% Zoom, shifted slightly left)
    crop_w, crop_h = w * 0.95, h * 0.95
    left = 0
    top = (h - crop_h) / 2
    right = crop_w
    bottom = (h + crop_h) / 2
    img_left = img.crop((left, top, right, bottom)).resize((w, h), Image.Resampling.LANCZOS)
    img_left.save(os.path.join(base_dir, f"{base_name}_3_left.png"))
    print("  - Generated Medium Left Camera")

    # Angle 4: Medium Right (5% Zoom, shifted slightly right)
    crop_w, crop_h = w * 0.95, h * 0.95
    left = w - crop_w
    top = (h - crop_h) / 2
    right = w
    bottom = (h + crop_h) / 2
    img_right = img.crop((left, top, right, bottom)).resize((w, h), Image.Resampling.LANCZOS)
    img_right.save(os.path.join(base_dir, f"{base_name}_4_right.png"))
    print("  - Generated Medium Right Camera")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python generate_camera_angles.py <path_to_portrait.png>")
        sys.exit(1)
    
    generate_angles(sys.argv[1])
