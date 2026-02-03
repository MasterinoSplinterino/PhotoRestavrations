# Photo Restoration Service

Сервис пакетной реставрации старых фотографий на базе [Microsoft Bringing-Old-Photos-Back-to-Life](https://github.com/microsoft/Bringing-Old-Photos-Back-to-Life) (CVPR 2020).

## Возможности

- Удаление царапин и дефектов
- Восстановление цветов
- Улучшение лиц
- Пакетная обработка папки с фотографиями
- GPU-ускорение (CUDA)

## Требования

- Docker с поддержкой NVIDIA GPU
- nvidia-container-toolkit
- GPU с поддержкой CUDA (Tesla V100, RTX и т.д.)

## Быстрый старт

### 1. Сборка образа

```bash
docker-compose build
```

### 2. Подготовка данных

```bash
mkdir -p input output
# Скопируйте фотографии в папку input/
cp /path/to/old/photos/*.jpg ./input/
```

### 3. Запуск обработки

```bash
# Режим без царапин (быстрый)
docker-compose up

# Режим с удалением царапин
PROCESSING_MODE=scratch docker-compose up

# Режим HR + царапины (максимальное качество)
PROCESSING_MODE=scratch_hr docker-compose up
```

## Режимы обработки

| Режим | Переменная | Описание |
|-------|-----------|----------|
| Стандартный | `PROCESSING_MODE=normal` | Улучшение качества без удаления царапин |
| С царапинами | `PROCESSING_MODE=scratch` | Удаление царапин + улучшение |
| HR + царапины | `PROCESSING_MODE=scratch_hr` | Высокое разрешение + удаление царапин |

## Конфигурация

### Переменные окружения

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `PROCESSING_MODE` | `normal` | Режим обработки |
| `INPUT_DIR` | `/data/input` | Путь к входным файлам |
| `OUTPUT_DIR` | `/data/output` | Путь для результатов |
| `GPU_ID` | `0` | ID GPU для использования |
| `WATCH_MODE` | `false` | Режим наблюдения за папкой |
| `WATCH_INTERVAL` | `10` | Интервал проверки (сек) |

### Watch Mode

Для постоянной работы сервиса с автоматической обработкой новых файлов:

```yaml
environment:
  - WATCH_MODE=true
  - WATCH_INTERVAL=30
  - PROCESSING_MODE=scratch
restart: always
```

## Деплой в Dokploy

### 1. Создание сервиса

1. В Dokploy создайте новый **Docker Compose** сервис
2. Загрузите содержимое `docker-compose.yml`
3. Включите GPU passthrough в настройках сервиса

### 2. Настройка volumes

Убедитесь, что volumes примонтированы к постоянному хранилищу:

```yaml
volumes:
  - /path/on/host/input:/data/input
  - /path/on/host/output:/data/output
```

### 3. Проверка GPU

```bash
# Внутри контейнера
docker exec -it photo-restoration python -c "import torch; print(torch.cuda.get_device_name(0))"
```

## Структура результатов

```
output/
└── final_output/
    ├── photo1_restored.png
    ├── photo2_restored.png
    └── ...
```

## Ручной запуск

Можно передать аргументы напрямую в `run.py`:

```bash
docker run --gpus all -v $(pwd)/input:/data/input -v $(pwd)/output:/data/output \
  photo-restoration \
  --input_folder /data/input \
  --output_folder /data/output \
  --GPU 0 \
  --with_scratch
```

## Troubleshooting

### GPU не обнаружена

```bash
# Проверьте nvidia-container-toolkit
nvidia-smi
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
```

### Ошибка памяти

Для режима HR требуется много VRAM. Уменьшите размер изображений или используйте режим `scratch` вместо `scratch_hr`.

### Контейнер сразу завершается

Убедитесь, что в папке `input/` есть изображения форматов: `.jpg`, `.jpeg`, `.png`, `.bmp`

## Лицензия

Код обёртки — MIT. Модель Microsoft — [MIT License](https://github.com/microsoft/Bringing-Old-Photos-Back-to-Life/blob/master/LICENSE).
