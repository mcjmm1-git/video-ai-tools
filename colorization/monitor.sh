#!/usr/bin/env bash
export LC_NUMERIC=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$DIR}"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
CONTAINER="${CONTAINER:-video-colorizer}"
REFRESH="${REFRESH:-2}"
LOG_TAIL="${LOG_TAIL:-5000}"
BG=$'\e[46m'; RESET=$'\e[0m'

EXPECTED_REFS=0
DURATION_SEC=0
CMNET_TOTAL=0
CMNET_FPS=""
CMNET_FULL_SCAN_DONE=0

get_env(){
  local k="$1" d="${2:-}" l v
  l=$(grep -E "^[[:space:]]*${k}=" "$ENV_FILE" 2>/dev/null | tail -1 || true)
  [[ -z "$l" ]] && { printf '%s' "$d"; return; }
  v="${l#*=}"; v="${v%$'\r'}"
  case "$v" in \"*\") v="${v:1:-1}";; \'*\') v="${v:1:-1}";; esac
  printf '%s' "$v"
}

hms(){
  local s
  s=$(awk -v x="${1:-0}" 'BEGIN{printf "%d",x+0}')
  ((s<0)) && s=0
  printf '%02d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

bar(){
  local p="${1:-0}" w="${2:-30}" f e
  f=$(awk -v p="$p" -v w="$w" 'BEGIN{if(p<0)p=0;if(p>100)p=100;printf "%d",p*w/100+0.5}')
  e=$((w-f)); printf '['
  ((f>0)) && printf "%s%${f}s%s" "$BG" '' "$RESET"
  ((e>0)) && printf "%${e}s" ''
  printf ']'
}

count_refs(){
  [[ -d "$1" ]] && find "$1" -maxdepth 1 -type f -name 'ref_*.png' 2>/dev/null | wc -l || echo 0
}

mount_source(){
  local dest="$1" fallback="$2" src
  src=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$dest\"}}{{.Source}}{{end}}{{end}}" "$CONTAINER" 2>/dev/null || true)
  [[ -n "$src" ]] && printf '%s' "$src" || printf '%s' "$fallback"
}

detect_phase(){
  local args="$1" logs="$2" p
  if [[ "$STATE" == running ]]; then
    grep -qE '(^|[ /])make_refs\.py([[:space:]]|$)' <<<"$args" && { echo 1; return; }
    grep -qE 'scripts/infer\.py|/opt/DDColor' <<<"$args" && { echo 2; return; }
    grep -qE 'test_video_full\.py|/opt/cmnet2' <<<"$args" && { echo 3; return; }
    grep -qE '(^|[ /])ffmpeg([[:space:]]|$)' <<<"$args" && { echo 4; return; }
  fi
  p=$(awk '/=== 1\/4/{p=1}/=== 2\/4/{p=2}/=== 3\/4/{p=3}/=== 4\/4/{p=4}/TERMINADO/{p=5}END{print p+0}' <<<"$logs")
  echo "$p"
}

cleanup(){ printf '\e[?25h\e[0m\n'; }
trap cleanup INT TERM EXIT
printf '\e[?25l'

THREADS=$(nproc 2>/dev/null || echo 1)
[[ "$THREADS" =~ ^[0-9]+$ ]] || THREADS=1
CORES=$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l | tr -d ' ')
[[ "$CORES" =~ ^[0-9]+$ ]] || CORES='?'

while true; do
  INPUT=$(get_env COLOR_INPUT desconocido)
  OUTPUT=$(get_env COLOR_OUTPUT desconocido)
  TEST=$(get_env TEST_DURATION 0)
  EVERY=$(get_env REF_EVERY 2)

  STATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo no-creado)
  EXIT=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || echo -)
  RAW=$(docker logs --tail "$LOG_TAIL" "$CONTAINER" 2>&1 || true)
  LOGS=$(printf '%s' "$RAW" | tr '\r' '\n')
  ARGS=$(docker top "$CONTAINER" -eo args 2>/dev/null | tail -n +2 || true)
  PHASE=$(detect_phase "$ARGS" "$LOGS")

  WORK_DIR=$(mount_source /work "$PROJECT_DIR/work")
  OUTPUT_DIR=$(mount_source /output "$PROJECT_DIR/output")
  BW=$(count_refs "$WORK_DIR/refs-bw")
  COL=$(count_refs "$WORK_DIR/refs-color")

  START=$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null || true)
  FIN=$(docker inspect -f '{{.State.FinishedAt}}' "$CONTAINER" 2>/dev/null || true)
  SE=$(date -d "$START" +%s 2>/dev/null || echo 0); EE=$(date +%s)
  [[ "$STATE" == exited && "$FIN" != 0001-01-01T00:00:00Z ]] && EE=$(date -d "$FIN" +%s 2>/dev/null || echo "$EE")
  ((SE>0)) && EL=$((EE-SE)) || EL=0

  if ((PHASE>=2 && EXPECTED_REFS==0 && BW>0)); then EXPECTED_REFS=$BW; fi
  if ((EXPECTED_REFS==0)); then
    RGT=$(grep -oE 'Referencias generadas: [0-9]+' <<<"$LOGS" | tail -1 | awk '{print $3}')
    [[ "$RGT" =~ ^[0-9]+$ ]] && ((RGT>0)) && EXPECTED_REFS=$RGT
  fi
  if ((EXPECTED_REFS==0)); then
    TF=$(grep -oE 'Fotogramas: [0-9]+' <<<"$LOGS" | tail -1 | awk '{print $2}')
    SF=$(grep -oE 'Referencia cada [0-9.]+ s = [0-9]+ frames' <<<"$LOGS" | tail -1 | awk '{print $(NF-1)}')
    [[ "$TF" =~ ^[0-9]+$ && "$SF" =~ ^[0-9]+$ ]] && ((SF>0)) && EXPECTED_REFS=$(((TF+SF-1)/SF))
  fi
  if ((EXPECTED_REFS==0)); then
    if [[ "$TEST" != 0 && "$TEST" =~ ^[0-9]+([.][0-9]+)?$ ]]; then DURATION_SEC=$TEST
    elif [[ "$STATE" == running ]]; then
      DURATION_SEC=$(docker exec "$CONTAINER" ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "/input/$INPUT" 2>/dev/null | head -1 || true)
    fi
    [[ "$DURATION_SEC" =~ ^[0-9]+([.][0-9]+)?$ ]] && EXPECTED_REFS=$(awk -v d="$DURATION_SEC" -v r="$EVERY" 'BEGIN{if(r>0)printf "%d",int(d/r)+1;else print 0}')
  fi

  if ((CMNET_TOTAL==0)); then
    CMNET_TOTAL=$(grep -oE 'Saving [0-9]+ color frames' <<<"$LOGS" | tail -1 | grep -oE '[0-9]+' || true)
    [[ "$CMNET_TOTAL" =~ ^[0-9]+$ ]] || CMNET_TOTAL=0
  fi
  if [[ -z "$CMNET_FPS" ]]; then
    CMNET_FPS=$(grep -oE 'Estimated FPS[[:space:]]*:[[:space:]]*[0-9.]+' <<<"$LOGS" | tail -1 | grep -oE '[0-9.]+$' || true)
    [[ "$CMNET_FPS" =~ ^[0-9]+([.][0-9]+)?$ ]] || CMNET_FPS=''
  fi
  if ((PHASE==3 && CMNET_TOTAL==0 && CMNET_FULL_SCAN_DONE==0)); then
    META=$(docker logs "$CONTAINER" 2>&1 | tr '\r' '\n' | grep -E 'Saving [0-9]+ color frames|Estimated FPS' || true)
    CMNET_TOTAL=$(grep -oE 'Saving [0-9]+ color frames' <<<"$META" | tail -1 | grep -oE '[0-9]+' || true)
    [[ "$CMNET_TOTAL" =~ ^[0-9]+$ ]] || CMNET_TOTAL=0
    CMNET_FPS=$(grep -oE 'Estimated FPS[[:space:]]*:[[:space:]]*[0-9.]+' <<<"$META" | tail -1 | grep -oE '[0-9.]+$' || true)
    [[ "$CMNET_FPS" =~ ^[0-9]+([.][0-9]+)?$ ]] || CMNET_FPS=''
    CMNET_FULL_SCAN_DONE=1
  fi

  STAGE='Iniciando'; PCT='0.00'; TOTAL='0.00'; DETAIL=''; FN=0; FT=0
  case "$PHASE" in
    1)
      STAGE='Generando referencias'
      if ((EXPECTED_REFS>0)); then
        PCT=$(awk -v a="$BW" -v b="$EXPECTED_REFS" 'BEGIN{p=a*100/b;if(p>100)p=100;printf "%.2f",p}')
        TOTAL=$(awk -v p="$PCT" 'BEGIN{printf "%.2f",p*.05}')
        DETAIL="$BW / $EXPECTED_REFS referencias"
      else DETAIL="$BW referencias generadas"; fi
      ;;
    2)
      STAGE='DDColor · coloreando referencias'
      if ((EXPECTED_REFS>0)); then
        PCT=$(awk -v a="$COL" -v b="$EXPECTED_REFS" 'BEGIN{p=a*100/b;if(p>100)p=100;printf "%.2f",p}')
        TOTAL=$(awk -v p="$PCT" 'BEGIN{printf "%.2f",5+p*.05}')
        DETAIL="$COL / $EXPECTED_REFS referencias"
      else TOTAL='5.00'; DETAIL="$COL referencias coloreadas"; fi
      ;;
    3)
      STAGE='CMNET2 · estabilizando color'
      if ((CMNET_TOTAL>0)); then
        PAIR=$(grep -oE '[0-9]+/[0-9]+' <<<"$LOGS" | awk -F/ -v t="$CMNET_TOTAL" '$2==t{last=$0}END{print last}' || true)
        if [[ "$PAIR" =~ ^([0-9]+)/([0-9]+)$ ]]; then FN=${BASH_REMATCH[1]}; FT=${BASH_REMATCH[2]}; else FT=$CMNET_TOTAL; fi
        PCT=$(awk -v a="$FN" -v b="$FT" 'BEGIN{if(b>0)p=a*100/b;else p=0;if(p>100)p=100;printf "%.2f",p}')
        TOTAL=$(awk -v p="$PCT" 'BEGIN{printf "%.2f",10+p*.89}')
        DETAIL="$FN / $FT frames"
      else TOTAL='10.00'; DETAIL='Preparando modelo / esperando contador CMNET2...'; fi
      ;;
    4) STAGE='Añadiendo audio y subtítulos'; PCT='100.00'; TOTAL='99.90'; DETAIL='Finalizando MKV' ;;
    5) STAGE='Finalizado'; PCT='100.00'; TOTAL='100.00'; DETAIL='Proceso completado' ;;
    *) DETAIL='Esperando detección de fase...' ;;
  esac

  if [[ "$STATE" == exited && "$EXIT" == 0 ]]; then PHASE=5; STAGE='Finalizado'; PCT='100.00'; TOTAL='100.00'; DETAIL='Proceso completado'; fi

  ETA_TXT='--:--:--'; END_TXT='--:--'
  if ((PHASE==3)) && [[ "$FN" =~ ^[0-9]+$ && "$FT" =~ ^[0-9]+$ && "$CMNET_FPS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    ETA=$(awk -v a="$FN" -v b="$FT" -v f="$CMNET_FPS" 'BEGIN{r=b-a;if(r<0)r=0;if(f>0)printf "%d",r/f;else print 0}')
    ETA_TXT=$(hms "$ETA"); END_TXT=$(date -d "+$ETA seconds" +%H:%M 2>/dev/null || echo --:--)
  elif awk -v p="$TOTAL" 'BEGIN{exit !(p>0&&p<100)}'; then
    ETA=$(awk -v e="$EL" -v p="$TOTAL" 'BEGIN{printf "%d",e*(100-p)/p}')
    ETA_TXT=$(hms "$ETA"); END_TXT=$(date -d "+$ETA seconds" +%H:%M 2>/dev/null || echo --:--)
  elif [[ "$TOTAL" == 100.00 ]]; then ETA_TXT='00:00:00'; END_TXT='terminado'; fi

  GL=$(nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1)
  GN='-'; GU=0; GM='-'; GT='-'; GP='-'
  if [[ -n "$GL" ]]; then
    IFS=',' read -r GN GU GUM GMT GT GP <<<"$GL"
    GN=$(xargs<<<"$GN"); GU=$(xargs<<<"$GU"); GUM=$(xargs<<<"$GUM"); GMT=$(xargs<<<"$GMT"); GT=$(xargs<<<"$GT"); GP=$(xargs<<<"$GP"); GM="$GUM / $GMT MiB"
  fi
  [[ "$GU" =~ ^[0-9]+([.][0-9]+)?$ ]] || GU=0

  CPU='0 %'; RAM='0 B'; RP='0 %'; BIO='-'
  if [[ "$STATE" == running ]]; then
    S=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.BlockIO}}' "$CONTAINER" 2>/dev/null || true)
    [[ -n "$S" ]] && IFS='|' read -r CPU RAM RP BIO <<<"$S"
  fi
  CN=$(tr -d ' %' <<<"$CPU"); RPN=$(tr -d ' %' <<<"$RP")
  [[ "$CN" =~ ^[0-9]+([.][0-9]+)?$ ]] || CN=0; [[ "$RPN" =~ ^[0-9]+([.][0-9]+)?$ ]] || RPN=0
  USED=$(awk -v c="$CN" 'BEGIN{printf "%.1f",c/100}')
  CP=$(awk -v c="$CN" -v n="$THREADS" 'BEGIN{p=c/n;if(p>100)p=100;printf "%.1f",p}')

  SIZE='todavía no creado'; [[ -f "$OUTPUT_DIR/$OUTPUT" ]] && SIZE=$(du -h "$OUTPUT_DIR/$OUTPUT" 2>/dev/null | awk '{print $1}')

  printf '\e[H\e[2J'
  echo '=============================================================='
  echo '              MONITOR DDColor + CMNET2'
  echo '=============================================================='
  echo
  if [[ "$STATE" == running ]]; then STATUS='● Procesando'; elif [[ "$STATE" == exited && "$EXIT" == 0 ]]; then STATUS='● Finalizado · código 0'; elif [[ "$STATE" == exited ]]; then STATUS="● ERROR · código $EXIT"; else STATUS="● $STATE"; fi
  printf " Estado       : %s\n Fase         : %s\n\n Entrada      : %s\n Salida       : %s\n Tamaño salida: %s\n\n" "$STATUS" "$STAGE" "$INPUT" "$OUTPUT" "$SIZE"
  echo '------------------------ PROGRESO ----------------------------'; echo
  printf ' Fase actual  : '; bar "$PCT" 40; printf '  %6.2f %%\n' "$PCT"; [[ -n "$DETAIL" ]] && printf '               %s\n' "$DETAIL"
  ((PHASE==3)) && [[ -n "$CMNET_FPS" ]] && printf ' CMNET2       : %s FPS estimados\n' "$CMNET_FPS"
  echo; printf ' Total aprox. : '; bar "$TOTAL" 40; printf '  %6.2f %%\n\n' "$TOTAL"
  printf " Transcurrido : %s\n ETA aprox.   : %s\n Fin estimado : %s\n\n" "$(hms "$EL")" "$ETA_TXT" "$END_TXT"
  echo '--------------------------- GPU ------------------------------'; printf " GPU          : %s\n Uso GPU      : " "$GN"; bar "$GU" 30; printf '  %5.1f %%\n' "$GU"; printf " VRAM         : %s\n Temperatura  : %s °C\n Potencia     : %s W\n\n" "$GM" "$GT" "$GP"
  echo '--------------------------- CPU ------------------------------'; printf ' Uso CPU      : '; bar "$CP" 30; printf '  %5.1f %%\n' "$CP"; printf " Hilos usados : %s / %s\n Procesador   : %s cores / %s hilos\n Docker CPU   : %s\n\n" "$USED" "$THREADS" "$CORES" "$THREADS" "$CPU"
  echo '------------------------- DOCKER -----------------------------'; printf ' Uso RAM      : '; bar "$RPN" 30; printf '  %5.1f %%\n' "$RPN"; printf " RAM          : %s\n Disco I/O    : %s\n\n--------------------------------------------------------------\n" "$RAM" "$BIO"
  if [[ "$STATE" == exited && "$EXIT" != 0 ]]; then echo ' Últimas líneas del error:'; docker logs --tail 8 "$CONTAINER" 2>&1
  elif [[ "$STATE" == exited && "$EXIT" == 0 ]]; then echo ' ✓ PROCESO COMPLETADO CORRECTAMENTE · 100,00 %'
  else echo " Actualización cada ${REFRESH}s · Ctrl+C cierra solo el monitor"; fi
  sleep "$REFRESH"
done
