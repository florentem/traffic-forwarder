# Traffic Forwarder

Универсальный и легковесный скрипт для настройки ядра Linux и создания `systemd`-сервиса трансляции трафика (L4 DNAT + MASQUERADE) через сервера-форвардеры на основной сервер Minecraft (**danki**).

По умолчанию настроен на проброс:
- **25565 (TCP)** — Minecraft (Velocity)
- **24454 (UDP)** — Simple Voice Chat

## Возможности
- **Работа на уровне ядра**: нулевой оверхед по памяти и процессору (iptables DNAT + MASQUERADE).
- **Авто-настройка ядра**: автоматически включает `net.ipv4.ip_forward=1` в рантайме и персистентно в `/etc/sysctl.d/`.
- **Изолированные цепочки**: не конфликтует с Docker, UFW или существующими правилами iptables.
- **Полноценный systemd-сервис**: автозапуск при загрузке сервера, чистый сброс правил при остановке (`systemctl stop`).
- **Поддержка UFW**: автоматически открывает нужные порты в фаерволе, если UFW активен.

---

## Быстрая установка (One-Liner)

Запустите на **сервере-форвардере**:

```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- 89.23.123.4
```
*Или с явным флагом:*
```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- -t 89.23.123.4
```

Скрипт автоматически:
1. Включит `net.ipv4.ip_forward=1` в ядре.
2. Настроит проброс порта `25565` (TCP) и `24454` (UDP) на `89.23.123.4`.
3. Создаст и запустит systemd-сервис `traffic-forwarder.service`.

---

## Кастомные порты (опционально)

Если нужно указать другие или дополнительные порты:
```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- \
  -t 89.23.123.4 \
  -p 25565 \
  -p 24454/udp
```

Форматы аргумента `-p` / `--port`:
- `25565` — порт 25565 транслируется в 25565 (TCP).
- `24454/udp` — UDP-порт.
- `25565:25565/tcp` — явное указание `ext:int/proto`.

---

## Управление сервисом

```bash
# Статус службы systemd
sudo systemctl status traffic-forwarder

# Просмотр правил iptables и счётчиков переданных байт/пакетов
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
