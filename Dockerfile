# Build argument for base image selection
ARG BASE_IMAGE=nvidia/cuda:13.0.2-cudnn-runtime-ubuntu24.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

# Build arguments for this stage with sensible defaults for standalone builds
ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY


# Architecture for RTX 5090 / B200 (SM120)
ENV TORCH_CUDA_ARCH_LIST="12.0"

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=16

# NVIDIA runtime environment
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Ensure ComfyUI's own subpackages (comfy_aimdo, etc.) are importable
ENV PYTHONPATH="/comfyui:${PYTHONPATH}"


# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
	python3.12-dev \
    git \
    wget \
	curl \
	build-essential \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# Install uv (latest) using official installer and create isolated venvv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv --python 3.12

# Use the virtual environment for all subsequent commands
ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
RUN uv pip install comfy-cli pip setuptools wheel

# Install ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi
	
# Completely remove any PyTorch/Triton installed by ComfyUI (to avoid version conflicts)
RUN uv pip uninstall -y torch torchvision torchaudio triton pytorch-triton torchao || true

# Nuclear cache cleanup (to avoid conflicting Pytorch / Triton with the installation that will follow after this code)
RUN uv cache clean && \
    rm -rf /root/.cache/pip \
           /root/.cache/uv \
           /root/.cache/torch \
           /root/.cache/torchvision \
           /root/.cache/torchaudio \
           /root/.triton \
           /root/.torch \
           /tmp/* && \
    find /opt/venv -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Force reinstall comfy-kitchen with CUBLAS support for NVFP4 optimizations
RUN uv pip install --no-cache-dir --force-reinstall "comfy-kitchen[cublas]"
	
# Fresh install of PyTorch 2.10.0 WITH EXPLICIT CU130 BUILD
RUN uv pip install --no-cache-dir \
    torch==2.10.0+cu130 \
    torchvision==0.25.0+cu130 \
    torchaudio==2.10.0+cu130 \
    --index-url https://download.pytorch.org/whl/cu130
	
# Fresh install of Triton 3.6.0
RUN uv pip install --no-cache-dir triton==3.6.0

# Install SageAttention
RUN wget -q -O /tmp/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl \
    "https://github.com/palechinchilla/SageAttention-2.2.0-Blackwell-/raw/refs/heads/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl" && \
    uv pip install --no-cache-dir /tmp/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl && \
    rm /tmp/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl

# Change working directory to ComfyUI
WORKDIR /comfyui


# Support for the network volume
ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Install custom nodes - KJNodes (SageAttention wrapper)
RUN git clone https://github.com/kijai/ComfyUI-KJNodes.git /comfyui/custom_nodes/ComfyUI-KJNodes \
    && cd /comfyui/custom_nodes/ComfyUI-KJNodes \
    && if [ -f requirements.txt ]; then uv pip install -r requirements.txt; fi

# Install ComfyUI-WanVideoWrapper
RUN git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git /comfyui/custom_nodes/ComfyUI-WanVideoWrapper \
    && cd /comfyui/custom_nodes/ComfyUI-WanVideoWrapper \
    && if [ -f requirements.txt ]; then uv pip install -r requirements.txt; fi

# Install ComfyUI-Custom-Scripts
RUN git clone https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git /comfyui/custom_nodes/ComfyUI-Custom-Scripts \
    && cd /comfyui/custom_nodes/ComfyUI-Custom-Scripts \
    && if [ -f requirements.txt ]; then uv pip install -r requirements.txt; fi

# Install ComfyUI-Easy-Use
RUN git clone https://github.com/yolain/ComfyUI-Easy-Use.git /comfyui/custom_nodes/ComfyUI-Easy-Use \
    && cd /comfyui/custom_nodes/ComfyUI-Easy-Use \
    && if [ -f requirements.txt ]; then uv pip install -r requirements.txt; fi

# Install ComfyUI-Frame-Interpolation
RUN git clone https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git /comfyui/custom_nodes/ComfyUI-Frame-Interpolation \
    && cd /comfyui/custom_nodes/ComfyUI-Frame-Interpolation \
    && if [ -f requirements.txt ]; then uv pip install -r requirements.txt; fi \
    && mkdir -p /comfyui/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife \
    && wget -O /comfyui/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife47.pth \
        https://huggingface.co/wavespeed/misc/resolve/main/rife/rife47.pth



# Install alembic (required by ComfyUI for its local SQLite database)
RUN uv pip install --no-cache-dir alembic

# Install ComfyUI as a proper Python package so internal modules like
# comfy_aimdo are importable when main.py runs (added in recent ComfyUI versions)
RUN uv pip install --no-cache-dir -e /comfyui

# Install Python runtime dependencies for the handler
RUN uv pip install runpod requests websocket-client

# Add application code and scripts
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

# Add script to install custom nodes
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
ENV PIP_NO_INPUT=1

# Copy helper script to switch Manager network mode at container start
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

# Set the default command to run when starting the container
CMD ["/start.sh"]


# Change working directory to ComfyUI
WORKDIR /comfyui

# Create necessary directories upfront
RUN mkdir -p models/checkpoints models/vae models/unet models/clip models/text_encoders models/diffusion_models models/model_patches models/loras models/latent_upscale_models models/upscale_models

# Download model files
RUN wget -q -O models/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors && \
    wget -q -O models/latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.1.safetensors https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.1.safetensors