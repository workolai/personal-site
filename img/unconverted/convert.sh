#!/bin/bash
set -euo pipefail

# Определяем, где физически лежит сам скрипт
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.img_config"

echo "=== ULTIMATE Image Optimization Script (CLI Parallel Edition) ==="

# ==================== ФУНКЦИЯ НАСТРОЙКИ ПУТИ ====================
setup_base_dir() {
    echo "--- Настройка базовой директории сайта ---"
    echo "Введите абсолютный путь к папке 'img' вашего сайта."
    echo "Пример: /home/micu/Documents/My_site/img/"
    read -r -p "Путь: " user_path

    user_path="${user_path%/}"

    if [ ! -d "$user_path" ]; then
        echo "⚠️ Ошибка: Директория '$user_path' не существует!"
        read -r -p "Всё равно сохранить этот путь? (y/n): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    echo "$user_path" > "$CONFIG_FILE"
    echo "✓ Базовый путь успешно сохранен в $CONFIG_FILE"
}

# ==================== ОБРАБОТКА ФЛАГОВ (-c / --change-dir) ====================
if [ "${1:-}" = "-c" ] || [ "${1:-}" = "--change-dir" ]; then
    setup_base_dir
    echo "Перезапуск скрипта..."
    exit 0
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Похоже, это первый запуск скрипта!"
    setup_base_dir
fi

BASE_OUT_DIR=$(cat "$CONFIG_FILE")

# ==================== ВЫБОР ПОДДИРЕКТОРИИ (Поста/Дня) ====================
echo ""
echo "Текущий базовый путь: $BASE_OUT_DIR"
echo "Введите название целевой подпапки для картинок (например: day_1):"
read -r -p "Подпапка: " sub_dir

sub_dir="${sub_dir#/}"
sub_dir="${sub_dir%/}"

FINAL_DESTINATION="$BASE_OUT_DIR/$sub_dir"
mkdir -p "$FINAL_DESTINATION"

# ==================== ВЫБОР РЕЖИМА СЖАТИЯ ====================
echo ""
echo "Выберите целевой режим сжатия:"
echo "1) Hero / LCP          — очень строго (<180 KiB)"
echo "2) Content             — строго (<230 KiB)"
echo "3) Banner              — умеренно (<350 KiB)"
echo "4) Gallery             — максимально (<110 KiB)"
read -r -p "Введите номер (1-4): " mode

case $mode in
    1) TARGET_WEBP=184320; MIN_QUALITY=18 ;;
    2) TARGET_WEBP=235520; MIN_QUALITY=22 ;;
    3) TARGET_WEBP=358400; MIN_QUALITY=28 ;;
    4) TARGET_WEBP=112640; MIN_QUALITY=15 ;;
    *) echo "По умолчанию Content"; TARGET_WEBP=235520; MIN_QUALITY=22 ;;
esac

SIZES=(640 1200 1920)
shopt -s nullglob

# Экспортируем переменные, чтобы дочерние процессы их видели
export TARGET_WEBP MIN_QUALITY FINAL_DESTINATION sub_dir SCRIPT_DIR
export -a SIZES

# ==================== ФУНКЦИЯ СЖАТИЯ ОДНОГО РАЗМЕРА ====================
compress_size() {
    local work="$1" local out_webp="$2" local out_avif="$3"
    local target_w="$4" local target_h="$5"

    local avif_target=$(( TARGET_WEBP * 70 / 100 ))
    local current_w=$target_w local current_h=$target_h

    # WebP
    magick "$work" -resize "${target_w}x${target_h}" -quality 72 -define webp:method=6 -define webp:pass=10 "$out_webp"

    # Агрессивный цикл
    for pass in {1..8}; do
        [ -f "$out_webp" ] || break
        local current_size=$(stat -c %s "$out_webp")
        [ "$current_size" -le "$TARGET_WEBP" ] && break

        local quality=$(( 72 - pass * 9 ))
        [ "$quality" -lt "$MIN_QUALITY" ] && quality=$MIN_QUALITY
        current_w=$(( current_w * 90 / 100 ))
        current_h=$(( current_h * 90 / 100 ))

        if [ $(( current_w < current_h ? current_w : current_h )) -lt 320 ]; then
            magick "$work" -resize "${target_w}x${target_h}" -quality "$quality" -define webp:method=6 -define webp:pass=10 -define webp:alpha-quality=30 "$out_webp"
            break
        fi
        magick "$work" -resize "${current_w}x${current_h}" -quality "$quality" -define webp:method=6 -define webp:pass=10 -define webp:alpha-quality=30 "$out_webp"
    done

    # AVIF
    local final_w=$(magick identify -format "%w" "$out_webp" 2>/dev/null || echo "$target_w")
    local final_h=$(magick identify -format "%h" "$out_webp" 2>/dev/null || echo "$target_h")

    magick "$work" -strip -units PixelsPerInch -density 72 -resize "${final_w}x${final_h}" -quality 60 "$out_avif"
    if [ $(stat -c %s "$out_avif" 2>/dev/null || echo 0) -gt "$avif_target" ]; then
        magick "$work" -strip -units PixelsPerInch -density 72 -resize "${final_w}x${final_h}" -quality 40 "$out_avif"
    fi
}
export -f compress_size

# ==================== ВОРКЕР: ОБРАБОТКА ОДНОГО ФАЙЛА ====================
process_single_image() {
    local input="$1"
    [ -e "$input" ] || return 0

    local name=$(basename "$input")
    local base="${name%.*}"
    local ext="${name##*.}"
    local clean_ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    [ "$clean_ext" == "jpeg" ] && clean_ext="jpg"

    local img_dir="$FINAL_DESTINATION/$base"
    local img_originals_dir="$img_dir/original"
    mkdir -p "$img_originals_dir"

    # Создаем ИЗОЛИРОВАННУЮ временную папку для конкретно этого файла
    local tmp_work_dir=$(mktemp -d "$SCRIPT_DIR/.tmp_work_${base}_XXXXXX")
    local work="$tmp_work_dir/${base}_work.${ext}"

    # Перенаправляем вывод всего процесса в переменную, чтобы логи не перемешивались в кашу
    local log_output=""

    log_output+="\n=== Processing: $name ===\n"
    log_output+=" → Результаты полетели в: $img_dir\n"

    cp "$input" "$img_originals_dir/$name"
    cp "$input" "$work"

    local has_alpha=0
    if [[ "$clean_ext" == "png" ]]; then
        if magick identify -format "%[channels]" "$work" 2>/dev/null | grep -q 'a'; then
            has_alpha=1
        fi
    fi

    if [ "$has_alpha" -eq 1 ]; then
        log_output+=" → Alpha PNG — предварительное сжатие...\n"
        pngquant --quality=40-85 --speed=1 --force --output "${work%.png}_tmp.png" "$work" && mv "${work%.png}_tmp.png" "$work" || true
        oxipng -o 6 --strip safe --quiet "$work" || true
    fi

    local src_w=$(magick identify -format "%w" "$work" 2>/dev/null || echo 0)
    local src_h=$(magick identify -format "%h" "$work" 2>/dev/null || echo 0)

    local max_created_w=0
    local max_created_h=0

    for size in "${SIZES[@]}"; do
        if [ "$size" -gt "$src_w" ] && [ "$size" -gt "$src_h" ]; then continue; fi

        if [ "$src_w" -ge "$src_h" ]; then
            local target_w=$size; local target_h=$(( src_h * size / src_w ))
        else
            local target_h=$size; local target_w=$(( src_w * size / src_h ))
        fi

        local out_webp="$img_dir/${base}-${size}.webp"
        local out_avif="$img_dir/${base}-${size}.avif"

        compress_size "$work" "$out_webp" "$out_avif" "$target_w" "$target_h"

        local final_w=$(magick identify -format "%w" "$out_webp" 2>/dev/null || echo "$target_w")
        local final_h=$(magick identify -format "%h" "$out_webp" 2>/dev/null || echo "$target_h")
        log_output+="      ✓ [${size}px] Созданы варианты WebP и AVIF [${final_w}x${final_h}]\n"

        max_created_w=$final_w
        max_created_h=$final_h
    done

    # Умный расчет размера фолбэка (Дубли удалены!)
    local fallback_w=$max_created_w
    local fallback_h=$max_created_h

    if [ "$max_created_w" -gt 1200 ] || [ "$max_created_h" -gt 1200 ]; then
        if [ "$src_w" -ge "$src_h" ]; then
            fallback_w=1200
            fallback_h=$(( src_h * 1200 / src_w ))
        else
            fallback_h=1200
            fallback_w=$(( src_w * 1200 / src_h ))
        fi
    fi

    local fallback_ext="jpg"
    [ "$has_alpha" -eq 1 ] && fallback_ext="png"

    local fallback_file="$img_dir/${base}-fallback.${fallback_ext}"

    if [ "$fallback_ext" == "png" ]; then
        magick "$work" -resize "${fallback_w}x${fallback_h}" "$fallback_file"
        log_output+="      ↳ Оптимизируем палитру уменьшенного PNG-фолбэка...\n"
        pngquant --quality=40-85 --speed=1 --force --output "${fallback_file%.png}_tmp.png" "$fallback_file" \
            && mv "${fallback_file%.png}_tmp.png" "$fallback_file" || true
        oxipng -o 6 --strip safe --quiet "$fallback_file" || true
    else
        magick "$work" -strip -units PixelsPerInch -density 72 \
            -resize "${fallback_w}x${fallback_h}" -quality 65 "$fallback_file"
    fi

    local fallback_final_size=$(stat -c %s "$fallback_file" 2>/dev/null || echo 0)
    local pretty_size=$(numfmt --to=iec "$fallback_final_size")
    log_output+="      ✓ Создан дефолтный фолбэк: ${base}-fallback.${fallback_ext} [${fallback_w}x${fallback_h}] ($pretty_size)\n"

    # Удаляем оригинал из входящей папки и временную рабочую директорию
    rm -f "$input"
    rm -rf "$tmp_work_dir"

    # Генерируем HTML блок в лог
    log_output+="\n → HTML для вашего файла:\n"
    log_output+="   <picture>\n"
    log_output+="     <source type=\"image/avif\" srcset=\"\n"
    for size in "${SIZES[@]}"; do
        [ -f "$img_dir/${base}-${size}.avif" ] && log_output+="       /img/${sub_dir}/${base}/${base}-${size}.avif ${size}w,\n"
    done
    log_output+="     \" sizes=\"(max-width: 640px) 100vw, (max-width: 1200px) 80vw, 1200px\" />\n"
    log_output+="     <source type=\"image/webp\" srcset=\"\n"
    for size in "${SIZES[@]}"; do
        [ -f "$img_dir/${base}-${size}.webp" ] && log_output+="       /img/${sub_dir}/${base}/${base}-${size}.webp ${size}w,\n"
    done
    log_output+="     \" sizes=\"(max-width: 640px) 100vw, (max-width: 1200px) 80vw, 1200px\" />\n"
    log_output+="     <img src=\"/img/${sub_dir}/${base}/${base}-fallback.${fallback_ext}\" width=\"$fallback_w\" height=\"$fallback_h\" alt=\"Опиши картинку здесь\" loading=\"lazy\" />\n"
    log_output+="   </picture>\n"

    # Выплескиваем весь лог картинки атомарно, чтобы строки не перепутались
    echo -e "$log_output"
}
export -f process_single_image

# ==================== ДИСПЕТЧЕР ПОТОКОВ ====================
files=("$SCRIPT_DIR"/*.{jpg,jpeg,png,webp,avif,JPG,JPEG,PNG,WEBP,AVIF})

if [ ${#files[@]} -eq 0 ]; then
    echo "❌ Ошибка: В папке '$SCRIPT_DIR' не найдено файлов картинок для обработки!"
    exit 1
fi

echo "🚀 Запуск параллельной обработки (Лимит: 5 потоков)..."

MAX_JOBS=5

for input in "${files[@]}"; do
    [ -e "$input" ] || continue

    # Запускаем обработку одной картинки строго в фоновом режиме (&)
    process_single_image "$input" &

    # Считаем, сколько фоновых задач запущено прямо сейчас
    # Каждый раз, когда количество фоновых задач достигает максимума,
    # команда 'wait -n' приостанавливает цикл, ожидая завершения ЛЮБОЙ одной задачи.
    while [ "$(jobs -r | wc -l)" -ge "$MAX_JOBS" ]; do
        wait -n
    done
done

# Ждем завершения последних "хвостов" в очереди
wait

echo ""
echo "=== Все картинки обработаны параллельно и разложены по полочкам! ==="
