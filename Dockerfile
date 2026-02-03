# Dockerfile для Microsoft Bringing-Old-Photos-Back-to-Life
# Обновлённая версия с CUDA 11.8 для совместимости с современными GPU

FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04

# Отключаем интерактивный режим для apt
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Устанавливаем системные зависимости
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    wget \
    curl \
    bzip2 \
    unzip \
    zip \
    cmake \
    build-essential \
    python3 \
    python3-pip \
    python3-dev \
    python-is-python3 \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgtk2.0-dev \
    libboost-all-dev \
    # Для монтирования SMB
    cifs-utils \
    && rm -rf /var/lib/apt/lists/*

# Обновляем pip
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel

# Устанавливаем PyTorch с CUDA 11.8
RUN pip3 install --no-cache-dir \
    torch==2.0.1+cu118 \
    torchvision==0.15.2+cu118 \
    --extra-index-url https://download.pytorch.org/whl/cu118

# Устанавливаем dlib (требует cmake и boost)
RUN pip3 install --no-cache-dir dlib

# Устанавливаем остальные Python зависимости
RUN pip3 install --no-cache-dir \
    numpy \
    scikit-image \
    easydict \
    PyYAML \
    "dominate>=2.3.1" \
    dill \
    tensorboardX \
    scipy \
    opencv-python-headless \
    einops \
    matplotlib \
    Pillow

# Создаём рабочую директорию
WORKDIR /app

# Клонируем репозиторий
RUN git clone https://github.com/microsoft/Bringing-Old-Photos-Back-to-Life.git . \
    && git checkout master

# Скачиваем Synchronized-BatchNorm-PyTorch
RUN git clone https://github.com/vacancy/Synchronized-BatchNorm-PyTorch.git \
    && cp -r Synchronized-BatchNorm-PyTorch/sync_batchnorm Face_Enhancement/models/networks/ \
    && cp -r Synchronized-BatchNorm-PyTorch/sync_batchnorm Global/detection_models/ \
    && rm -rf Synchronized-BatchNorm-PyTorch

# Скачиваем модель детектора лиц dlib
RUN cd Face_Detection/shape_predictor && \
    wget -q http://dlib.net/files/shape_predictor_68_face_landmarks.dat.bz2 && \
    bzip2 -d shape_predictor_68_face_landmarks.dat.bz2

# Скачиваем чекпоинты Face_Enhancement
RUN cd Face_Enhancement && \
    wget -q https://github.com/microsoft/Bringing-Old-Photos-Back-to-Life/releases/download/v1.0/face_checkpoints.zip && \
    unzip -q face_checkpoints.zip && \
    rm face_checkpoints.zip

# Скачиваем чекпоинты Global
RUN cd Global && \
    wget -q https://github.com/microsoft/Bringing-Old-Photos-Back-to-Life/releases/download/v1.0/global_checkpoints.zip && \
    unzip -q global_checkpoints.zip && \
    rm global_checkpoints.zip

# Скачиваем чекпоинты для детекции царапин (опционально, но нужно для --with_scratch)
RUN cd Global && \
    wget -q https://github.com/microsoft/Bringing-Old-Photos-Back-to-Life/releases/download/v1.0/detection_checkpoints.zip && \
    unzip -q detection_checkpoints.zip && \
    rm detection_checkpoints.zip

# Создаём директории для input/output
RUN mkdir -p /data/input /data/output

# Копируем entrypoint скрипт
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Устанавливаем переменные окружения для CUDA
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Порт не нужен для batch processing, но можно добавить health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import torch; assert torch.cuda.is_available()" || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
