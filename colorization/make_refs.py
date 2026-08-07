#!/usr/bin/env python3

import argparse
import os
import cv2

parser = argparse.ArgumentParser()
parser.add_argument("--input", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--every", type=float, default=2.0)
args = parser.parse_args()

os.makedirs(args.output, exist_ok=True)

cap = cv2.VideoCapture(args.input)

if not cap.isOpened():
    raise RuntimeError(f"No puedo abrir {args.input}")

fps = cap.get(cv2.CAP_PROP_FPS)

if fps <= 0:
    raise RuntimeError("No se pudo determinar FPS")

total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
step = max(1, round(fps * args.every))

print(f"FPS: {fps:.3f}")
print(f"Fotogramas: {total}")
print(f"Referencia cada {args.every} s = {step} frames")

frame_num = 0
refs = 0

while True:
    ok, frame = cap.read()

    if not ok:
        break

    if frame_num % step == 0:
        name = f"ref_{frame_num:06d}.png"
        path = os.path.join(args.output, name)

        if not cv2.imwrite(path, frame):
            raise RuntimeError(f"Error escribiendo {path}")

        refs += 1

    frame_num += 1

cap.release()

print(f"Referencias generadas: {refs}")
