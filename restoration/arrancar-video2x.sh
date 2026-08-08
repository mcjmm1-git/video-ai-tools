#!/usr/bin/env bash
set -e

cd /home/juanma/video-restoration

echo "Arrancando Video2X..."
docker compose up -d --force-recreate video2x

echo "Reiniciando monitor web..."
sudo systemctl restart video2x-monitor

echo
echo "Video2X arrancado."
echo "Monitor: http://192.168.1.48:9003"
echo
echo "Estado del contenedor:"
docker inspect -f 'Estado={{.State.Status}}  Código={{.State.ExitCode}}' video2x
