#!/bin/bash
set -e

# =============================================================================
# Entrypoint скрипт для Photo Restoration сервиса
# Поддерживает три режима: normal, scratch, scratch_hr
# + Архивация и выгрузка на SMB
# =============================================================================

INPUT_DIR="${INPUT_DIR:-/data/input}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/output}"
GPU_ID="${GPU_ID:-0}"
PROCESSING_MODE="${PROCESSING_MODE:-normal}"
WATCH_MODE="${WATCH_MODE:-false}"
WATCH_INTERVAL="${WATCH_INTERVAL:-10}"

# SMB настройки
SMB_ENABLED="${SMB_ENABLED:-false}"
SMB_HOST="${SMB_HOST:-}"
SMB_SHARE="${SMB_SHARE:-}"
SMB_USER="${SMB_USER:-}"
SMB_PASSWORD="${SMB_PASSWORD:-}"
SMB_MOUNT="/mnt/smb"

# Архивация
ARCHIVE_ENABLED="${ARCHIVE_ENABLED:-true}"
ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-zip}"  # zip или tar.gz

# Путь к моделям (volume)
MODELS_DIR="${MODELS_DIR:-/data/models}"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Проверка GPU
check_gpu() {
    log_info "Проверка доступности GPU..."
    if python -c "import torch; assert torch.cuda.is_available(), 'CUDA not available'"; then
        GPU_NAME=$(python -c "import torch; print(torch.cuda.get_device_name(0))")
        GPU_MEM=$(python -c "import torch; print(f'{torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB')")
        log_info "GPU доступна: $GPU_NAME ($GPU_MEM)"
        return 0
    else
        log_error "GPU не обнаружена! Проверьте конфигурацию Docker."
        return 1
    fi
}

# Проверка входных файлов
check_input() {
    if [ ! -d "$INPUT_DIR" ]; then
        log_error "Директория $INPUT_DIR не существует!"
        return 1
    fi

    FILE_COUNT=$(find "$INPUT_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.bmp" \) | wc -l)

    if [ "$FILE_COUNT" -eq 0 ]; then
        log_warn "В $INPUT_DIR нет изображений для обработки"
        return 1
    fi

    log_info "Найдено $FILE_COUNT изображений для обработки"
    return 0
}

# Монтирование SMB
mount_smb() {
    if [ "$SMB_ENABLED" != "true" ]; then
        return 0
    fi

    if [ -z "$SMB_HOST" ] || [ -z "$SMB_SHARE" ]; then
        log_error "SMB_HOST и SMB_SHARE обязательны при SMB_ENABLED=true"
        return 1
    fi

    log_info "Монтирование SMB: //${SMB_HOST}/${SMB_SHARE}"
    mkdir -p "$SMB_MOUNT"

    # Формируем учётные данные
    MOUNT_OPTS="vers=3.0"
    if [ -n "$SMB_USER" ]; then
        MOUNT_OPTS="${MOUNT_OPTS},username=${SMB_USER}"
        if [ -n "$SMB_PASSWORD" ]; then
            MOUNT_OPTS="${MOUNT_OPTS},password=${SMB_PASSWORD}"
        fi
    else
        MOUNT_OPTS="${MOUNT_OPTS},guest"
    fi

    if mount -t cifs "//${SMB_HOST}/${SMB_SHARE}" "$SMB_MOUNT" -o "$MOUNT_OPTS"; then
        log_info "SMB успешно примонтирован в $SMB_MOUNT"
        return 0
    else
        log_error "Не удалось примонтировать SMB"
        return 1
    fi
}

# Размонтирование SMB
umount_smb() {
    if [ "$SMB_ENABLED" = "true" ] && mountpoint -q "$SMB_MOUNT"; then
        log_info "Размонтирование SMB..."
        umount "$SMB_MOUNT" || log_warn "Не удалось размонтировать SMB"
    fi
}

# Архивация результатов
archive_results() {
    local source_dir="$1"
    local batch_id="$2"

    if [ "$ARCHIVE_ENABLED" != "true" ]; then
        log_info "Архивация отключена"
        return 0
    fi

    if [ ! -d "$source_dir" ] || [ -z "$(ls -A "$source_dir" 2>/dev/null)" ]; then
        log_warn "Нет файлов для архивации в $source_dir"
        return 1
    fi

    local archive_name="restored_${batch_id}"
    local archive_path=""

    case "$ARCHIVE_FORMAT" in
        "zip")
            archive_path="${OUTPUT_DIR}/${archive_name}.zip"
            log_info "Создание ZIP архива: $archive_path"
            cd "$source_dir"
            zip -r "$archive_path" . -x "*.gitkeep"
            ;;
        "tar.gz"|"tgz")
            archive_path="${OUTPUT_DIR}/${archive_name}.tar.gz"
            log_info "Создание TAR.GZ архива: $archive_path"
            tar -czf "$archive_path" -C "$source_dir" .
            ;;
        *)
            log_warn "Неизвестный формат архива: $ARCHIVE_FORMAT, использую zip"
            archive_path="${OUTPUT_DIR}/${archive_name}.zip"
            cd "$source_dir"
            zip -r "$archive_path" . -x "*.gitkeep"
            ;;
    esac

    if [ -f "$archive_path" ]; then
        local size=$(du -h "$archive_path" | cut -f1)
        log_info "Архив создан: $archive_path ($size)"
        echo "$archive_path"
        return 0
    else
        log_error "Не удалось создать архив"
        return 1
    fi
}

# Выгрузка на SMB
upload_to_smb() {
    local file_path="$1"

    if [ "$SMB_ENABLED" != "true" ]; then
        return 0
    fi

    if [ ! -f "$file_path" ]; then
        log_error "Файл не найден: $file_path"
        return 1
    fi

    if ! mountpoint -q "$SMB_MOUNT"; then
        log_error "SMB не примонтирован"
        return 1
    fi

    local filename=$(basename "$file_path")
    local dest_path="${SMB_MOUNT}/${filename}"

    log_info "Выгрузка на SMB: $filename"
    if cp "$file_path" "$dest_path"; then
        log_info "Файл успешно выгружен: $dest_path"
        return 0
    else
        log_error "Ошибка выгрузки на SMB"
        return 1
    fi
}

# Уменьшение больших изображений для экономии GPU памяти
resize_large_images() {
    local max_size="${MAX_IMAGE_SIZE:-1024}"
    local resized_count=0
    log_info "Проверка размеров изображений (макс: ${max_size}px)..."

    while IFS= read -r img; do
        [ -f "$img" ] || continue

        # Получаем размеры
        dims=$(python3 -c "from PIL import Image; im=Image.open('$img'); print(max(im.size))" 2>/dev/null || echo "0")

        if [ -n "$dims" ] && [ "$dims" -gt "$max_size" ]; then
            log_info "Уменьшение $(basename "$img"): ${dims}px -> ${max_size}px"
            python3 << PYEOF
from PIL import Image
im = Image.open('$img')
im.thumbnail(($max_size, $max_size), Image.LANCZOS)
# Сохраняем в том же формате
if im.mode in ('RGBA', 'LA', 'P'):
    im = im.convert('RGB')
im.save('$img', quality=95)
print('Resized successfully')
PYEOF
            resized_count=$((resized_count + 1))
        fi
    done < <(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.bmp" \))

    log_info "Уменьшено изображений: $resized_count"
}

# Основная функция обработки
process_photos() {
    local batch_id="${1:-$(date +%Y%m%d_%H%M%S)}"

    log_info "Запуск обработки в режиме: $PROCESSING_MODE"
    log_info "Input: $INPUT_DIR"
    log_info "Output: $OUTPUT_DIR"
    log_info "GPU: $GPU_ID"
    log_info "Batch ID: $batch_id"

    # Создаём выходную директорию
    mkdir -p "$OUTPUT_DIR"

    # Уменьшаем большие изображения для экономии GPU памяти
    resize_large_images

    cd /app

    case "$PROCESSING_MODE" in
        "normal")
            log_info "Режим: Без царапин (стандартное восстановление)"
            python run.py \
                --input_folder "$INPUT_DIR" \
                --output_folder "$OUTPUT_DIR" \
                --GPU "$GPU_ID"
            ;;
        "scratch")
            log_info "Режим: С удалением царапин"
            python run.py \
                --input_folder "$INPUT_DIR" \
                --output_folder "$OUTPUT_DIR" \
                --GPU "$GPU_ID" \
                --with_scratch
            ;;
        "scratch_hr")
            log_info "Режим: С удалением царапин + высокое разрешение"
            python run.py \
                --input_folder "$INPUT_DIR" \
                --output_folder "$OUTPUT_DIR" \
                --GPU "$GPU_ID" \
                --with_scratch \
                --HR
            ;;
        *)
            log_error "Неизвестный режим: $PROCESSING_MODE"
            log_info "Доступные режимы: normal, scratch, scratch_hr"
            exit 1
            ;;
    esac

    # Проверяем результаты
    if [ -d "$OUTPUT_DIR/final_output" ]; then
        RESULT_COUNT=$(find "$OUTPUT_DIR/final_output" -type f | wc -l)
        log_info "Обработка завершена! Результатов: $RESULT_COUNT"
        log_info "Результаты сохранены в: $OUTPUT_DIR/final_output"

        # Архивируем и выгружаем
        archive_path=$(archive_results "$OUTPUT_DIR/final_output" "$batch_id")
        if [ -n "$archive_path" ] && [ -f "$archive_path" ]; then
            upload_to_smb "$archive_path"
        fi
    else
        log_warn "Директория final_output не создана. Проверьте логи выше."
    fi
}

# Watch режим - следит за новыми файлами
watch_mode() {
    log_info "Запуск в режиме наблюдения (watch mode)"
    log_info "Интервал проверки: $WATCH_INTERVAL секунд"

    PROCESSED_DIR="$INPUT_DIR/.processed"
    mkdir -p "$PROCESSED_DIR"

    # Монтируем SMB при старте watch mode
    if [ "$SMB_ENABLED" = "true" ]; then
        mount_smb || log_warn "SMB недоступен, продолжаем без него"
    fi

    # Cleanup при выходе
    trap 'umount_smb; exit 0' SIGTERM SIGINT

    while true; do
        if check_input 2>/dev/null; then
            # Перемещаем файлы во временную директорию для обработки
            BATCH_DIR=$(mktemp -d)
            BATCH_ID=$(date +%Y%m%d_%H%M%S)

            find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.bmp" \) -exec mv {} "$BATCH_DIR/" \;

            if [ "$(ls -A $BATCH_DIR)" ]; then
                log_info "Обработка batch: $BATCH_ID"

                INPUT_DIR="$BATCH_DIR" OUTPUT_DIR="$OUTPUT_DIR/$BATCH_ID" process_photos "$BATCH_ID"

                # Перемещаем обработанные в архив
                mv "$BATCH_DIR"/* "$PROCESSED_DIR/" 2>/dev/null || true
            fi

            rm -rf "$BATCH_DIR"
        fi

        sleep "$WATCH_INTERVAL"
    done
}

# Показать справку
show_help() {
    echo "Photo Restoration Service"
    echo "========================="
    echo ""
    echo "Переменные окружения:"
    echo ""
    echo "  Обработка:"
    echo "    PROCESSING_MODE  - Режим: normal, scratch, scratch_hr (default: normal)"
    echo "    INPUT_DIR        - Входные изображения (default: /data/input)"
    echo "    OUTPUT_DIR       - Результаты (default: /data/output)"
    echo "    GPU_ID           - ID GPU (default: 0)"
    echo "    WATCH_MODE       - Режим наблюдения: true/false (default: false)"
    echo "    WATCH_INTERVAL   - Интервал проверки в секундах (default: 10)"
    echo ""
    echo "  Архивация:"
    echo "    ARCHIVE_ENABLED  - Включить архивацию: true/false (default: true)"
    echo "    ARCHIVE_FORMAT   - Формат: zip, tar.gz (default: zip)"
    echo ""
    echo "  SMB выгрузка:"
    echo "    SMB_ENABLED      - Включить выгрузку: true/false (default: false)"
    echo "    SMB_HOST         - IP или hostname SMB сервера"
    echo "    SMB_SHARE        - Имя шары (например: photo_results)"
    echo "    SMB_USER         - Имя пользователя (опционально)"
    echo "    SMB_PASSWORD     - Пароль (опционально)"
    echo ""
    echo "Примеры запуска:"
    echo "  docker run -e PROCESSING_MODE=scratch photo-restoration"
    echo "  docker run -e SMB_ENABLED=true -e SMB_HOST=192.168.1.1 -e SMB_SHARE=photos photo-restoration"
    echo ""
}

# =============================================================================
# Главная логика
# =============================================================================

# Если передан аргумент, используем его как команду
if [ "$1" = "help" ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    show_help
    exit 0
fi

if [ "$1" = "check" ]; then
    check_gpu
    exit $?
fi

if [ "$1" = "bash" ] || [ "$1" = "sh" ]; then
    exec /bin/bash
fi

# Если есть аргументы, передаём их напрямую в run.py
if [ $# -gt 0 ]; then
    log_info "Запуск с пользовательскими аргументами: $@"
    cd /app
    exec python run.py "$@"
fi

# Стандартный запуск
log_info "========================================"
log_info "Photo Restoration Service Starting"
log_info "========================================"

# Установка моделей из volume
setup_models() {
    log_info "Проверка и установка моделей..."

    # dlib face landmarks
    # Скрипты ищут файл в текущей директории (Face_Detection), поэтому копируем туда
    if [ -f "$MODELS_DIR/shape_predictor_68_face_landmarks.dat" ]; then
        if [ ! -f "/app/Face_Detection/shape_predictor_68_face_landmarks.dat" ]; then
            log_info "Копирование dlib модели..."
            cp "$MODELS_DIR/shape_predictor_68_face_landmarks.dat" /app/Face_Detection/
        fi
    else
        log_warn "Модель dlib не найдена в $MODELS_DIR"
    fi

    # Face checkpoints
    if [ -f "$MODELS_DIR/face_checkpoints.zip" ]; then
        if [ ! -d "/app/Face_Enhancement/checkpoints/Setting_9_epoch_100" ]; then
            log_info "Распаковка face_checkpoints..."
            cd /app/Face_Enhancement
            unzip -q "$MODELS_DIR/face_checkpoints.zip"
        fi
    else
        log_warn "face_checkpoints.zip не найден в $MODELS_DIR"
    fi

    # Global checkpoints
    if [ -f "$MODELS_DIR/global_checkpoints.zip" ]; then
        if [ ! -d "/app/Global/checkpoints/detection" ]; then
            log_info "Распаковка global_checkpoints..."
            cd /app/Global
            unzip -q "$MODELS_DIR/global_checkpoints.zip"
        fi
    else
        log_warn "global_checkpoints.zip не найден в $MODELS_DIR"
    fi

    cd /app

    # Патч для NumPy совместимости в align_warp_back_multiple_dlib.py
    # Исправляем строку: mask *= 255.0 -> mask = (mask * 255.0).astype(np.uint8)
    DLIB_FILE="/app/Face_Detection/align_warp_back_multiple_dlib.py"
    if [ -f "$DLIB_FILE" ] && grep -q "mask \*= 255.0" "$DLIB_FILE"; then
        log_info "Применение патча для NumPy совместимости..."
        sed -i 's/mask \*= 255\.0/mask = (mask.astype(np.float64) * 255.0).astype(np.uint8)/g' "$DLIB_FILE"
    fi

    log_info "Модели установлены"
}

# Устанавливаем модели
setup_models

# Проверяем GPU
if ! check_gpu; then
    log_error "Критическая ошибка: GPU недоступна"
    exit 1
fi

# Монтируем SMB если включено (для однократного режима)
if [ "$SMB_ENABLED" = "true" ] && [ "$WATCH_MODE" != "true" ]; then
    mount_smb || log_warn "SMB недоступен, продолжаем без него"
    trap 'umount_smb; exit 0' SIGTERM SIGINT EXIT
fi

# Watch mode или однократная обработка
if [ "$WATCH_MODE" = "true" ]; then
    watch_mode
else
    if check_input; then
        process_photos
    else
        log_warn "Нет файлов для обработки. Контейнер завершает работу."
        log_info "Поместите изображения в $INPUT_DIR и перезапустите контейнер"
        exit 0
    fi
fi
