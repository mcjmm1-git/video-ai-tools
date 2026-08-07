# video-ai-tools

Docker-based workflow for **AI video restoration and colorization** with NVIDIA GPUs.

This repository packages a workflow tested with an **NVIDIA GeForce RTX 3060 12 GB**:

1. **Video2X + Real-ESRGAN** for restoration/upscaling.
2. **DDColor** to generate color reference frames.
3. **CMNET2** to propagate color with better temporal consistency.
4. Terminal/web monitors for progress, GPU, CPU and RAM usage.

The repository contains scripts and configuration only. **Movies, generated videos, model weights, caches and local `.env` files are intentionally excluded.**

## Layout

```text
video-ai-tools/
├── restoration/
│   ├── compose.yaml
│   ├── .env.example
│   ├── monitor-video2x.sh
│   ├── input/
│   └── output/
└── colorization/
    ├── compose.yaml
    ├── Dockerfile
    ├── .env.example
    ├── make_refs.py
    ├── pipeline.sh
    ├── monitor.sh
    ├── input/
    ├── output/
    ├── models/
    ├── cache/
    └── work/
```

## Requirements

- Linux with Docker Engine and Docker Compose v2.
- NVIDIA GPU with a working host driver.
- NVIDIA Container Toolkit configured for Docker.
- `nvidia-smi` available on the host for monitor metrics.
- `ttyd` is optional, only needed for browser-based monitors.

The colorization Dockerfile defaults to CUDA Compute Capability `8.6`, which matches the RTX 3060 used during testing. For another GPU, set `TORCH_CUDA_ARCH_LIST` appropriately in `colorization/.env` before building.

## 1. Restoration / upscaling

```bash
cd restoration
cp .env.example .env
```

Put the source video in `restoration/input/` and edit `.env`.

Start Video2X:

```bash
docker compose up -d --force-recreate video2x
```

Follow logs:

```bash
docker compose logs -f video2x
```

Run the terminal monitor:

```bash
./monitor-video2x.sh
```

The monitor intentionally forces **100.00% when the container exits successfully with code 0**, even if the last periodic `ffprobe` sample was still at 99.x%.

### Optional audio helpers

Increase volume:

```bash
docker compose up -d --force-recreate subir-volumen
```

Normalize loudness:

```bash
docker compose up -d --force-recreate normalizar-audio
```

## 2. Colorization with DDColor + CMNET2

Copy the restored video into `colorization/input/`, then:

```bash
cd colorization
cp .env.example .env
docker compose build
```

### Test first

The example `.env` starts with a 20-second test:

```env
TEST_START=00:10:00
TEST_DURATION=20
```

Run it:

```bash
docker compose up -d --force-recreate colorizar
docker compose logs -f colorizar
```

When the result looks good, switch to the complete film:

```env
TEST_START=00:00:00
TEST_DURATION=0
```

Then run the service again.

### What the colorization pipeline does

The pipeline performs four stages:

1. Decode the input and create reference frames every `REF_EVERY` seconds.
2. Colorize those references with DDColor.
3. Use CMNET2 to propagate/stabilize color across the complete sequence.
4. Mux the original audio/subtitle streams into the final file.

CMNET2 model files are downloaded on first use into `colorization/models/` and are not committed to Git.

## Monitors

Both monitors use solid ANSI cyan bars compatible with `ttyd` and display:

- process progress;
- GPU utilization and VRAM;
- GPU temperature and power;
- Docker CPU usage normalized against all logical CPUs (`nproc`);
- logical CPUs in use and physical core/thread count;
- Docker RAM usage and percentage;
- disk I/O.

The Video2X monitor filters GPU process activity to the Video2X container where possible, so another GPU workload does not make Video2X appear active after it has finished. GPU temperature and board power remain global device metrics.

### Optional browser monitor with ttyd

Example for restoration:

```bash
ttyd -W -p 9003 ./monitor-video2x.sh
```

Example for colorization:

```bash
ttyd -W -p 9004 ./monitor.sh
```

For permanent services, create systemd units pointing `ttyd` to these scripts and your chosen ports.

## Notes

- Do not run restoration and colorization simultaneously on the same GPU unless you intentionally want them to compete for GPU resources.
- The first CMNET2 run downloads several model files and may take longer to start.
- `spatial-correlation-sampler` is compiled inside the colorization image. The Dockerfile uses a CUDA **devel** image and disables pip build isolation for that package so it compiles against the same PyTorch/CUDA environment.
- Test a short segment before committing to a full-length film.

## Upstream projects

This project orchestrates existing open-source tools; it does not vendor their source code or model weights:

- Video2X: https://github.com/k4yt3x/video2x
- DDColor: https://github.com/piddnad/DDColor
- CMNET2: https://github.com/dan64/cmnet2

Please consult each upstream project for its own license, model terms and attribution requirements.

## Status

The workflow has been tested end-to-end on Ubuntu/Linux with an NVIDIA RTX 3060 12 GB, including a feature-length video. Hardware, driver and dependency combinations may require adjustments on other systems.
