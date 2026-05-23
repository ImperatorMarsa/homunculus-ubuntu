#!/usr/bin/env bash
# ============================================================================
# build-autoinstall-iso.sh
#
# Создаёт кастомный Ubuntu Server ISO с встроенным autoinstall.
# После запуска ISO в VM установка стартует БЕЗ участия человека.
#
# Использование:
#   ./build-autoinstall-iso.sh path/to/ubuntu-26.04-live-server-amd64.iso
#
# Результат: ubuntu-autoinstall.iso в текущей директории
# ============================================================================

set -euo pipefail

# --- Параметры --------------------------------------------------------------
SRC_ISO="${1:-}"
OUT_ISO="${OUT_ISO:-ubuntu-autoinstall.iso}"
WORK_DIR="${WORK_DIR:-./iso-build}"
USER_DATA="${USER_DATA:-./user-data}"
META_DATA="${META_DATA:-./meta-data}"

# --- Проверки --------------------------------------------------------------
if [[ -z "$SRC_ISO" ]]; then
  echo "ОШИБКА: укажи путь к исходному ISO." >&2
  echo "Пример: $0 ~/Downloads/ubuntu-26.04-live-server-amd64.iso" >&2
  exit 1
fi

for f in "$SRC_ISO" "$USER_DATA" "$META_DATA"; do
  [[ -f "$f" ]] || { echo "ОШИБКА: не найден файл: $f" >&2; exit 1; }
done

for tool in xorriso 7z; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ОШИБКА: не установлен '$tool'." >&2
    echo "Установи: sudo apt install -y xorriso p7zip-full" >&2
    exit 1
  }
done

# --- Подготовка рабочей директории -----------------------------------------
echo ">>> Очистка $WORK_DIR..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/iso" "$WORK_DIR/boot"

# --- Извлечение содержимого ISO --------------------------------------------
echo ">>> Извлечение содержимого ISO..."
xorriso -osirrox on \
        -indev "$SRC_ISO" \
        -extract / "$WORK_DIR/iso" \
        2>/dev/null

# Снимаем флаг read-only с извлечённых файлов
chmod -R u+w "$WORK_DIR/iso"

# --- Извлечение загрузочных образов (нужно для пересборки) -----------------
echo ">>> Извлечение boot-образов (BIOS+UEFI)..."
xorriso -indev "$SRC_ISO" \
        -report_el_torito as_mkisofs \
        > "$WORK_DIR/xorriso-args.txt" 2>/dev/null || true

# Достаём physical boot images через 7z (надёжнее, чем парсить вывод xorriso)
7z -y x -o"$WORK_DIR/boot" "$SRC_ISO" '[BOOT]' >/dev/null
# Результат: $WORK_DIR/boot/[BOOT]/1-Boot-NoEmul.img  (BIOS, El Torito)
#            $WORK_DIR/boot/[BOOT]/2-Boot-NoEmul.img  (UEFI, GPT partition)

# --- Подкладываем autoinstall конфиг ---------------------------------------
echo ">>> Размещение user-data и meta-data в /nocloud/ на ISO..."
mkdir -p "$WORK_DIR/iso/nocloud"
cp "$USER_DATA" "$WORK_DIR/iso/nocloud/user-data"
cp "$META_DATA" "$WORK_DIR/iso/nocloud/meta-data"

# --- Патчим GRUB-конфиг ----------------------------------------------------
# Что меняем:
#   1) timeout=1 (вместо 30) - быстрее стартует
#   2) default=0 - выбираем первый пункт меню
#   3) Добавляем autoinstall + ds=nocloud в первый menuentry
echo ">>> Патчим grub.cfg..."
GRUB_CFG="$WORK_DIR/iso/boot/grub/grub.cfg"
cp "$GRUB_CFG" "$GRUB_CFG.orig"

# Сокращаем таймаут и форсируем дефолт
sed -i 's/^set timeout=.*/set timeout=1/' "$GRUB_CFG"
grep -q '^set default=' "$GRUB_CFG" || \
  sed -i '1i set default=0' "$GRUB_CFG"

# Заменяем стандартный menuentry на автоустановочный.
# Современные Ubuntu Server ISO содержат строку вида:
#   linux /casper/vmlinuz  ---
# Мы вставляем autoinstall параметр и ds= перед "---"
sed -i 's|/casper/vmlinuz\([^-]*\)---|/casper/vmlinuz\1autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---|' "$GRUB_CFG"

# Аналогично для isolinux (legacy BIOS boot), если такой файл есть
ISOLINUX_CFG="$WORK_DIR/iso/isolinux/txt.cfg"
if [[ -f "$ISOLINUX_CFG" ]]; then
  sed -i 's|/casper/vmlinuz\([^-]*\)---|/casper/vmlinuz\1autoinstall ds=nocloud;s=/cdrom/nocloud/ ---|' \
      "$ISOLINUX_CFG"
fi

# Проверяем, что autoinstall точно попал в grub.cfg
if ! grep -q 'autoinstall' "$GRUB_CFG"; then
  echo "ВНИМАНИЕ: автозамена в grub.cfg не сработала." >&2
  echo "Содержимое grub.cfg для ручной проверки:" >&2
  cat "$GRUB_CFG" >&2
  exit 1
fi

# --- Сборка нового ISO ------------------------------------------------------
# Опции -as mkisofs ниже обеспечивают:
#   * GPT + защитный MBR (загружается и на UEFI, и на BIOS)
#   * El Torito catalog (BIOS boot)
#   * Appended EFI partition (UEFI boot)
echo ">>> Сборка $OUT_ISO..."

VOLID=$(xorriso -indev "$SRC_ISO" -toc 2>/dev/null \
        | grep -oP "Volume id\s*:\s*'\K[^']+" \
        | head -1 || echo "UBUNTU_AUTOINSTALL")

OUT_ISO_ABS="$(realpath -m "$OUT_ISO")"

cd "$WORK_DIR/iso"

xorriso -as mkisofs \
        -r -V "$VOLID" \
        -J -joliet-long \
        -iso-level 3 \
        --modification-date="$(date -u +%Y%m%d%H%M%S00)" \
        --grub2-mbr "../boot/[BOOT]/1-Boot-NoEmul.img" \
        -partition_offset 16 \
        --mbr-force-bootable \
        -append_partition 2 0xef "../boot/[BOOT]/2-Boot-NoEmul.img" \
        -appended_part_as_gpt \
        -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
        -c '/boot.catalog' \
        -b '/boot/grub/i386-pc/eltorito.img' \
          -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
        -eltorito-alt-boot \
        -e '--interval:appended_partition_2:::' \
          -no-emul-boot \
        -o "$OUT_ISO_ABS" \
        .

cd - >/dev/null

# --- Готово -----------------------------------------------------------------
ISO_SIZE=$(du -h "$OUT_ISO_ABS" | cut -f1)
echo
echo "================================================================"
echo "ГОТОВО: $OUT_ISO_ABS ($ISO_SIZE)"
echo "================================================================"
echo
echo "Следующие шаги:"
echo "  1) Скопируй ISO в директорию qemu_storage:"
echo "       cp $OUT_ISO ./qemu_storage/custom.iso"
echo "  2) Обнови docker-compose.yml — см. README.md"
echo "  3) Запусти: docker compose up"
echo
