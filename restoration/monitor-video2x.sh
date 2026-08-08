#!/usr/bin/env bash
set -u
export LC_NUMERIC=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1

CONTAINER="${CONTAINER:-video2x}"
ENV_FILE="${ENV_FILE:-$DIR/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$DIR/compose.yaml}"
REFRESH="${REFRESH:-2}"
PROBE_INTERVAL="${PROBE_INTERVAL:-30}"

RESET=$'\e[0m'
BLUE=$'\e[34m'
GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
BOLD=$'\e[1m'
BG=$'\e[46m'

get_env() {
    local k="$1" v
    v=$(grep -E "^[[:space:]]*${k}[[:space:]]*=" "$ENV_FILE" 2>/dev/null |
        tail -1 |
        sed -E "s/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*//")
    [[ "$v" == \"*\" || "$v" == \'*\' ]] && v="${v:1:${#v}-2}"
    printf '%s' "$v"
}

hms() {
    local s
    s=$(awk -v x="${1:-0}" 'BEGIN {printf "%d",x+0}')
    (( s < 0 )) && s=0
    printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

bar() {
    local p="${1:-0}" w="${2:-30}" f e
    f=$(awk -v p="$p" -v w="$w" 'BEGIN {
        if(p<0)p=0
        if(p>100)p=100
        printf "%d",p*w/100+0.5
    }')
    e=$((w-f))
    printf "["
    ((f>0)) && printf "%s%${f}s%s" "$BG" "" "$RESET"
    ((e>0)) && printf "%${e}s" ""
    printf "]"
}

# Obtiene la ruta del host desde compose.yaml.
# Así, si cambias /mnt/dd2 por /mnt/pepito, solo hay que tocar compose.yaml.
compose_mount_source() {
    local target="$1"

    docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null |
    python3 -c '
import json, sys
target = sys.argv[1]
try:
    data = json.load(sys.stdin)
    for v in data.get("services", {}).get("video2x", {}).get("volumes", []):
        if isinstance(v, dict) and v.get("target") == target:
            print(v.get("source", ""))
            break
except Exception:
    pass
' "$target"
}

# Mientras Video2X está ejecutándose usamos el montaje real del contenedor.
# Si está parado/no existe, leemos compose.yaml, que es la configuración
# que se aplicará en el próximo arranque. Así basta con cambiar compose.yaml.
mount_source() {
    local destination="$1"
    local source=""
    local state=""

    state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)

    if [[ "$state" == "running" ]]; then
        source=$(docker inspect \
            -f "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{.Source}}{{end}}{{end}}" \
            "$CONTAINER" 2>/dev/null || true)
    fi

    if [[ -z "$source" ]]; then
        source=$(compose_mount_source "$destination" || true)
    fi

    printf '%s' "$source"
}

[[ -f "$ENV_FILE" ]] || { echo "ERROR: no encuentro $ENV_FILE"; exit 1; }
[[ -f "$COMPOSE_FILE" ]] || { echo "ERROR: no encuentro $COMPOSE_FILE"; exit 1; }

VIDEO_INPUT=$(get_env VIDEO_INPUT)
VIDEO_RESTORED=$(get_env VIDEO_RESTORED)
SCALE=$(get_env SCALE)
GPU_DEVICE=$(get_env GPU)

[[ -n "$VIDEO_INPUT" && -n "$VIDEO_RESTORED" ]] || {
    echo "ERROR: faltan VIDEO_INPUT o VIDEO_RESTORED en .env"
    exit 1
}

THREADS=$(nproc 2>/dev/null || echo 1)
[[ "$THREADS" =~ ^[0-9]+$ ]] || THREADS=1

CORES=$(lscpu -p=CORE,SOCKET 2>/dev/null |
    grep -v '^#' | sort -u | wc -l | tr -d ' ')
[[ "$CORES" =~ ^[0-9]+$ ]] || CORES="?"

duration() {
    [[ -n "$INPUT_DIR" && -f "$INPUT_DIR/$VIDEO_INPUT" ]] || { echo 0; return; }

    docker run --rm \
        --entrypoint ffprobe \
        -v "$INPUT_DIR:/input:ro" \
        lscr.io/linuxserver/ffmpeg:latest \
        -v error \
        -show_entries format=duration \
        -of default=nw=1:nk=1 \
        "/input/$VIDEO_INPUT" 2>/dev/null |
        head -1 |
        awk '{printf "%.0f",$1+0}'
}

processed() {
    [[ -n "$OUTPUT_DIR" && -f "$OUTPUT_DIR/$VIDEO_RESTORED" ]] || { echo 0; return; }

    docker run --rm \
        --entrypoint ffprobe \
        -v "$OUTPUT_DIR:/output:ro" \
        lscr.io/linuxserver/ffmpeg:latest \
        -v error \
        -select_streams v:0 \
        -show_entries packet=pts_time \
        -of csv=p=0 \
        "/output/$VIDEO_RESTORED" 2>/dev/null |
        tail -1 |
        awk '{printf "%.0f",$1+0}'
}

cleanup() { printf '\e[?25h\e[?1049l'; }
trap cleanup EXIT INT TERM
printf '\e[?1049h\e[?25l\e[2J\e[H'

TOTAL=0
DONE=0
LAST=0
LAST_INPUT_DIR=""
LAST_OUTPUT_DIR=""

while true; do
    NOW=$(date +%s)

    INPUT_DIR=$(mount_source /input)
    OUTPUT_DIR=$(mount_source /output)

    if [[ "$INPUT_DIR" != "$LAST_INPUT_DIR" || "$OUTPUT_DIR" != "$LAST_OUTPUT_DIR" ]]; then
        TOTAL=0
        DONE=0
        LAST=0
        LAST_INPUT_DIR="$INPUT_DIR"
        LAST_OUTPUT_DIR="$OUTPUT_DIR"
    fi

    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
        printf '\e[H\e[2J'
        printf "%b==============================================================%b\n" "$BLUE" "$RESET"
        printf "%b                 MONITOR VIDEO2X%b\n" "$BOLD" "$RESET"
        printf "%b==============================================================%b\n\n" "$BLUE" "$RESET"
        echo " Estado       : ● Contenedor no creado"
        echo
        echo " Entrada      : $VIDEO_INPUT"
        echo " Salida       : $VIDEO_RESTORED"
        echo " Entrada host : ${INPUT_DIR:-No detectada en compose.yaml}"
        echo " Salida host  : ${OUTPUT_DIR:-No detectada en compose.yaml}"
        echo
        echo " El monitor está listo. Arranca Video2X cuando quieras."
        echo " Actualización cada ${REFRESH}s · Ctrl+C cierra solo el monitor"
        sleep "$REFRESH"
        continue
    fi

    STATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo desconocido)
    EXIT=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || echo "-")

    START=$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null || true)
    FIN=$(docker inspect -f '{{.State.FinishedAt}}' "$CONTAINER" 2>/dev/null || true)

    SE=$(date -d "$START" +%s 2>/dev/null || echo "$NOW")
    EE=$NOW
    [[ "$STATE" == exited && "$FIN" != 0001-01-01T00:00:00Z ]] &&
        EE=$(date -d "$FIN" +%s 2>/dev/null || echo "$NOW")

    EL=$((EE-SE))
    ((EL<0)) && EL=0

    ((TOTAL==0)) && TOTAL=$(duration)

    if [[ "$STATE" == running ]] && ((NOW-LAST>=PROBE_INTERVAL)); then
        N=$(processed)
        ((N>=DONE)) && DONE=$N
        LAST=$NOW
    fi

    PCT=$(awk -v a="$DONE" -v b="$TOTAL" 'BEGIN {
        if(b>0)p=a*100/b
        else p=0
        if(p>100)p=100
        printf "%.2f",p
    }')

    SPEED=$(awk -v a="$DONE" -v e="$EL" 'BEGIN {
        if(e>0)printf "%.3f",a/e
        else print "0.000"
    }')

    ETA=0
    ETA_TXT="Calculando..."
    END_TXT="--:--:--"

    if [[ "$STATE" == exited && "$EXIT" == 0 ]]; then
        PCT="100.00"
        ((TOTAL>0)) && DONE=$TOTAL
        ETA_TXT="00:00:00"
        END_TXT="terminado"
    elif [[ "$STATE" == running ]] && ((DONE>0 && TOTAL>DONE)); then
        ETA=$(awk -v r="$((TOTAL-DONE))" -v s="$SPEED" 'BEGIN {
            if(s>0)printf "%.0f",r/s
            else print 0
        }')
        ETA_TXT=$(hms "$ETA")
        END_TXT=$(date -d "+$ETA seconds" +%H:%M:%S 2>/dev/null || echo --:--:--)
    fi

    GD=$(nvidia-smi \
        --query-gpu=name,memory.total,temperature.gpu,power.draw \
        --format=csv,noheader,nounits 2>/dev/null | head -1)

    GN="No disponible"; GMT=0; GT=0; GP=0; GU=0; GMU=0
    GPT="Sin actividad GPU de Video2X"

    if [[ -n "$GD" ]]; then
        IFS=',' read -r GN GMT GT GP <<<"$GD"
        GN=$(xargs <<<"$GN"); GMT=$(xargs <<<"$GMT")
        GT=$(xargs <<<"$GT"); GP=$(xargs <<<"$GP")
    fi

    if [[ "$STATE" == running ]]; then
        PIDS=$(docker top "$CONTAINER" -eo pid 2>/dev/null |
            awk 'NR>1&&$1~/^[0-9]+$/{print $1}')

        while read -r pid sm fb; do
            [[ -n "${pid:-}" ]] || continue
            if grep -qx "$pid" <<<"$PIDS"; then
                GPT="Video2X · PID $pid"
                [[ "$sm" =~ ^[0-9]+$ ]] &&
                    GU=$(awk -v a="$GU" -v b="$sm" 'BEGIN{x=a+b;if(x>100)x=100;print x}')
                [[ "$fb" =~ ^[0-9]+$ ]] && GMU=$((GMU+fb))
            fi
        done < <(
            nvidia-smi pmon -c 1 -s um 2>/dev/null |
            awk '!/^#/&&$2~/^[0-9]+$/{print $2,$4,$5}'
        )
    fi

    CPU="0 %"; RAM="0 B"; RP="0 %"; BIO="-"

    if [[ "$STATE" == running ]]; then
        S=$(docker stats --no-stream \
            --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.BlockIO}}' \
            "$CONTAINER" 2>/dev/null || true)
        [[ -n "$S" ]] && IFS='|' read -r CPU RAM RP BIO <<<"$S"
    fi

    CN=$(tr -d ' %' <<<"$CPU")
    RPN=$(tr -d ' %' <<<"$RP")
    [[ "$CN" =~ ^[0-9]+([.][0-9]+)?$ ]] || CN=0
    [[ "$RPN" =~ ^[0-9]+([.][0-9]+)?$ ]] || RPN=0

    USED=$(awk -v c="$CN" 'BEGIN{printf "%.1f",c/100}')
    CP=$(awk -v c="$CN" -v n="$THREADS" 'BEGIN{p=c/n;if(p>100)p=100;printf "%.1f",p}')

    SIZE="0 B"
    [[ -n "$OUTPUT_DIR" && -f "$OUTPUT_DIR/$VIDEO_RESTORED" ]] &&
        SIZE=$(du -h "$OUTPUT_DIR/$VIDEO_RESTORED" 2>/dev/null | awk '{print $1}')

    VK=$(docker logs --tail 300 "$CONTAINER" 2>&1 |
        grep 'Using Vulkan device:' | tail -1 |
        sed -E 's/.*Using Vulkan device: //' || true)
    [[ -n "$VK" ]] || VK="No detectado todavía"

    if [[ "$STATE" == running ]]; then
        ST="● Procesando"; SC=$GREEN; PH="Video2X · restaurando vídeo"
    elif [[ "$STATE" == exited && "$EXIT" == 0 ]]; then
        ST="● Finalizado · código 0"; SC=$GREEN; PH="Finalizado"
    elif [[ "$STATE" == exited ]]; then
        ST="● Error · código $EXIT"; SC=$RED; PH="Video2X detenido con error"
    else
        ST="● $STATE"; SC=$YELLOW; PH="Video2X · $STATE"
    fi

    printf '\e[H\e[2J'
    printf "%b==============================================================%b\n" "$BLUE" "$RESET"
    printf "%b                 MONITOR VIDEO2X%b\n" "$BOLD" "$RESET"
    printf "%b==============================================================%b\n\n" "$BLUE" "$RESET"

    printf " Estado       : %b%s%b\n" "$SC" "$ST" "$RESET"
    printf " Fase         : %s\n\n" "$PH"

    printf " Entrada      : %s\n" "$VIDEO_INPUT"
    printf " Salida       : %s\n" "$VIDEO_RESTORED"
    printf " Entrada host : %s\n" "${INPUT_DIR:-No detectada}"
    printf " Salida host  : %s\n" "${OUTPUT_DIR:-No detectada}"
    printf " Tamaño salida: %s\n" "$SIZE"
    printf " Escala       : x%s\n" "${SCALE:-?}"
    printf " GPU config   : %s\n" "${GPU_DEVICE:-?}"
    printf " Vulkan       : %s\n\n" "$VK"

    echo "------------------------- PROGRESO --------------------------"
    echo
    printf " Progreso     : "; bar "$PCT" 40; printf "  %6.2f %%\n" "$PCT"
    printf " Vídeo        : %s / %s\n" "$(hms "$DONE")" "$(hms "$TOTAL")"
    printf " Transcurrido : %s\n" "$(hms "$EL")"
    printf " Velocidad    : %sx\n" "$SPEED"
    printf " Restante     : %s\n" "$ETA_TXT"
    printf " Fin estimado : %s\n\n" "$END_TXT"

    echo "--------------------------- GPU ------------------------------"
    printf " GPU          : %s\n" "$GN"
    printf " Proceso      : %s\n" "$GPT"
    printf " Uso Video2X  : "; bar "$GU" 30; printf "  %5.1f %%\n" "$GU"
    printf " VRAM Video2X : %s / %s MiB\n" "$GMU" "$GMT"
    printf " Temp. GPU    : %s °C  (global)\n" "$GT"
    printf " Potencia GPU : %s W   (global)\n\n" "$GP"

    echo "--------------------------- CPU ------------------------------"
    printf " Uso CPU      : "; bar "$CP" 30; printf "  %5.1f %%\n" "$CP"
    printf " Hilos usados : %s / %s\n" "$USED" "$THREADS"
    printf " Procesador   : %s cores / %s hilos\n" "$CORES" "$THREADS"
    printf " Docker CPU   : %s\n\n" "$CPU"

    echo "------------------------- DOCKER -----------------------------"
    printf " Uso RAM      : "; bar "$RPN" 30; printf "  %5.1f %%\n" "$RPN"
    printf " RAM          : %s\n" "$RAM"
    printf " Disco I/O    : %s\n\n" "$BIO"
    echo "--------------------------------------------------------------"

    if [[ "$STATE" == exited && "$EXIT" == 0 ]]; then
        echo " ✓ PROCESO COMPLETADO CORRECTAMENTE · 100,00 %"
    elif [[ "$STATE" == exited ]]; then
        echo " ✗ Video2X terminó con código $EXIT"
        docker logs --tail 6 "$CONTAINER" 2>&1 | sed 's/^/   /'
    else
        echo " Progreso cada ${PROBE_INTERVAL}s · recursos cada ${REFRESH}s · Ctrl+C cierra solo el monitor"
    fi

    sleep "$REFRESH"
done
