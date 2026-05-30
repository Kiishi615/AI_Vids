#!/bin/bash
# ============================================================================
# LivePortrait One-Shot Setup Script for RunPod
# ============================================================================
# HOW TO USE:
# 1. Deploy your pod on RunPod (any GPU from the ranked list)
# 2. Open Jupyter Lab → Terminal
# 3. Upload this file to /workspace/ OR paste these commands
# 4. Run: bash /workspace/setup_liveportrait.sh
# ============================================================================

set -e  # Stop on any error

echo "============================================"
echo "  LivePortrait Setup for RunPod"
echo "============================================"

# Navigate to persistent storage
cd /workspace

# ── Step 1: Clone LivePortrait ──────────────────────────────────────────────
if [ -d "LivePortrait" ]; then
    echo "[✓] LivePortrait already cloned, updating..."
    cd LivePortrait
    git pull
else
    echo "[→] Cloning LivePortrait..."
    git clone https://github.com/KwaiVGI/LivePortrait
    cd LivePortrait
fi

# ── Step 2: Install Python Dependencies ─────────────────────────────────────
echo "[→] Installing Python dependencies..."
pip install -r requirements.txt

# ── Step 2b: Fix Gradio version mismatch ────────────────────────────────────
# Fixes TypeError in gradio_client/utils.py where additionalProperties is bool
echo "[→] Upgrading Gradio to fix API schema bug..."
pip install --upgrade gradio gradio_client

# ── Step 3: Install FFmpeg ──────────────────────────────────────────────────
echo "[→] Installing FFmpeg..."
apt-get update -qq && apt-get install -y -qq ffmpeg

# ── Step 4: Download Model Weights ──────────────────────────────────────────
if [ -d "pretrained_weights" ] && [ "$(ls -A pretrained_weights)" ]; then
    echo "[✓] Model weights already downloaded, skipping..."
else
    echo "[→] Downloading model weights (~4GB, this takes 2-5 minutes)..."
    mkdir -p pretrained_weights
    huggingface-cli download KwaiVGI/LivePortrait --local-dir pretrained_weights
fi

# ── Step 5: Create output directories ───────────────────────────────────────
mkdir -p /workspace/portraits    # Put your source images here
mkdir -p /workspace/output       # Animated videos will go here
mkdir -p /workspace/final        # Looped/final videos will go here

echo ""
echo "============================================"
echo "  ✅ Setup Complete!"
echo "============================================"
echo ""
echo "  NEXT STEPS:"
echo ""
echo "  1. Upload your portrait images to:"
echo "     /workspace/portraits/"
echo ""
echo "  2. Launch the web UI with:"
echo "     cd /workspace/LivePortrait"
echo "     python app.py --server_name 0.0.0.0 --server_port 7860"
echo ""
echo "  3. Open the UI:"
echo "     Go to RunPod dashboard → your pod → Connect"
echo "     → Click 'Connect to HTTP Service [Port 7860]'"
echo ""
echo "  4. In the UI:"
echo "     - Upload your portrait photo"
echo "     - Use the Eye/Head sliders to animate"
echo "     - Click Generate"
echo ""
echo "============================================"
