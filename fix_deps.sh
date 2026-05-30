#!/bin/bash
# ============================================================================
# Lightning AI — Dependency Scanner & Fixer
# ============================================================================
#
# Scans ALL Python imports needed by LivePortrait and LatentSync,
# reports what's missing, and installs everything in one pass.
#
# USAGE:
#   bash ~/workspace/fix_deps.sh
#
# ============================================================================

set -e

WORKSPACE="$HOME/workspace"

echo ""
echo "============================================"
echo "  🔍 Dependency Scanner & Fixer"
echo "  ⚡ Lightning AI"
echo "============================================"
echo ""

# ── Step 1: Scan all imports ────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Scanning imports..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

MISSING_PACKAGES=""
ALL_OK=true

check_import() {
    local module="$1"
    local pip_name="${2:-$1}"  # pip package name (if different from module)
    local version="${3:-}"     # optional version pin
    
    if python -c "import $module" 2>/dev/null; then
        ver=$(python -c "import $module; print(getattr($module, '__version__', '?'))" 2>/dev/null || echo "?")
        echo "  ✅ $module ($ver)"
    else
        echo "  ❌ $module — MISSING"
        if [ -n "$version" ]; then
            MISSING_PACKAGES="$MISSING_PACKAGES ${pip_name}==${version}"
        else
            MISSING_PACKAGES="$MISSING_PACKAGES ${pip_name}"
        fi
        ALL_OK=false
    fi
}

echo ""
echo "── Core ML ──"
check_import "torch"
check_import "torchvision"
check_import "torchaudio"

echo ""
echo "── LivePortrait deps ──"
check_import "cv2" "opencv-python" "4.9.0.80"
check_import "PIL" "Pillow" "10.2.0"
check_import "numpy" "numpy" "1.26.4"
check_import "scipy" "scipy"
check_import "skimage" "scikit-image"
check_import "pykalman" "pykalman"
check_import "dill" "dill"
check_import "tyro" "tyro"
check_import "lmdb" "lmdb"
check_import "yaml" "pyyaml"
check_import "tqdm" "tqdm"
check_import "imageio" "imageio" "2.31.1"
check_import "insightface" "insightface" "0.7.3"
check_import "onnxruntime" "onnxruntime-gpu"
check_import "mediapipe" "mediapipe"
check_import "safetensors" "safetensors"

echo ""
echo "── LatentSync deps ──"
check_import "diffusers" "diffusers" "0.32.2"
check_import "transformers" "transformers" "4.48.0"
check_import "accelerate" "accelerate" "0.26.1"
check_import "einops" "einops" "0.7.0"
check_import "omegaconf" "omegaconf" "2.3.0"
check_import "python_speech_features" "python_speech_features" "0.6"
check_import "librosa" "librosa" "0.10.1"
check_import "scenedetect" "scenedetect" "0.6.1"
check_import "lpips" "lpips" "0.1.4"
check_import "face_alignment" "face-alignment" "1.4.1"
check_import "kornia" "kornia" "0.8.0"
check_import "DeepCache" "DeepCache" "0.1.1"
check_import "huggingface_hub" "huggingface-hub" "0.30.2"
check_import "decord" "decord"

echo ""
echo "── Video/Audio tools ──"
check_import "ffmpeg" "ffmpeg-python" "0.2.0"
check_import "imageio_ffmpeg" "imageio-ffmpeg" "0.5.1"

# Check ffmpeg binary
if command -v ffmpeg &>/dev/null; then
    echo "  ✅ ffmpeg binary ($(ffmpeg -version 2>&1 | head -1 | awk '{print $3}'))"
else
    echo "  ❌ ffmpeg binary — MISSING (run: sudo apt-get install ffmpeg)"
fi

# Check ffprobe binary
if command -v ffprobe &>/dev/null; then
    echo "  ✅ ffprobe binary"
else
    echo "  ❌ ffprobe binary — MISSING (run: sudo apt-get install ffmpeg)"
fi

# ── Step 2: Fix what's broken ───────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$ALL_OK" = true ]; then
    echo "  ✅ All dependencies present!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo "  📦 Installing missing packages..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Missing: $MISSING_PACKAGES"
    echo ""
    
    pip install --no-cache-dir $MISSING_PACKAGES 2>&1 | tail -5
    
    echo ""
    echo "  [→] Re-checking..."
    echo ""
    
    # Quick re-check
    STILL_BROKEN=false
    for pkg in $MISSING_PACKAGES; do
        mod=$(echo "$pkg" | sed 's/==.*//' | sed 's/-/_/g')
        # Handle special module names
        case "$mod" in
            opencv_python) mod="cv2" ;;
            Pillow) mod="PIL" ;;
            pyyaml) mod="yaml" ;;
            scikit_image) mod="skimage" ;;
            onnxruntime_gpu) mod="onnxruntime" ;;
            face_alignment) mod="face_alignment" ;;
            ffmpeg_python) mod="ffmpeg" ;;
            imageio_ffmpeg) mod="imageio_ffmpeg" ;;
            huggingface_hub) mod="huggingface_hub" ;;
        esac
        if python -c "import $mod" 2>/dev/null; then
            echo "  ✅ $mod — fixed"
        else
            echo "  ❌ $mod — still broken"
            STILL_BROKEN=true
        fi
    done
    
    echo ""
    if [ "$STILL_BROKEN" = true ]; then
        echo "  ⚠ Some packages still failing — check errors above"
    else
        echo "  ✅ All fixed! Try running the pipeline again."
    fi
fi

# ── Step 3: Check binary compatibility ──────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Testing binary compatibility..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

python -c "
import sys
try:
    from skimage import transform
    print('  ✅ scikit-image + numpy compatible')
except ValueError as e:
    print(f'  ❌ scikit-image/numpy mismatch: {e}')
    print('     Fix: pip install --force-reinstall scikit-image numpy==1.26.4')

try:
    import insightface
    from insightface.model_zoo import model_zoo
    print('  ✅ insightface imports OK')
except Exception as e:
    print(f'  ❌ insightface issue: {e}')

try:
    import torch
    if torch.cuda.is_available():
        print(f'  ✅ CUDA available: {torch.cuda.get_device_name(0)}')
        vram = torch.cuda.get_device_properties(0).total_memory / 1e9
        print(f'     VRAM: {vram:.1f} GB')
    else:
        print('  ⚠ CUDA not available (CPU only)')
except Exception as e:
    print(f'  ❌ PyTorch/CUDA issue: {e}')
" 2>&1

echo ""
echo "============================================"
echo "  Done! Run your pipeline:"
echo "  bash ~/workspace/lightning_run_pipeline.sh \\"
echo "    ~/workspace/portraits/Kid1.png \\"
echo "    ~/workspace/audio/5min.mp3"
echo "============================================"
