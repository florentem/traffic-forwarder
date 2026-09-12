# traffic-forwarder

Скрипт для проброса портов через промежуточный сервер на уровне ядра (iptables DNAT + MASQUERADE).

Задумка простая — принять входящие пакеты на форвардере и перенаправить их на целевой хост без сторонних демонов и накладных расходов. При установке сам включает `net.ipv4.ip_forward` в ядре и оформляет правила в отдельный `systemd`-юнит.

### Ограничения
* **Реальные IP-адреса клиентов целевой сервер не увидит** — из-за MASQUERADE для него весь трафик будет идти от имени форвардера. Если вам принципиально видеть исходные IP игроков (например, для локальных банов по IP на бэкенде), этот вариант, скорее всего, вам не подходит.
* **Никакой фильтрации, защиты от DDoS или аналитики здесь нет** — ядро просто пересылает пакеты дальше как обычный роутер.

---

### Установка

```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- \
  -n <имя> \
  -t <целевой_ip> \
  -p <порты>
```

Параметры:
* `-t` — IP-адрес целевого сервера.
* `-p` — порт или список портов (например, `25565` для TCP или `24454/udp` для войса). Если порты на форвардере и цели отличаются — указываются через двоеточие (`25565:25577`).
* `-n` — короткое имя сервиса (например, `danki`). Если не указать — имя сгенерируется из IP цели.

Пример (проброс игры и войса на danki):
```bash
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- \
  -n danki \
  -t 89.23.123.4 \
  -p 25565 \
  -p 24454/udp
```

---

### Управление

```bash
# Посмотреть все форвардеры на этой машине
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | bash -s -- --list

# Посмотреть счётчики пакетов конкретного сервиса
sudo /usr/local/bin/forwarder-<имя>.sh status

# Удалить сервис и очистить правила iptables
curl -sSL https://raw.githubusercontent.com/florentem/traffic-forwarder/main/install.sh | sudo bash -s -- -n <имя> --uninstall
```
