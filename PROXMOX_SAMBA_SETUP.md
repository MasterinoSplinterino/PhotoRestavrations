# Настройка общей папки Samba на Proxmox

Создаём универсальную сетевую папку на хосте Proxmox, доступную всем VM и компьютерам в локальной сети **без пароля**.

## Структура

```
/srv/proxmox/                    # Общая папка Proxmox
├── photo_restoration/           # Реставрация фото
│   ├── input/                   # Входящие фото
│   └── output/                  # Результаты (ZIP-архивы)
├── backups/                     # Для бэкапов (пример)
├── shared/                      # Общие файлы (пример)
└── ...                          # Другие сервисы
```

## 1. Установка Samba

```bash
ssh root@proxmox-host

apt update
apt install samba -y
```

## 2. Создание структуры папок

```bash
# Основная папка
mkdir -p /srv/proxmox

# Подпапки для реставрации
mkdir -p /srv/proxmox/photo_restoration/input
mkdir -p /srv/proxmox/photo_restoration/output

# Права для всех
chmod -R 777 /srv/proxmox
chown -R nobody:nogroup /srv/proxmox
```

## 3. Конфигурация Samba (гостевой доступ)

```bash
# Бэкап
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

# Редактируем
nano /etc/samba/smb.conf
```

Замените содержимое на:

```ini
[global]
   workgroup = WORKGROUP
   server string = Proxmox File Server

   # Гостевой доступ без пароля
   security = user
   map to guest = Bad User
   guest account = nobody

   # Оптимизация
   socket options = TCP_NODELAY IPTOS_LOWDELAY

   # Логирование
   log file = /var/log/samba/log.%m
   max log size = 1000

   # Поддержка Windows 10/11
   server min protocol = SMB2
   server max protocol = SMB3

   # Кодировка
   unix charset = UTF-8

# ===========================================
# Общая папка Proxmox (БЕЗ ПАРОЛЯ)
# ===========================================
[proxmox]
   comment = Proxmox Shared Storage
   path = /srv/proxmox
   browseable = yes
   read only = no
   writable = yes
   guest ok = yes
   public = yes
   create mask = 0666
   directory mask = 0777
   force user = nobody
   force group = nogroup
```

## 4. Запуск Samba

```bash
# Проверка конфига
testparm

# Перезапуск
systemctl restart smbd nmbd
systemctl enable smbd nmbd

# Проверка статуса
systemctl status smbd
```

## 5. Firewall

```bash
# Разрешаем SMB порты
iptables -I INPUT -p tcp --dport 445 -j ACCEPT
iptables -I INPUT -p tcp --dport 139 -j ACCEPT

# Сохранение (опционально)
apt install iptables-persistent -y
netfilter-persistent save
```

## 6. Проверка доступа

### Windows:
```
Win + R → \\192.168.1.100\proxmox
```
Откроется сразу, без запроса пароля.

### Linux:
```bash
# Без пароля
mount -t cifs //192.168.1.100/proxmox /mnt/proxmox -o guest

# Или
mount -t cifs //192.168.1.100/proxmox /mnt/proxmox -o username=guest,password=
```

### macOS:
```
Finder → Cmd+K → smb://192.168.1.100/proxmox → Connect as Guest
```

## 7. Настройка контейнера реставрации

**Вариант 1: Через SMB из контейнера**

В `docker-compose.yml`:
```yaml
environment:
  - SMB_ENABLED=true
  - SMB_HOST=10.0.0.1              # IP Proxmox (из VM)
  - SMB_SHARE=proxmox/photo_restoration/output
  # SMB_USER и SMB_PASSWORD не нужны - гостевой доступ
```

**Вариант 2: Примонтировать на VM, пробросить в контейнер (проще)**

На VM:
```bash
mkdir -p /mnt/proxmox
mount -t cifs //10.0.0.1/proxmox /mnt/proxmox -o guest
```

В `docker-compose.yml`:
```yaml
volumes:
  - /mnt/proxmox/photo_restoration/input:/data/input
  - /mnt/proxmox/photo_restoration/output:/data/output

environment:
  - SMB_ENABLED=false  # Не нужен, volumes напрямую
```

## 8. Автомонтирование в VM (fstab)

```bash
# Установка cifs-utils
apt install cifs-utils -y

# Точка монтирования
mkdir -p /mnt/proxmox

# Добавляем в /etc/fstab
echo "//10.0.0.1/proxmox /mnt/proxmox cifs guest,uid=1000,gid=1000,_netdev,nofail 0 0" >> /etc/fstab

# Монтируем
mount -a
```

## Итоговая схема

```
┌─────────────────────────────────────────────────────────────┐
│                     Proxmox Host                            │
│  /srv/proxmox/  ←── Samba "proxmox" (guest, без пароля)    │
│      ├── photo_restoration/                                 │
│      │       ├── input/   ← кладёшь фото сюда              │
│      │       └── output/  ← ZIP результаты тут             │
│      └── (другие папки по необходимости)                   │
└─────────────────────────────────────────────────────────────┘
           │
           │ SMB:445 (без авторизации)
           │
    ┌──────┴──────┬──────────────┐
    ▼             ▼              ▼
 ┌──────┐   ┌─────────┐   ┌───────────┐
 │  VM  │   │ Windows │   │ Mac/Linux │
 │Ubuntu│   │   ПК    │   │    ПК     │
 └──────┘   └─────────┘   └───────────┘
     │           │              │
     │      \\proxmox-ip\proxmox
     │
     └── mount -o guest → /mnt/proxmox
         Docker volumes из /mnt/proxmox
```

## Быстрый старт (копипаста)

На Proxmox выполните всё одной командой:

```bash
apt update && apt install samba -y && \
mkdir -p /srv/proxmox/photo_restoration/{input,output} && \
chmod -R 777 /srv/proxmox && \
chown -R nobody:nogroup /srv/proxmox && \
cat > /etc/samba/smb.conf << 'EOF'
[global]
   workgroup = WORKGROUP
   server string = Proxmox File Server
   security = user
   map to guest = Bad User
   guest account = nobody
   server min protocol = SMB2
   server max protocol = SMB3

[proxmox]
   path = /srv/proxmox
   browseable = yes
   writable = yes
   guest ok = yes
   public = yes
   create mask = 0666
   directory mask = 0777
   force user = nobody
   force group = nogroup
EOF
systemctl restart smbd nmbd && \
systemctl enable smbd nmbd && \
echo "Done! Access: \\\\$(hostname -I | awk '{print $1}')\\proxmox"
```

## Troubleshooting

### Windows не подключается
```
Win + R → regedit
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters
AllowInsecureGuestAuth = 1 (DWORD)
```
Перезагрузите ПК.

### "Permission denied" при записи
```bash
chmod -R 777 /srv/proxmox
```

### VM не видит Proxmox
```bash
# Узнайте IP хоста
ip route | grep default
# gateway = IP Proxmox
```
