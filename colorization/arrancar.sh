#!/usr/bin/env bash
set -e

cd /home/juanma/video-colorization

echo "Arrancando colorización..."
docker compose up -d --force-recreate colorizar

echo "Reiniciando monitor web..."
sudo systemctl restart video-colorization-monitor

echo
echo "Colorización arrancada."
echo "Monitor: http://192.168.1.48:9004"
echo
echo "Estado del contenedor:"
docker inspect -f 'Estado={{.State.Status}}  Código={{.State.ExitCode}}' video-colorizer
