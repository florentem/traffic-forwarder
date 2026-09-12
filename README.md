# Traffic Forwarder

Универсальный скрипт для быстрой настройки ядра Linux и создания `systemd`-сервиса трансляции трафика (L4 DNAT + MASQUERADE) через сервера-форвардеры.

## Возможности
- **Работа на уровне ядра**: нулевой оверхед по памяти и процессору (iptables DNAT + MASQUERADE).
- **Авто-настройка ядра**: автоматически включает `net.ipv4.ip_forward=1` в рантайме и персистентно в `/etc/sysctl.d/99-ip-forward.conf`.
- **Изолированные цепочки**: не конфликтует с Docker, UFW или существующими правилами iptables.
- **Поддержка любых протоколов**: TCP, UDP или оба сразу (`both`).
- **Полноценный systemd-сервис**: автозапуск при загрузке сервера, чистый сброс правил при остановке (`systemctl stop`).
- **Поддержка UFW**: автоматически открывает пробрасываемые порты в фаерволе, если UFW активен.
- **Без хардкода**: никаких скрытых адресов или портов по умолчанию.

---

## Быстрая установка (One-Liner)

Выполните на **сервере-форвардере**:

```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- \
  --target <IP_СЕРВЕРА> \
  --port <ПОРТ_1> \
  --port <ПОРТ_2>
```

### Пример проброса Minecraft (25565 TCP) и Voice Chat (24454 UDP) на danki:
```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- \
  -t 89.23.123.4 \
  -p 25565 \
  -p 24454/udp
```

---

## Форматы флага `--port` (`-p`)
- `25565` — проброс порта 25565 -> 25565 (по умолчанию TCP).
- `24454/udp` — проброс UDP-порта 24454 -> 24454.
- `8080:80/tcp` — трансляция внешнего порта 8080 во внутренний 80 (TCP).
- `8080:80/both` — трансляция для обоих протоколов (TCP и UDP).

---

## Управление сервисом на форвардере

```bash
# Статус службы systemd
sudo systemctl status traffic-forwarder

# Просмотр правил iptables и счётчиков переданных байт/пакетов
sudo /usr/local/bin/traffic-forwarder.sh status

# Перезапуск сервиса
sudo systemctl restart traffic-forwarder

# Остановка (чисто сбрасывает и удаляет цепочки правил)
sudo systemctl stop traffic-forwarder
```

---

## Удаление

```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- --uninstall
```
