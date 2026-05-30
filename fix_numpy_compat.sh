#!/bin/bash
# ============================================================================
# Fix: numpy binary incompatibility on Lightning AI  (v2 — comprehensive)
# ============================================================================
#
# PROBLEM:
#   "numpy.dtype size changed, may indicate binary incompatibility.
#    Expected 96 from C header, got 88 from PyObject"
#
#   This means packages were compiled against numpy 1.x (dtype 88 bytes)
#   but numpy 2.x is installed (dtype 96 bytes), or vice versa.
#
# ROOT CAUSE:
#   Lightning AI's conda env ships numpy 2.x, but some pip-installed wheels
#   (transformers, diffusers, scikit-image, etc.) were built against numpy 1.x.
#
# FIX STRATEGY:
#   Pin numpy to 1.26.x (1.x) and force-reinstall EVERY package that links
#   against numpy's C ABI. This is more reliable than upgrading to 2.x because
#   many ML packages still ship wheels compiled against numpy 1.x.
#
# USAGE:
#   bash ~/workspace/fix_numpy_compat.sh
#
# TIME: ~3-5 minutes
# ============================================================================

set -e

echo ""
echo "============================================"
echo "  🔧 Fixing numpy binary incompatibility"
echo "  Strategy: pin numpy 1.26.x + rebuild all"
echo "============================================"
echo ""

# ── Step 1: Check what we're starting with ──────────────────────────────────
echo "── Current state ──"
python -c "
import numpy; print(f'  numpy:      {numpy.__version__}')
" 2>/dev/null || echo "  numpy: NOT IMPORTABLE"

python -c "
try:
    import transformers; print(f'  transformers: {transformers.__version__}')
except Exception as e:
    print(f'  transformers: BROKEN ({type(e).__name__})')
try:
    import diffusers; print(f'  diffusers:  {diffusers.__version__}')
except Exception as e:
    print(f'  diffusers:  BROKEN ({type(e).__name__})')
try:
    from skimage import transform; print('  scikit-image: OK')
except Exception as e:
    print(f'  scikit-image: BROKEN ({type(e).__name__})')
" 2>/dev/null || true
echo ""

# ── Step 2: Pin numpy to 1.26.x ────────────────────────────────────────────
echo "[1/4] Pinning numpy to 1.26.x..."
pip install --no-cache-dir "numpy==1.26.4" 2>&1 | tail -3
echo "  [✓] numpy $(python -c 'import numpy; print(numpy.__version__)')"

# ── Step 3: Force-reinstall ALL packages with numpy C extensions ────────────
# These packages contain compiled C/Cython code that links against numpy's ABI.
# If they were installed when a different numpy major version was present,
# they will crash with "dtype size changed".
echo ""
echo "[2/4] Force-reinstalling packages with numpy C bindings..."
echo "  (This takes 2-3 minutes — rebuilding C extensions)"
echo ""

# Group 1: Core scientific stack (heavy C extensions)
echo "  → scipy + scikit-image..."
pip install --no-cache-dir --force-reinstall \
    "scipy>=1.11,<1.14" \
    "scikit-image>=0.21" \
    2>&1 | tail -3

# Group 2: ML framework wrappers (tokenizers/safetensors have Rust+C bindings)
echo "  → transformers + diffusers + tokenizers + safetensors..."
pip install --no-cache-dir --force-reinstall \
    "transformers==4.48.0" \
    "diffusers==0.32.2" \
    "tokenizers" \
    "safetensors" \
    2>&1 | tail -3

# Group 3: Computer vision / media packages
echo "  → opencv + mediapipe + insightface..."
pip install --no-cache-dir --force-reinstall \
    "opencv-python>=4.9" \
    2>&1 | tail -3

pip install --no-cache-dir --force-reinstall \
    "mediapipe>=0.10" \
    2>&1 | tail -3 || echo "  [⚠] mediapipe reinstall had issues (non-critical)"

pip install --no-cache-dir --force-reinstall \
    "insightface==0.7.3" \
    2>&1 | tail -3 || echo "  [⚠] insightface reinstall had issues (non-critical)"

# Group 4: Other numpy-dependent packages
echo "  → kornia + librosa + face-alignment..."
pip install --no-cache-dir --force-reinstall \
    "kornia==0.8.0" \
    "librosa==0.10.1" \
    "face-alignment==1.4.1" \
    "lpips==0.1.4" \
    2>&1 | tail -3

# ── Step 4: Verify numpy wasn't silently upgraded ──────────────────────────
echo ""
echo "[3/4] Verifying numpy stayed at 1.26.x..."
NUMPY_VER=$(python -c "import numpy; print(numpy.__version__)")
echo "  numpy: $NUMPY_VER"

if [[ "$NUMPY_VER" == 2.* ]]; then
    echo "  [⚠] numpy got pulled to 2.x by a dependency — re-pinning..."
    pip install --no-cache-dir "numpy==1.26.4" 2>&1 | tail -2
    # Re-check
    NUMPY_VER=$(python -c "import numpy; print(numpy.__version__)")
    echo "  numpy now: $NUMPY_VER"
fi

# ── Step 5: Full import chain verification ──────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[4/4] Verifying full import chain..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

python -c "
import sys
print(f'  Python:        {sys.version.split()[0]}')

import numpy as np
print(f'  numpy:         {np.__version__}  ✅')

import scipy
print(f'  scipy:         {scipy.__version__}  ✅')

from skimage import transform
print(f'  scikit-image:  OK  ✅')

import torch
print(f'  torch:         {torch.__version__}  ✅')
if torch.cuda.is_available():
    print(f'  GPU:           {torch.cuda.get_device_name(0)}')

# This is the exact chain that was failing:
import transformers
print(f'  transformers:  {transformers.__version__}  ✅')

import diffusers
print(f'  diffusers:     {diffusers.__version__}  ✅')

from diffusers.models.autoencoders.autoencoder_kl import AutoencoderKL
print(f'  AutoencoderKL: importable  ✅')

# Test the exact failing import path
from diffusers.loaders.peft import PeftAdapterMixin
print(f'  PeftAdapter:   importable  ✅')

import kornia
print(f'  kornia:        {kornia.__version__}  ✅')

import librosa
print(f'  librosa:       {librosa.__version__}  ✅')

import cv2
print(f'  opencv:        {cv2.__version__}  ✅')

try:
    import mediapipe
    print(f'  mediapipe:     {mediapipe.__version__}  ✅')
except Exception as e:
    print(f'  mediapipe:     ⚠ {e}')

try:
    import insightface
    print(f'  insightface:   {insightface.__version__}  ✅')
except Exception as e:
    print(f'  insightface:   ⚠ {e}')

print()
print('  🎉 All imports passed — LatentSync should work now!')
" 2>&1

RESULT=$?

echo ""
if [ $RESULT -eq 0 ]; then
    echo "============================================"
    echo "  ✅ Fixed! Re-run your pipeline:"
    echo ""
    echo "  bash ~/workspace/lightning_run_pipeline.sh \\"
    echo "    ~/workspace/portraits/Kid1.png \\"
    echo "    ~/workspace/audio/5min.mp3"
    echo "============================================"
else
    echo "============================================"
    echo "  ⚠ Some imports still failing — check above"
    echo "============================================"
    echo ""
    echo "  Nuclear option (if above didn't work):"
    echo "    pip install --no-cache-dir --force-reinstall \\"
    echo "      numpy==1.26.4 scipy scikit-image transformers \\"
    echo "      diffusers tokenizers safetensors"
fi
echo ""
