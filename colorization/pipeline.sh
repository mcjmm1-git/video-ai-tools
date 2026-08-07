#!/usr/bin/env bash

set -Eeuo pipefail

INPUT="/input/${COLOR_INPUT}"
OUTPUT="/output/${COLOR_OUTPUT}"

TEST_START="${TEST_START:-00:10:00}"
TEST_DURATION="${TEST_DURATION:-20}"

REF_EVERY="${REF_EVERY:-2}"
DDCOLOR_SIZE="${DDCOLOR_SIZE:-512}"

CMNET_MAX_SIDE="${CMNET_MAX_SIDE:-512}"
CMNET_WINDOW="${CMNET_WINDOW:-20}"
CMNET_TOP_K="${CMNET_TOP_K:-20}"
CMNET_MEM_EVERY="${CMNET_MEM_EVERY:-10}"

WORK="/work"
REFS_BW="$WORK/refs-bw"
REFS_COLOR="$WORK/refs-color"

mkdir -p \
    /models/cmnet2/weights \
    /models/cmnet2/models/checkpoints \
    "$REFS_BW" \
    "$REFS_COLOR"

echo
echo "============================================================"
echo " DDColor + CMNET2"
echo "============================================================"
echo "Entrada:       $INPUT"
echo "Salida:        $OUTPUT"
echo "Ref cada:      $REF_EVERY segundos"
echo "CMNET tamaño:  $CMNET_MAX_SIDE"
echo "CMNET ventana: $CMNET_WINDOW"
echo

echo "=== GPU ==="

python - <<'PY'
import torch

print("PyTorch:", torch.__version__)
print("CUDA disponible:", torch.cuda.is_available())

if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
PY

###############################################################################
# MODELOS CMNET2
###############################################################################

download()
{
    local url="$1"
    local dest="$2"

    if [[ ! -s "$dest" ]]; then
        echo
        echo "Descargando $(basename "$dest")..."
        curl -fL --retry 5 --retry-delay 3 \
            "$url" \
            -o "$dest"
    fi
}

download \
"https://github.com/dan64/cmnet2/releases/download/v1.0.0/DINOv2FeatureV6_LocalAtten_s2_154000.pth" \
"/models/cmnet2/weights/DINOv2FeatureV6_LocalAtten_s2_154000.pth"

download \
"https://github.com/dan64/cmnet2/releases/download/v1.0.0/dinov2_vits14_pretrain.pth" \
"/models/cmnet2/models/checkpoints/dinov2_vits14_pretrain.pth"

download \
"https://github.com/dan64/cmnet2/releases/download/v1.0.0/resnet18-5c106cde.pth" \
"/models/cmnet2/models/checkpoints/resnet18-5c106cde.pth"

download \
"https://github.com/dan64/cmnet2/releases/download/v1.0.0/resnet50-19c8e357.pth" \
"/models/cmnet2/models/checkpoints/resnet50-19c8e357.pth"

if [[ ! -d /models/cmnet2/models/facebookresearch_dinov2_main ]]; then
    echo
    echo "Descargando código DINOv2..."

    download \
    "https://github.com/dan64/cmnet2/releases/download/v1.0.0/facebookresearch_dinov2_main.zip" \
    "/models/cmnet2/facebookresearch_dinov2_main.zip"

    unzip -q \
        /models/cmnet2/facebookresearch_dinov2_main.zip \
        -d /models/cmnet2/models
fi

###############################################################################
# ENLAZAR MODELOS CON CMNET2
###############################################################################

rm -rf /opt/cmnet2/weights
ln -s /models/cmnet2/weights /opt/cmnet2/weights

rm -rf /opt/cmnet2/models
ln -s /models/cmnet2/models /opt/cmnet2/models

###############################################################################
# PRUEBA O PELÍCULA COMPLETA
###############################################################################

WORK_INPUT="$INPUT"

if [[ "$TEST_DURATION" != "0" ]]; then
    echo
    echo "=== Preparando prueba ==="
    echo "Inicio: $TEST_START"
    echo "Duración: $TEST_DURATION segundos"

    rm -f "$WORK/test-input.mkv"

    ffmpeg \
        -hide_banner \
        -loglevel warning \
        -y \
        -ss "$TEST_START" \
        -i "$INPUT" \
        -t "$TEST_DURATION" \
        -map 0 \
        -c copy \
        "$WORK/test-input.mkv"

    WORK_INPUT="$WORK/test-input.mkv"
fi

###############################################################################
# REFERENCIAS
###############################################################################

echo
echo "=== 1/4 Generando fotogramas de referencia ==="

rm -rf "$REFS_BW" "$REFS_COLOR"
mkdir -p "$REFS_BW" "$REFS_COLOR"

python /app/make_refs.py \
    --input "$WORK_INPUT" \
    --output "$REFS_BW" \
    --every "$REF_EVERY"

###############################################################################
# DDCOLOR
###############################################################################

echo
echo "=== 2/4 Coloreando referencias con DDColor ==="

cd /opt/DDColor

python scripts/infer.py \
    --model_name ddcolor_artistic \
    --input "$REFS_BW" \
    --output "$REFS_COLOR" \
    --input_size "$DDCOLOR_SIZE"

###############################################################################
# CMNET2
###############################################################################

echo
echo "=== 3/4 Propagando y estabilizando color con CMNET2 ==="

rm -f "$WORK/cmnet2.mp4"

cd /opt/cmnet2

python test_video_full.py \
    --input "$WORK_INPUT" \
    --ref_path "$REFS_COLOR" \
    --output "$WORK/cmnet2.mp4" \
    --max_side "$CMNET_MAX_SIDE" \
    --window_size "$CMNET_WINDOW" \
    --top_k "$CMNET_TOP_K" \
    --mem_every "$CMNET_MEM_EVERY"

###############################################################################
# AUDIO
###############################################################################

echo
echo "=== 4/4 Añadiendo audio y subtítulos originales ==="

rm -f "$OUTPUT"

ffmpeg \
    -hide_banner \
    -y \
    -i "$WORK/cmnet2.mp4" \
    -i "$WORK_INPUT" \
    -map 0:v:0 \
    -map 1:a? \
    -map 1:s? \
    -map_metadata 1 \
    -c:v copy \
    -c:a copy \
    -c:s copy \
    "$OUTPUT"

echo
echo "============================================================"
echo " TERMINADO"
echo " $OUTPUT"
echo "============================================================"
