FROM pytorch/pytorch:2.2.0-cuda11.8-cudnn8-devel

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV CUDA_HOME=/usr/local/cuda
ARG TORCH_CUDA_ARCH_LIST=8.6
ENV TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST}

RUN apt-get update && apt-get install -y \
    ffmpeg \
    git \
    curl \
    unzip \
    ca-certificates \
    libgl1 \
    libglib2.0-0 \
    build-essential \
    python3-dev \
    ninja-build \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --no-build-isolation -v \
    numpy==1.24.3 \
    opencv-python-headless==4.7.0.72 \
    pillow \
    scikit-image \
    scipy \
    tqdm \
    huggingface-hub \
    pyyaml \
    einops

RUN pip install --no-cache-dir --no-build-isolation -v \
    spatial-correlation-sampler==0.5.0

RUN git clone --depth 1 \
    https://github.com/piddnad/DDColor.git \
    /opt/DDColor

RUN git clone --depth 1 \
    https://github.com/dan64/cmnet2.git \
    /opt/cmnet2

WORKDIR /app

COPY make_refs.py /app/make_refs.py
COPY pipeline.sh /app/pipeline.sh

RUN chmod +x /app/pipeline.sh
