# Traffic Forwarder

Универсальный и легковесный инструмент настройки ядра Linux и создания `systemd`-сервиса для трансляции портов (L4 DNAT + MASQUERADE) через сервера-форвардеры.

## Возможности
- **Работа на уровне ядра**: нулевой оверхед по памяти и процессору (iptables DNAT + MASQUERADE).
- **Авто-настройка ядра**: автоматически включает `net.ipv4.ip_forward=1` в рантайме и персистентно в `/etc/sysctl.d/`.
- **Изолированные цепочки**: создаёт собственные цепочки iptables, не конфликтует с Docker, UFW или существующими правилами.
- **Поддержка любых протоколов**: TCP, UDP или оба сразу (`both`).
- **Полноценный systemd-сервис**: автоматический запуск при загрузке сервера, чистое удаление правил при остановке (`systemctl stop`).
- **Поддержка UFW**: автоматически открывает порты в фаерволе, если UFW активен.

---

## Быстрая установка (One-Liner)

```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- \
  --target <IP_СЕРВЕРА> \
  --port <ПОРТЫ>
```

### Примеры использования

#### 1. Проброс только SSH (порт 2222 форвардера -> 22 порт целевого сервера):
```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- \
  -t 89.23.123.4 \
  -p 2222:22
```
*Подключение:* `ssh -p 2222 user@<IP_ФОРВАРДЕРА>`

#### 2. Проброс SSH, игрового трафика (25565 TCP) и голосового чата (24454 UDP):
```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- \
  -t 89.23.123.4 \
  -p 2222:22 \
  -p 25565 \
  -p 24454/udp
```

---

## Форматы аргумента `--port` (`-p`)
- `2222:22` — внешний порт 2222 транслируется в 22 целевого сервера (по умолчанию TCP).
- `25565` — порт 25565 транслируется в 25565 (TCP).
- `24454/udp` или `24454:24454/udp` — проброс UDP-порта.
- `8080:80/both` — проброс как TCP, так и UDP.

---

## Управление сервисом

```bash
# Статус службы systemd
sudo systemctl status traffic-forwarder

# Просмотр правил и счётчиков переданных пакетов
sudo /usr/local/bin/traffic-forwarder.sh status

# Перезапуск сервиса
sudo systemctl restart traffic-forwarder

# Временная остановка (сбрасывает правила iptables)
sudo systemctl stop traffic-forwarder
```

---

## Удаление

```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- --uninstall
```
