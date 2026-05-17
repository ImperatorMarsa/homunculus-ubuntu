# Создание кастомного autoinstall ISO для Ubuntu Server 26.04

Подход: качаем оригинальный Ubuntu Server ISO, встраиваем `user-data` прямо
внутрь, патчим GRUB чтобы автоматически стартовала установка. На выходе —
один самодостаточный `.iso`, который скармливается VM как обычный
загрузочный диск. Никаких seed-floppy, никаких HTTP-серверов.

---

## Шаг 1. Предварительные требования

На хост-машине (где собираем ISO) нужны:

```bash
sudo apt update
sudo apt install -y xorriso p7zip-full whois
```

- `xorriso` — распаковка/сборка ISO с сохранением UEFI+BIOS boot-секторов
- `p7zip-full` — извлечение загрузочных образов из `[BOOT]`
- `whois` — даёт команду `mkpasswd` для генерации хеша пароля

---

## Шаг 2. Скачать оригинальный Ubuntu Server ISO

С официальной зеркальной сети:

```bash
# Замени на актуальную версию, когда выйдет 26.04 LTS:
wget https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso

# Проверь контрольную сумму:
wget https://releases.ubuntu.com/26.04/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

---

## Шаг 3. Подготовить user-data

В файле `user-data` (приложен) нужно заменить **два значения**:

**Хеш пароля для пользователя `admin`:**

```bash
mkpasswd -m sha-512
# либо
openssl passwd -6
```

Скопировать полученную строку (начинается с `$6$...`) в строку
`password:` в `user-data`.

**Публичный SSH-ключ:**

```bash
cat ~/.ssh/id_ed25519.pub
```

Скопировать в массив `authorized-keys`.

---

## Шаг 4. Собрать кастомный ISO

В директории должны лежать три файла: `user-data`, `meta-data`,
`build-autoinstall-iso.sh`.

```bash
chmod +x build-autoinstall-iso.sh
./build-autoinstall-iso.sh ~/Downloads/ubuntu-26.04-live-server-amd64.iso
```

Скрипт:

1. Распаковывает оригинальный ISO во временный каталог `iso-build/`.
2. Извлекает El Torito boot-образы (BIOS + UEFI ESP) — без них пересобранный
   ISO не сможет загрузиться на UEFI.
3. Кладёт `user-data` и `meta-data` в `/nocloud/` внутри ISO.
4. Патчит `boot/grub/grub.cfg`:
   - таймаут меню → 1 секунда (вместо 30)
   - default → первый пункт
   - в `linux /casper/vmlinuz ... ---` добавляет
     `autoinstall ds=nocloud;s=/cdrom/nocloud/`
5. Пересобирает hybrid ISO с правильными параметрами `xorriso`, чтобы
   работала и BIOS-загрузка (El Torito), и UEFI-загрузка (GPT-приложенный
   ESP-раздел).

Результат: `ubuntu-autoinstall.iso` в текущей директории.

---

## Шаг 5. Подключить ISO к qemux/qemu

`qemux/qemu` поддерживает кастомный ISO через переменную окружения `BOOT`,
указывающую на путь к локальному файлу (внутри контейнера).

Скопируй полученный ISO в директорию, монтируемую как `/storage`:

```bash
cp ubuntu-autoinstall.iso ./qemu_storage/custom.iso
```

И обнови `docker-compose.yml`:

```yaml
services:
  qemu:
    image: qemux/qemu
    container_name: qemu
    environment:
      BOOT: "/storage/custom.iso"        # путь внутри контейнера
      BOOT_MODE: "uefi"                  # принудительно UEFI
      USER_PORTS: "22,80,443,5900"
      ARGUMENTS: "-device usb-host,vendorid=0x1234,productid=0x1234"
    volumes:
      - ./qemu_storage:/storage
    devices:
      - /dev/bus/usb
      - /dev/kvm
      - /dev/net/tun
      - /dev/disk/by-id/ata-MT-128_9191219802151:/disk2
    cap_add:
      - NET_ADMIN
    ports:
      - 8006:8006
      - 2222:22
      - 2280:80
      - 2443:443
      - 5900:5900
    restart: no
    stop_grace_period: 2m
```

Изменения по сравнению с исходным compose:

- `BOOT: "ubuntus"` → `BOOT: "/storage/custom.iso"` — отключаем автоскачивание
- Добавлено `BOOT_MODE: "uefi"` — наш ISO собран для UEFI-загрузки

> **Важно:** проверь актуальный синтаксис `BOOT` для текущей версии
> `qemux/qemu` — в README образа описано, какие пути и форматы поддерживаются.
> Если переменная `BOOT` не принимает локальные пути, используй
> `ARGUMENTS` с `-cdrom /storage/custom.iso`.

---

## Шаг 6. Запуск

```bash
docker compose up
```

Открой web-консоль на `http://localhost:8006`. Должно произойти:

1. VM стартует с custom.iso.
2. GRUB показывает меню на 1 секунду и автоматически выбирает первый пункт.
3. Subiquity находит `/cdrom/nocloud/user-data`, валидирует YAML.
4. Автоматически выбирает самый большой диск (= физический MT-128 SSD).
5. Создаёт GPT → ESP (1G) + /boot (2G ext4) + btrfs (остаток).
6. Создаёт btrfs-подтома `@` и `@home`.
7. Устанавливает пакеты, настраивает SSH, применяет late-commands.
8. Перезагружается.

После reboot **физический диск загружается через UEFI напрямую**. Установочный
ISO больше не нужен — можно удалить `BOOT: ...` из compose или закомментировать
монтирование `custom.iso`.

---

## Шаг 7. Первый вход и установка Docker

```bash
ssh admin@<vm-ip>          # или: ssh -p 2222 admin@localhost

# Docker через официальный репозиторий:
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
     -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) \
      signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker admin
```

Поскольку корень — btrfs, Docker сам выберет storage driver `btrfs`.
Проверить: `docker info | grep "Storage Driver"`.

---

## Отладка

**autoinstall не стартует, висит prompt "Continue with autoinstall?"**

Это значит kernel cmdline не содержит параметра `autoinstall`. Проверь
содержимое `boot/grub/grub.cfg` в собранном ISO:

```bash
xorriso -indev ubuntu-autoinstall.iso \
        -osirrox on -extract /boot/grub/grub.cfg /tmp/check-grub.cfg 2>/dev/null
grep autoinstall /tmp/check-grub.cfg
```

Должна быть строка вида:
```
linux /casper/vmlinuz ... autoinstall ds=nocloud;s=/cdrom/nocloud/ ---
```

**autoinstall стартует, но валится с ошибкой YAML-схемы**

Прогони валидацию локально перед сборкой:

```bash
# Через subiquity (если установлен):
subiquity --dry-run --autoinstall user-data

# Или через snap:
sudo snap install subiquity --classic
```

**Установка идёт не на тот диск**

Проверь критерии в `storage.config.match`:
- `size: largest` берёт самый большой → правильно, если 128 GB SSD > 16 GB
  внутреннего диска VM
- При желании можно сматчиться явно через `match: { path: "/dev/sdb" }`,
  но это менее надёжно (порядок может меняться)

**ISO не грузится в UEFI-режиме**

Проверь, что `qemux/qemu` запускает VM в UEFI-режиме (`BOOT_MODE: "uefi"`).
Также убедись, что в собранном ISO есть GPT-раздел типа EF00:

```bash
fdisk -l ubuntu-autoinstall.iso
# должна быть строка: ... EFI System
```

---

## Что ещё можно настроить

- **Сразу включить установку Docker через PPA в autoinstall** —
  через секцию `apt.sources` и `packages: [docker-ce, ...]`. Оставлено
  на ручную установку, как и было запрошено.
- **Подписать ISO** через `secureboot-db` — нужно для UEFI с включённым
  Secure Boot. Для лабораторной VM не требуется.
- **Включить TPM/disk encryption** — через `storage.layout: hybrid` с
  `encrypted: true`. Несовместимо с явным action-based config выше; либо
  то, либо другое.
