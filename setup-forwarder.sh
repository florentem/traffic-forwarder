#!/usr/bin/env bash
# ==============================================================================
# setup-forwarder.sh — Универсальный скрипт настройки ядра и systemd-сервиса
# для перенаправления трафика (DNAT + MASQUERADE) через сервера-форвардеры
# ==============================================================================
# Поддерживает:
#   - Автоматическое включение net.ipv4.ip_forward (в рантайме и персистентно)
#   - Изолированные цепочки iptables (не конфликтует с Docker/UFW)
#   - TCP, UDP и BOTH протоколы
#   - Чистый start / stop / reload / status через systemctl
# ==============================================================================

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SERVICE_NAME="traffic-forwarder"
TARGET_IP=""
RAW_PORTS=()
UNINSTALL=false

usage() {
    cat <<EOU
Использование:
  sudo $0 --target <IP_НАЗНАЧЕНИЯ> --port <ПОРТЫ> [ОПЦИИ]

Обязательные аргументы:
  -t, --target <IP>          Целевой IP-адрес сервера (например, 89.23.123.4)
                             (также можно передать первым позиционным аргументом: sudo $0 89.23.123.4)
  -p, --port <ПРАВИЛО>       Порт или маппинг портов (можно указывать несколько раз)
                             Форматы:
                               25565              (TCP: 25565 -> целевой 25565)
                               24454/udp          (UDP: 24454 -> целевой 24454)
                               25565:25565/tcp
                               24454:24454/udp
                               8080:80/both       (TCP и UDP одновременно)

Опциональные аргументы:
  -n, --name <ИМЯ>           Имя systemd-сервиса (по умолчанию: traffic-forwarder)
  -u, --uninstall            Удалить созданный сервис и сбросить правила iptables
  -h, --help                 Показать эту справку

Примеры:
  # Проброс портов на целевой сервер:
  sudo $0 -t 89.23.123.4 -p 25565 -p 24454/udp

  # Удаление сервиса:
  sudo $0 -n traffic-forwarder --uninstall
EOU
    exit "${1:-0}"
}

# Проверка запроса справки без root
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        usage
    fi
done

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] Этот скрипт должен быть запущен с правами root (sudo).${NC}" >&2
    exit 1
fi

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)
            TARGET_IP="$2"
            shift 2
            ;;
        -p|--port)
            IFS=',' read -ra ADDR <<< "$2"
            for p in "${ADDR[@]}"; do
                RAW_PORTS+=("$p")
            done
            shift 2
            ;;
        -n|--name)
            SERVICE_NAME="$2"
            shift 2
            ;;
        -u|--uninstall)
            UNINSTALL=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$TARGET_IP" && ! "$1" =~ ^- ]]; then
                TARGET_IP="$1"
                shift
            else
                echo -e "${RED}[ERROR] Неизвестный аргумент: $1${NC}" >&2
                usage 1
            fi
            ;;
    esac
done

SCRIPT_PATH="/usr/local/bin/${SERVICE_NAME}.sh"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

# Обработка деинсталляции
if [[ "$UNINSTALL" == true ]]; then
    echo -e "${YELLOW}=== Удаление сервиса $SERVICE_NAME ===${NC}"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "Остановка сервиса и сброс правил iptables..."
        systemctl stop "$SERVICE_NAME" || true
    fi
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl disable "$SERVICE_NAME" || true
    fi
    rm -f "$UNIT_PATH" "$SCRIPT_PATH"
    systemctl daemon-reload
    echo -e "${GREEN}[OK] Сервис $SERVICE_NAME успешно удален, правила iptables очищены.${NC}"
    exit 0
fi

# Валидация входных данных
if [[ -z "$TARGET_IP" ]]; then
    echo -e "${RED}[ERROR] Не указан целевой IP (--target).${NC}" >&2
    usage 1
fi

if [[ ${#RAW_PORTS[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] Не указан ни один порт для проброса (--port).${NC}" >&2
    usage 1
fi

# Проверка / установка iptables
if ! command -v iptables &>/dev/null; then
    echo -e "${YELLOW}[WARN] Утилита iptables не найдена. Попытка автоматической установки...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq iptables
    elif command -v dnf &>/dev/null; then
        dnf install -y iptables
    elif command -v yum &>/dev/null; then
        yum install -y iptables
    elif command -v apk &>/dev/null; then
        apk add iptables
    else
        echo -e "${RED}[ERROR] Не удалось автоматически установить iptables. Установите её вручную.${NC}" >&2
        exit 1
    fi
fi

# 1. Автоматическое включение IP forwarding в ядре Linux
echo -e "${CYAN}[1/4] Проверка и настройка маршрутизации ядра (sysctl)...${NC}"
SYSCTL_VAL=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
if [[ "$SYSCTL_VAL" != "1" ]]; then
    echo "Включение net.ipv4.ip_forward в рантайме..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi

# Персистентная фиксация в /etc/sysctl.d
SYSCTL_CONF="/etc/sysctl.d/99-ip-forward.conf"
if [[ ! -f "$SYSCTL_CONF" ]] || ! grep -q "net.ipv4.ip_forward=1" "$SYSCTL_CONF" 2>/dev/null; then
    echo "Сохранение настроек в $SYSCTL_CONF..."
    cat <<EOSYS > "$SYSCTL_CONF"
# Включено скриптом ${SERVICE_NAME}
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOSYS
    sysctl --system >/dev/null 2>&1 || true
fi
echo -e "${GREEN}  ✓ IP forwarding включен и зафиксирован в sysctl${NC}"

# 2. Разбор портов
echo -e "${CYAN}[2/4] Подготовка правил перенаправления...${NC}"
PARSED_MAPPINGS=()
CHAIN_TAG=$(echo "${SERVICE_NAME}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

for item in "${RAW_PORTS[@]}"; do
    proto="tcp"
    port_part="$item"
    if [[ "$item" =~ ^(.*)/(tcp|udp|both)$ ]]; then
        port_part="${BASH_REMATCH[1]}"
        proto="${BASH_REMATCH[2]}"
    fi

    if [[ "$port_part" =~ ^([0-9]+):([0-9]+)$ ]]; then
        ext="${BASH_REMATCH[1]}"
        int="${BASH_REMATCH[2]}"
    elif [[ "$port_part" =~ ^([0-9]+)$ ]]; then
        ext="${BASH_REMATCH[1]}"
        int="${BASH_REMATCH[1]}"
    else
        echo -e "${RED}[ERROR] Некорректный формат порта: $item${NC}" >&2
        exit 1
    fi

    if [[ "$ext" == "22" ]]; then
        echo -e "${YELLOW}  [ВНИМАНИЕ] Внешний порт 22 перенаправляется на цель! Убедитесь, что порт SSH самого форвардера изменен, иначе SSH-доступ к форвардеру будет потерян.${NC}"
    fi

    if [[ "$proto" == "both" ]]; then
        PARSED_MAPPINGS+=("${ext}:${int}:tcp")
        PARSED_MAPPINGS+=("${ext}:${int}:udp")
    else
        PARSED_MAPPINGS+=("${ext}:${int}:${proto}")
    fi
done

# 3. Генерация управляющего скрипта /usr/local/bin/<name>.sh
echo -e "${CYAN}[3/4] Создание управляющего скрипта ${SCRIPT_PATH}...${NC}"
cat <<'EOSCRIPT' > "$SCRIPT_PATH"
#!/usr/bin/env bash
set -euo pipefail

TARGET_IP="__TARGET_IP__"
CHAIN_PREROUTING="FWD___TAG___PRE"
CHAIN_POSTROUTING="FWD___TAG___POST"
CHAIN_OUTPUT="FWD___TAG___OUT"
CHAIN_FORWARD="FWD___TAG___FWD"

# Список маппингов (ext:int:proto)
MAPPINGS=(
__MAPPINGS__
)

start() {
    # Гарантируем включенный форвардинг в ядре при старте
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    # Создаем изолированные цепочки (если еще не созданы)
    iptables -t nat -N "$CHAIN_PREROUTING" 2>/dev/null || true
    iptables -t nat -N "$CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t nat -N "$CHAIN_OUTPUT" 2>/dev/null || true
    iptables -N "$CHAIN_FORWARD" 2>/dev/null || true

    # Очищаем цепочки для идемпотентности
    iptables -t nat -F "$CHAIN_PREROUTING"
    iptables -t nat -F "$CHAIN_POSTROUTING"
    iptables -t nat -F "$CHAIN_OUTPUT"
    iptables -F "$CHAIN_FORWARD"

    # Привязываем изолированные цепочки в начало стандартных
    iptables -t nat -C PREROUTING -j "$CHAIN_PREROUTING" 2>/dev/null || iptables -t nat -I PREROUTING 1 -j "$CHAIN_PREROUTING"
    iptables -t nat -C POSTROUTING -j "$CHAIN_POSTROUTING" 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j "$CHAIN_POSTROUTING"
    iptables -t nat -C OUTPUT -j "$CHAIN_OUTPUT" 2>/dev/null || iptables -t nat -I OUTPUT 1 -j "$CHAIN_OUTPUT"
    iptables -C FORWARD -j "$CHAIN_FORWARD" 2>/dev/null || iptables -I FORWARD 1 -j "$CHAIN_FORWARD"

    # Разрешаем существующие и связанные соединения
    iptables -A "$CHAIN_FORWARD" -m state --state RELATED,ESTABLISHED -j ACCEPT

    for m in "${MAPPINGS[@]}"; do
        IFS=':' read -r ext int proto <<< "$m"
        # DNAT для внешнего входящего трафика
        iptables -t nat -A "$CHAIN_PREROUTING" -p "$proto" --dport "$ext" -j DNAT --to-destination "${TARGET_IP}:${int}"
        # DNAT для локальных обращений с самого хоста форвардера
        iptables -t nat -A "$CHAIN_OUTPUT" -p "$proto" --dport "$ext" -j DNAT --to-destination "${TARGET_IP}:${int}"
        # Разрешение прохождения транзитного пакета через фильтр ядра
        iptables -A "$CHAIN_FORWARD" -p "$proto" -d "$TARGET_IP" --dport "$int" -j ACCEPT
        # SNAT (MASQUERADE) в сторону целевого хоста
        iptables -t nat -A "$CHAIN_POSTROUTING" -p "$proto" -d "$TARGET_IP" --dport "$int" -j MASQUERADE
    done
    echo "[OK] Forwarding rules applied to ${TARGET_IP}."
}

stop() {
    # Отвязываем цепочки
    iptables -t nat -D PREROUTING -j "$CHAIN_PREROUTING" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j "$CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t nat -D OUTPUT -j "$CHAIN_OUTPUT" 2>/dev/null || true
    iptables -D FORWARD -j "$CHAIN_FORWARD" 2>/dev/null || true

    # Очищаем правила внутри цепочек
    iptables -t nat -F "$CHAIN_PREROUTING" 2>/dev/null || true
    iptables -t nat -F "$CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t nat -F "$CHAIN_OUTPUT" 2>/dev/null || true
    iptables -F "$CHAIN_FORWARD" 2>/dev/null || true

    # Удаляем сами цепочки
    iptables -t nat -X "$CHAIN_PREROUTING" 2>/dev/null || true
    iptables -t nat -X "$CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t nat -X "$CHAIN_OUTPUT" 2>/dev/null || true
    iptables -X "$CHAIN_FORWARD" 2>/dev/null || true
    echo "[OK] Forwarding rules cleanly removed."
}

status() {
    echo "=== PREROUTING (DNAT Rules) ==="
    iptables -t nat -L "$CHAIN_PREROUTING" -n -v --line-numbers 2>/dev/null || echo "Chain not active"
    echo ""
    echo "=== FORWARD (Filter Rules) ==="
    iptables -L "$CHAIN_FORWARD" -n -v --line-numbers 2>/dev/null || echo "Chain not active"
    echo ""
    echo "=== POSTROUTING (MASQUERADE Rules) ==="
    iptables -t nat -L "$CHAIN_POSTROUTING" -n -v --line-numbers 2>/dev/null || echo "Chain not active"
}

case "${1:-start}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart|reload)
        stop
        start
        ;;
    status)
        status
        ;;
    *)
        echo "Использование: $0 {start|stop|restart|reload|status}"
        exit 1
        ;;
esac
EOSCRIPT

# Подставляем реальные переменные в файл управляющего скрипта
MAPPINGS_STR=""
for m in "${PARSED_MAPPINGS[@]}"; do
    MAPPINGS_STR+="    \"$m\""$'\n'
done

sed -i "s|__TARGET_IP__|${TARGET_IP}|g" "$SCRIPT_PATH"
sed -i "s|__TAG__|${CHAIN_TAG}|g" "$SCRIPT_PATH"
sed -i "/__MAPPINGS__/c\\${MAPPINGS_STR%$'\n'}" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"

# 4. Создание systemd-юнита
echo -e "${CYAN}[4/4] Создание и запуск systemd-сервиса ${UNIT_PATH}...${NC}"
cat <<EOUNIT > "$UNIT_PATH"
[Unit]
Description=Kernel-level Traffic Forwarder (${SERVICE_NAME}) to ${TARGET_IP}
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/sysctl -w net.ipv4.ip_forward=1
ExecStart=${SCRIPT_PATH} start
ExecStop=${SCRIPT_PATH} stop
ExecReload=${SCRIPT_PATH} reload

[Install]
WantedBy=multi-user.target
EOUNIT

# Если включен UFW, открываем внешние порты
if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
    echo "Обнаружен активный UFW. Добавление внешних портов в белый список UFW..."
    for m in "${PARSED_MAPPINGS[@]}"; do
        IFS=':' read -r ext int proto <<< "$m"
        ufw allow "${ext}/${proto}" comment "${SERVICE_NAME}" >/dev/null || true
    done
fi

# Активация и запуск через systemd
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}   Сервис ${SERVICE_NAME} успешно установлен и запущен!${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "Целевой хост: ${BLUE}${TARGET_IP}${NC}"
echo -e "Маршруты проброса:"
for m in "${PARSED_MAPPINGS[@]}"; do
    IFS=':' read -r ext int proto <<< "$m"
    printf "  • Порт форвардера %-7s (%s)  --->  %s:%s\n" "${ext}" "${proto^^}" "${TARGET_IP}" "${int}"
done
echo ""
echo -e "Команды управления:"
echo -e "  Статус сервиса:   ${YELLOW}systemctl status ${SERVICE_NAME}${NC}"
echo -e "  Счётчики трафика: ${YELLOW}${SCRIPT_PATH} status${NC}"
echo -e "  Перезапуск:       ${YELLOW}systemctl restart ${SERVICE_NAME}${NC}"
echo -e "  Остановка:        ${YELLOW}systemctl stop ${SERVICE_NAME}${NC}"
echo -e "  Полное удаление:  ${YELLOW}sudo $0 -n ${SERVICE_NAME} --uninstall${NC}"
echo -e "${GREEN}================================================================${NC}"
