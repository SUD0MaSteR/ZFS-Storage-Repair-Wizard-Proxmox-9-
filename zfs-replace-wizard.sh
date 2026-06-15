#!/bin/bash

export NCURSES_NO_UTF8_ACS=1
TITLE="ZFS Storage Repair Wizard (Proxmox 9)"
LOG_FILE="/var/log/zfs-repair.log"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

echo "=== ЗАПУСК МАСТЕРА ВОССТАНОВЛЕНИЯ $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"

# 1. Поиск всех пулов в системе
ALL_POOLS=$(zpool list -H -o name 2>/dev/null)

if [ -z "$ALL_POOLS" ]; then
    log_message "Ошибка: Пулы ZFS не обнаружены."
    dialog --backtitle "$TITLE" --msgbox "В системе не обнаружено ни одного активного пула ZFS!" 8 60
    exit 0
fi

POOL_MENU=()
for p in $ALL_POOLS; do
    STATUS=$(zpool list -H -o health "$p")
    HAS_REDUNDANCY=$(zpool status "$p" | grep -E "mirror|raidz1|raidz2|raidz3" && echo "yes" || echo "no")
    IS_RESILVERING=$(zpool status "$p" | grep -q "resilver in progress" && echo "yes" || echo "no")
    
    if [ "$STATUS" != "ONLINE" ] || [ "$IS_RESILVERING" = "yes" ]; then
        POOL_MENU+=("$p" "Статус:_$STATUS")
    elif [ "$HAS_REDUNDANCY" = "no" ]; then
        POOL_MENU+=("$p" "Одиночный_диск_(Stripe)")
    fi
done

if [ ${#POOL_MENU[@]} -eq 0 ]; then
    log_message "Проверка: Все пулы здоровы."
    dialog --backtitle "$TITLE" --msgbox "Отличные новости! Все пулы ZFS находятся в статусе ONLINE. Восстановление не требуется." 8 60
    clear
    exit 0
fi

POOL=$(dialog --clear --backtitle "$TITLE" --menu "Выберите пул для восстановления/мониторинга:" 12 60 4 "${POOL_MENU[@]}" 2>&1 >/dev/tty)
[ -z "$POOL" ] && { log_message "Пользователь отменил выбор пула."; exit 1; }

log_message "Выбран пул: $POOL"

if zpool status "$POOL" | grep -q "resilver in progress"; then
    log_message "Пул уже в режиме ребилда. Переходим сразу к прогресс-бару."
    SKIP_PREPARE="yes"
else
    SKIP_PREPARE="no"
fi

if [ "$SKIP_PREPARE" = "no" ]; then
    POOL_TYPE="stripe"
    zpool status "$POOL" | grep -q "mirror" && POOL_TYPE="mirror"
    zpool status "$POOL" | grep -q "raidz1" && POOL_TYPE="raidz1"
    zpool status "$POOL" | grep -q "raidz2" && POOL_TYPE="raidz2"
    zpool status "$POOL" | grep -q "raidz3" && POOL_TYPE="raidz3"

    FAULTED_DISK=$(zpool status "$POOL" | awk '/FAULTED|UNAVAIL|OFFLINE/ {print $1}' | grep -v -E "mirror|raidz|$POOL" | head -n 1)
    MODE="replace"

    if [ -z "$FAULTED_DISK" ]; then
        FAULTED_DISK=$(zpool status "$POOL" | awk '/was \/dev/ {print $1}' | head -n 1)
    fi

    RAW_ALIVE=$(zpool status "$POOL" | grep ONLINE | grep -v -E "$POOL|mirror|raidz" | awk '{print $1}' | head -n 1)

    if [ -z "$FAULTED_DISK" ] && [ "$POOL_TYPE" = "stripe" ]; then
        MODE="attach"
        dialog --backtitle "$TITLE" --yesno "Пул $POOL сейчас работает без избыточности.\n\nВы хотите добавить второй диск и сделать этот массив Зеркалом?" 12 60
        [ $? -ne 0 ] && { log_message "Пользователь отказался от создания зеркала."; exit 1; }
    fi

    if [ -z "$FAULTED_DISK" ] && [ "$POOL_TYPE" != "stripe" ] && [ "$POOL_TYPE" != "mirror" ]; then
        dialog --backtitle "$TITLE" --msgbox "Пул имеет структуру $POOL_TYPE. В массивах RAID-5/6 нельзя запустить замену, пока старый диск не помечен как FAULTED." 10 60
        log_message "Ошибка: Попытка ребилда RAIDЗ без FAULTED диска."
        exit 1
    fi

    dialog --backtitle "$TITLE" --yesno "Пул: $POOL ($POOL_TYPE)\nОпорный живой диск: $RAW_ALIVE\nСбойный vdev/ID: ${FAULTED_DISK:-"Новый диск"}\n\nРежим операции: ${MODE^^}.\nПродолжить?" 14 60
    [ $? -ne 0 ] && { log_message "Пользователь отменил операцию на этапе подтверждения."; exit 1; }

    # 3. АНАЛИЗ И СТРОГАЯ ФИЛЬТРАЦИЯ ФИЗИЧЕСКИХ НАКОПИТЕЛЕЙ
    log_message "--- АНАЛИЗ ПОДКЛЮЧЕННЫХ ДИСКОВ В СИСТЕМЕ ---"
    mapfile -t AVAILABLE_DISKS < <(lsblk -dno NAME,SIZE,TRAN,MODEL,SERIAL | awk '$3 !~ /loop|rom/ {print $0}')

    DISK_MENU=()
    ZFS_USED_DISKS=$(zpool status | grep -oE '(ata-|nvme-|wwn-|sd)[a-zA-Z0-9_-]+' | sort -u)

    for row in "${AVAILABLE_DISKS[@]}"; do
        dev_name=$(echo "$row" | awk '{print $1}')
        dev_size=$(echo "$row" | awk '{print $2}')
        dev_tran=$(echo "$row" | awk '{print $3}')
        dev_model=$(echo "$row" | awk '{$1=$2=$3=""; print $0}' | sed -e 's/^[ \t]*//')
        dev_serial=$(echo "$dev_model" | awk '{print $NF}')
        dev_model_clean=$(echo "$dev_model" | sed "s/$dev_serial//g" | sed -e 's/[ \t]*$//')
        
        [ -z "$dev_tran" ] && dev_tran="PCIe/NVMe"
        [ -z "$dev_serial" ] && dev_serial="N/A"
        [ -z "$dev_model_clean" ] && dev_model_clean="Generic Disk"

        # Фильтр виртуальных дисков ВМ (zd*)
        if [[ "$dev_name" == zd* ]]; then
            log_message "Устройство /dev/$dev_name ИСКЛЮЧЕНO: Виртуальный том ZVOL."
            continue
        fi

        # Проверка монтирования диска или разделов
        MOUNT_POINTS=$(lsblk -no MOUNTPOINTS "/dev/$dev_name" | tr -d '[:space:]')
        IS_MOUNTED="no"
        [ ! -z "$MOUNT_POINTS" ] && IS_MOUNTED="yes"
        mount | grep -q -E "/dev/${dev_name}" && IS_MOUNTED="yes"

        # Проверка LVM
        IS_LVM="no"
        if pvs 2>/dev/null | grep -q "/dev/$dev_name" || lsblk -no TYPE "/dev/$dev_name" | grep -q "lvm"; then
            IS_LVM="yes"
        fi
        
        # Проверка вхождения в пулы ZFS
        echo "$ZFS_USED_DISKS" | grep -q -E "$dev_name|$dev_serial" && IS_ZFS_USED="yes" || IS_ZFS_USED="no"

        # ПРОВЕРКА ЛОГИКИ: Допускаем диск ТОЛЬКО если он полностью пуст ИЛИ является текущим сбойным vdev
        IS_TARGET_FAULTED="no"
        if [ ! -z "$FAULTED_DISK" ] && echo "$FAULTED_DISK" | grep -q -E "$dev_name|$dev_serial"; then
            IS_TARGET_FAULTED="yes"
        fi

        if [ "$IS_TARGET_FAULTED" = "yes" ]; then
            # Разрешаем выводить поврежденный диск, ТОЛЬКО если он не смонтирован администратором вручную
            if [ "$IS_MOUNTED" = "no" ]; then
                log_message "Диск /dev/$dev_name ($dev_model_clean) ДОСТУПЕН: Является текущим поврежденным vdev пула $POOL."
                DISK_MENU+=("$dev_name" "[ $dev_size ] ${dev_tran^^} | $dev_model_clean | SN: $dev_serial")
                continue
            fi
        fi

        # Если диск не сбойный vdev, он обязан быть железно чистым от ZFS, LVM и монтирований
        if [ "$IS_MOUNTED" = "yes" ]; then
            log_message "Диск /dev/$dev_name ($dev_model_clean) ИСКЛЮЧЕН: Обнаружена активная точка монтирования."
        elif [ "$IS_LVM" = "yes" ]; then
            log_message "Диск /dev/$dev_name ($dev_model_clean) ИСКЛЮЧЕН: Занят структурой LVM."
        elif [ "$IS_ZFS_USED" = "yes" ]; then
            log_message "Диск /dev/$dev_name ($dev_model_clean) ИСКЛЮЧЕН: Занят в пуле ZFS."
        else
            log_message "Диск /dev/$dev_name ($dev_model_clean) ПРОВЕРЕН: Абсолютно чистый и доступен для выбора."
            DISK_MENU+=("$dev_name" "[ $dev_size ] ${dev_tran^^} | $dev_model_clean | SN: $dev_serial")
        fi
    done
    log_message "--------------------------------------------"

    if [ ${#DISK_MENU[@]} -eq 0 ]; then
        log_message "Ошибка: Свободные диски на сервере отсутствуют."
        dialog --backtitle "$TITLE" --msgbox "Внимание! В системе не найдено ни одного СВОБОДНОГО накопителя.\n\nВсе подключенные диски уже распределены под нужды ОС, LVM, точек монтирования или рабочих ZFS пулов." 10 65
        exit 1
    fi

    log_message "--- ИТОГОВЫЙ СПИСОК ДЛЯ ПОЛЬЗОВАТЕЛЯ В GUI ---"
    for ((i=0; i<${#DISK_MENU[@]}; i+=2)); do
        log_message "Пункт меню: /dev/${DISK_MENU[i]} -> ${DISK_MENU[i+1]}"
    done
    log_message "--------------------------------------------"

    CHOSEN_DEV=$(dialog --clear --backtitle "$TITLE" --menu "Выберите СВОБОДНЫЙ диск для интеграции (сверьте модель и SN):" 18 90 8 "${DISK_MENU[@]}" 2>&1 >/dev/tty)
    [ -z "$CHOSEN_DEV" ] && { log_message "Пользователь отменил выбор нового диска."; exit 1; }
    log_message "Пользователь выбрал свободный диск: /dev/$CHOSEN_DEV"

    dialog --backtitle "$TITLE" --yesno "ВНИМАНИЕ! Диск /dev/$CHOSEN_DEV будет ОЧИЩЕН.\nВсе данные будут уничтожены.\n\nПродолжить?" 12 60
    [ $? -ne 0 ] && { log_message "Отмена очистки диска пользователем."; exit 1; }

    dialog --backtitle "$TITLE" --infobox "Освобождаем пул от старых блокировок и форматируем диск..." 8 60

    if [ "$POOL_TYPE" = "mirror" ] && [ ! -z "$FAULTED_DISK" ]; then
        log_message "Выполнение zpool detach для $FAULTED_DISK"
        zpool detach "$POOL" "$FAULTED_DISK" >> "$LOG_FILE" 2>&1
        zpool offline -f "$POOL" "$FAULTED_DISK" >> "$LOG_FILE" 2>&1
        MODE="attach"
    fi

    log_message "Очистка метаданных wipefs и labelclear на /dev/$CHOSEN_DEV"
    wipefs -a "/dev/$CHOSEN_DEV" >> "$LOG_FILE" 2>&1
    zpool labelclear -f "/dev/${CHOSEN_DEV}1" 2>/dev/null
    zpool labelclear -f "/dev/$CHOSEN_DEV" 2>/dev/null
    dd if=/dev/zero of="/dev/$CHOSEN_DEV" bs=1M count=20 conv=fdatasync status=none >> "$LOG_FILE" 2>&1

    ALIVE_DEV=$(ls -l /dev/disk/by-id/ | grep -E "nvme-|ata-" | grep "$RAW_ALIVE" | awk '{print $NF}' | sed 's|../../||' | tr -d '0-9' | head -n 1)
    [ -z "$ALIVE_DEV" ] && ALIVE_DEV=$(echo "$RAW_ALIVE" | tr -d '[:space:]')

    log_message "Клонирование таблицы разделов с /dev/$ALIVE_DEV на /dev/$CHOSEN_DEV"
    sgdisk --replicate="/dev/$CHOSEN_DEV" "/dev/$ALIVE_DEV" >> "$LOG_FILE" 2>&1
    sgdisk -G "/dev/$CHOSEN_DEV" >> "$LOG_FILE" 2>&1
    partprobe "/dev/$CHOSEN_DEV" >> "$LOG_FILE" 2>&1
    sleep 2

    NEW_PART_ID=$(ls -l /dev/disk/by-id/ | grep -E "ata-|nvme-" | grep "${CHOSEN_DEV}1$" | awk '{print $9}' | head -n 1)
    [ -z "$NEW_PART_ID" ] && TARGET_PART="/dev/${CHOSEN_DEV}1" || TARGET_PART="/dev/disk/by-id/$NEW_PART_ID"

    if ! zpool status "$POOL" | grep -q "mirror"; then
        MODE="attach"
    fi

    dialog --backtitle "$TITLE" --infobox "Выполняется сборка массива пула $POOL...\nПожалуйста, подождите." 8 60

    log_message "Запуск сборки ZFS. Режим: $MODE. Целевой раздел: $TARGET_PART"
    if [ "$MODE" = "attach" ]; then
        zpool attach -f "$POOL" "$RAW_ALIVE" "$TARGET_PART" >> "$LOG_FILE" 2>&1
    else
        zpool replace -f "$POOL" "$FAULTED_DISK" "$TARGET_PART" >> "$LOG_FILE" 2>&1
    fi

    if [ $? -eq 0 ]; then
        log_message "Ребилд успешно запущен. Включаем тюнинг скорости."
        echo 5000 > /sys/module/zfs/parameters/zfs_resilver_min_time_ms 2>/dev/null
    else
        log_message "КРИТИЧЕСКАЯ ОШИБКА: ZFS отказалась выполнять команду сборки."
        dialog --backtitle "$TITLE" --msgbox "ОШИБКА: ZFS отказалась выполнить сборку массива!\n\nЖурнал логов сейчас откроется автоматически." 10 60
        dialog --backtitle "$TITLE" --title " Журнал ошибок: $LOG_FILE " --textbox "$LOG_FILE" 22 85
        clear; exit 1
    fi
fi

# 6. МОНИТОРИНГ ПРОГРЕСС-БАРА
(
    echo 0
    echo "XXX"
    echo "Инициализация ребилда пула $POOL...\nСчитывание текущей скорости ZFS."
    echo "XXX"
    sleep 1

    while true; do
        PCT=$(zpool status "$POOL" | grep -E "resilvered|done" | grep -oE "[0-9.]+\%" | tr -d '%' | head -n 1 | cut -d. -f1)
        INFO=$(zpool status "$POOL" | grep -E "scanned|issued" | sed 's/^[ \t]*//' | paste -sd " | " -)
        TIME_LEFT=$(zpool status "$POOL" | grep -oE "[0-9]+:[0-9]+:[0-9]+ to go|[0-9]+m to go" | head -n 1)
        
        [ -z "$PCT" ] && PCT=0
        
        if zpool status "$POOL" | grep -q "scan: resilvered" || ! zpool status "$POOL" | grep -q "resilver in progress"; then
            echo 100
            echo "XXX"
            echo "Синхронизация зеркала успешно завершена на 100%!"
            echo "XXX"
            sleep 1.5
            break
        fi
        
        echo "$PCT"
        echo "XXX"
        echo "Идет восстановление пула $POOL...\n\nСтатус: $INFO\nВремени осталось: ${TIME_LEFT:-"Расчет скорости..."}"
        echo "XXX"
        
        sleep 0.5
    done
) | dialog --backtitle "$TITLE" --title " Прогресс восстановления массива ZFS " --gauge "Связь с подсистемой ядра ZFS..." 14 78 0

log_message "Процесс мониторинга успешно завершен."
dialog --backtitle "$TITLE" --yesno "Ребилд успешно завершен!\nМассив пула $POOL полностью восстановлен.\n\nХотите открыть журнал логов работы скрипта?" 10 65
if [ $? -eq 0 ]; then
    dialog --backtitle "$TITLE" --title " Журнал логов: $LOG_FILE " --textbox "$LOG_FILE" 22 85
fi

clear
