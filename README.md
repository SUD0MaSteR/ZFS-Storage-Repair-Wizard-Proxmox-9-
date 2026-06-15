# Мастер восстановления ZFS зеркал в Proxmox 9

Интерактивный bash-скрипт с текстовым интерфейсом (TUI) для быстрой и безопасной замены сбойных дисков или создания ZFS Mirror на серверах Proxmox VE 9.x.

## 🛠 Установка зависимостей на сервере
Перед запуском убедитесь, что в системе установлены утилиты интерфейса и разметки:
```bash
apt update && apt install dialog parted -y
```

## 🏃 Запуск скрипта
Вы можете скачать этот скрипт и запустить его одной командой:
```bash
curl -sSL https://githubusercontent.com -o zfs-replace-wizard.sh && chmod +x zfs-replace-wizard.sh && ./zfs-replace-wizard.sh
```
