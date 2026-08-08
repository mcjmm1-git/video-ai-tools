#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/juanma/video-restoration"
cd "$PROJECT_DIR"

clear
echo "==============================================="
echo "         VIDEO RESTORATION - MENU"
echo "==============================================="
echo
echo "  1) Restaurar imagen (Video2X)"
echo "  2) Aumentar volumen"
echo "  3) Normalizar volumen"
echo
read -r -p "Elige una opción [1]: " OPCION
OPCION="${OPCION:-1}"

echo

case "$OPCION" in
    1)
        echo "Arrancando restauración con Video2X..."
        docker compose up -d --force-recreate video2x

        echo "Reiniciando monitor web..."
        sudo systemctl restart video2x-monitor

        echo
        echo "Video2X arrancado."
        echo "Monitor: http://192.168.1.48:9003"
        echo
        docker inspect -f 'Estado={{.State.Status}}  Código={{.State.ExitCode}}' video2x
        ;;

    2)
        echo "Arrancando aumento de volumen..."
        docker compose up -d --force-recreate subir-volumen
        echo
        docker inspect -f 'Estado={{.State.Status}}  Código={{.State.ExitCode}}' subir-volumen
        ;;

    3)
        echo "Arrancando normalización de volumen..."
        docker compose up -d --force-recreate normalizar-audio
        echo
        docker inspect -f 'Estado={{.State.Status}}  Código={{.State.ExitCode}}' normalizar-audio
        ;;

    *)
        echo "Opción no válida: $OPCION"
        echo "Usa 1, 2 o 3."
        exit 1
        ;;
esac
