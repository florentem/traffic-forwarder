# Traffic Forwarder

Универсальный инструмент настройки ядра Linux и создания `systemd`-сервисов для трансляции портов (L4 DNAT + MASQUERADE) через сервера-форвардеры.

## Возможности
- **Поддержка нескольких форвардеров на одной машине**: каждый сервис изолирован, имеет своё имя, свой systemd-юнит и свои цепочки iptables.
- **Уникальные имена сервисов**: задавайте имя вручную через `-n <имя>` (например, `-n danki`) или скрипт сгенерирует его автоматически по IP (`forwarder-<IP>`).
- **Работа на уровне ядра**: нулевой оверхед по памяти и процессору (iptables DNAT + MASQUERADE).
- **Авто-настройка ядра**: автоматически включает `net.ipv4.ip_forward=1` в рантайме и персистентно в `/etc/sysctl.d/99-ip-forward.conf`.
- **Изолированные цепочки**: не конфликтует с Docker, UFW или существующими правилами iptables.
- **Поддержка любых протоколов**: TCP, UDP или оба сразу (`both`).
- **Удобный просмотр всех сервисов**: просмотр всех запущенных форвардеров одной командой (`--list`).
- **Полноценный systemd-сервис**: автозапуск при загрузке сервера, чистый сброс правил при остановке (`systemctl stop`).

---

## Быстрая установка (One-Liner)

Выполните на **сервере-форвардере**:

### 1. Создание форвардера с уникальным именем (например, `danki`):
```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- \
  -n danki \
  -t 89.23.123.4 \
  -p 25565 \
  -p 24454/udp
```
*Создаст службу `forwarder-danki.service`.*

### 2. Создание второго независимого форвардера (например, на другой сервер):
```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- \
  -n hub \
  -t 1.2.3.4 \
  -p 25566:25565
```
*Создаст службу `forwarder-hub.service`.*

---

## Просмотр всех запущенных форвардеров

```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | bash -s -- --list
```
Выведет наглядный список всех сервисов на машине, их статус (active/inactive), целевые IP и таблицу проброшенных портов.

---

## Форматы флага `--port` (`-p`)
- `25565` — порт 25565 транслируется в 25565 (по умолчанию TCP).
- `24454/udp` — проброс UDP-порта 24454 -> 24454.
- `25565:25577` — внешний порт 25565 транслируется во внутренний 25577 на целевом сервере.
- `8080:80/both` — трансляция для обоих протоколов (TCP и UDP).

---

## Управление сервисами

Каждый сервис управляется через стандартный `systemctl`:

```bash
# Статус конкретной службы
sudo systemctl status forwarder-danki

# Просмотр правил iptables и счётчиков переданных байт/пакетов
sudo /usr/local/bin/forwarder-danki.sh status

# Перезапуск службы
sudo systemctl restart forwarder-danki

# Остановка (чисто сбрасывает и удаляет свои цепочки iptables)
sudo systemctl stop forwarder-danki

# Удаление службы
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- -n danki --uninstall
```
