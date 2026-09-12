#!/usr/bin/env bash
# ==============================================================================
# install.sh — Универсальный скрипт настройки ядра и создания systemd-сервисов
# для перенаправления трафика (L4 DNAT + MASQUERADE) через сервера-форвардеры
# ==============================================================================
# Поддерживает:
#   - Запуск нескольких независимых сервисов на одном сервере
#   - Автоматическое или пользовательское уникальное имя сервиса (-n / --name)
#   - Автоматическое включение net.ipv4.ip_forward (в рантайме и персистентно)
#   - Изолированные цепочки iptables (не конфликтует с Docker, UFW и другими сервисами)
#   - TCP, UDP и BOTH протоколы
#   - Просмотр всех установленных форвардеров (--list)
# ==============================================================================

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

USER_NAME=""
SERVICE_NAME=""
TARGET_IP=""
RAW_PORTS=()
UNINSTALL=false
LIST_ALL=false

usage() {
    cat <<EOU
Использование:
  sudo $0 --target <IP_НАЗНАЧЕНИЯ> --port <ПОРТЫ> [ОПЦИИ]

Обязательные аргументы при установке:
  -t, --target <IP>          Целевой IP-адрес сервера (например, 89.23.123.4)
                             (также можно передать первым позиционным аргументом: sudo $0 89.23.123.4)
  -p, --port <ПРАВИЛО>       Порт или маппинг портов (можно указывать несколько раз)
                             Форматы:
                               25565              (TCP: 25565 -> целевой 25565)
                               24454/udp          (UDP: 24454 -> целевой 24454)
                               25565:25577/tcp    (TCP: внешний 25565 -> целевой 25577)
                               24454:30000/udp    (UDP: внешний 24454 -> целевой 30000)
                               8080:80/both       (TCP и UDP одновременно)

Опциональные аргументы:
  -n, --name <ИМЯ>           Уникальное имя сервиса (например: danki, mc, hub).
                             Если не указано, имя генерируется автоматически: forwarder-<IP>
  -l, --list                 Показать все активные сервисы-форвардеры на сервере
  -u, --uninstall            Удалить сервис и сбросить его правила iptables
  -h, --help                 Показать эту справку

Примеры:
  # Проброс на danki с уникальным именем 'danki':
  sudo $0 -n danki -t 89.23.123.4 -p 25565 -p 24454/udp

  # Проброс на другой сервер с авто-именем forwarder-1-2-3-4:
  sudo $0 -t 1.2.3.4 -p 25566:25565

  # Список всех запущенных форвардеров:
  sudo $0 --list

  # Удаление конкретного сервиса:
  sudo $0 -n danki --uninstall
EOU
    exit "${1:-0}"
}

# Проверка запроса справки или списка без root
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        usage 0
    fi
done

# Обработка флага --list (может вызываться без root)
for arg in "$@"; do
    if [[ "$arg" == "-l" || "$arg" == "--list" ]]; then
        LIST_ALL=true
        break
    fi
done

if [[ "$LIST_ALL" == true ]]; then
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}             Сервисы-форвардеры на этой машине                  ${NC}"
    echo -e "${CYAN}================================================================${NC}"
    found=false
    for s in /etc/systemd/system/forwarder-*.service /etc/systemd/system/traffic-forwarder*.service; do
        if [[ -f "$s" ]]; then
            found=true
            sname=$(basename "$s" .service)
            status=$(systemctl is-active "$sname" 2>/dev/null || echo "inactive")
            if [[ "$status" == "active" ]]; then
                status_colored="${GREEN}ACTIVE (работает)${NC}"
            else
                status_colored="${RED}${status^^} (остановлен)${NC}"
            fi
            echo -e "• Сервис: ${YELLOW}${sname}${NC} [${status_colored}]"
            script="/usr/local/bin/${sname}.sh"
            if [[ -f "$script" ]]; then
                target=$(grep -m1 '^TARGET_IP=' "$script" | cut -d'"' -f2 || true)
                echo -e "  Целевой сервер: ${BLUE}${target}${NC}"
                echo -e "  Маршруты:"
                grep -A 30 'MAPPINGS=(' "$script" | grep '^[[:space:]]*"[0-9]' | tr -d ' "' | while read -r m; do
                    IFS=':' read -r ext int proto <<< "$m"
                    printf "    - Порт форвардера %-7s (%s)  --->  %s:%s\n" "${ext}" "${proto^^}" "${target}" "${int}"
                done
            fi
            echo ""
        fi
    done
    if [[ "$found" == false ]]; then
        echo -e "${YELLOW}Сервисы-форвардеры не найдены.${NC}"
    fi
    echo -e "${CYAN}================================================================${NC}"
    exit 0
fi

# Проверка прав root для установки / удаления
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
            USER_NAME="$2"
            shift 2
            ;;
        -l|--list)
            LIST_ALL=true
            shift
            ;;
        -u|--uninstall)
            UNINSTALL=true
            shift
            ;;
        -h|--help)
            usage 0
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


# Определение имени сервиса
if [[ -n "$USER_NAME" ]]; then
    CLEAN_NAME=$(echo "$USER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    if [[ "$CLEAN_NAME" =~ ^forwarder- || "$CLEAN_NAME" == "traffic-forwarder" ]]; then
        SERVICE_NAME="$CLEAN_NAME"
    else
        SERVICE_NAME="forwarder-${CLEAN_NAME}"
    fi
elif [[ -n "$TARGET_IP" ]]; then
    IP_SLUG=$(echo "$TARGET_IP" | tr '.' '-' | tr ':' '-')
    SERVICE_NAME="forwarder-${IP_SLUG}"
else
    SERVICE_NAME="traffic-forwarder"
fi

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

# Проверка и установка iptables
if ! command -v iptables &>/dev/null; then
    echo -e "${YELLOW}[WARN] iptables не найден. Установка...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq iptables
    elif command -v dnf &>/dev/null; then
        dnf install -y iptables
    elif command -v yum &>/dev/null; then
        yum install -y iptables
    elif command -v apk &>/dev/null; then
        apk add iptables
    fi
fi

# 1. Автоматическое включение форвардинга ядра
echo -e "${CYAN}[1/4] Настройка маршрутизации ядра (sysctl)...${NC}"
SYSCTL_VAL=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
if [[ "$SYSCTL_VAL" != "1" ]]; then
    echo "Включение net.ipv4.ip_forward в рантайме..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi

SYSCTL_CONF="/etc/sysctl.d/99-ip-forward.conf"
if [[ ! -f "$SYSCTL_CONF" ]] || ! grep -q "net.ipv4.ip_forward=1" "$SYSCTL_CONF" 2>/dev/null; then
    echo "Сохранение настроек в $SYSCTL_CONF..."
    cat <<EOSYS > "$SYSCTL_CONF"
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOSYS
    sysctl --system >/dev/null 2>&1 || true
fi
echo -e "${GREEN}  ✓ IP forwarding включен и зафиксирован в sysctl${NC}"

# 2. Разбор портов и генерация тегов iptables (до 14 символов для безопасности лимита 28 байт)
echo -e "${CYAN}[2/4] Подготовка правил перенаправления для '${SERVICE_NAME}'...${NC}"
PARSED_MAPPINGS=()
RAW_TAG=$(echo "${SERVICE_NAME}" | sed 's/^forwarder-//' | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_' | cut -c 1-14)

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

    if [[ "$proto" == "both" ]]; then
        PARSED_MAPPINGS+=("${ext}:${int}:tcp")
        PARSED_MAPPINGS+=("${ext}:${int}:udp")
    else
        PARSED_MAPPINGS+=("${ext}:${int}:${proto}")
    fi
done

# 3. Генерация управляющего скрипта
echo -e "${CYAN}[3/4] Создание управляющего скрипта ${SCRIPT_PATH}...${NC}"
cat <<EOF > "$SCRIPT_PATH"
#!/usr/bin/env bash
set -euo pipefail

TARGET_IP="${TARGET_IP}"
CHAIN_PREROUTING="F_${RAW_TAG}_PRE"
CHAIN_POSTROUTING="F_${RAW_TAG}_POST"
CHAIN_OUTPUT="F_${RAW_TAG}_OUT"
CHAIN_FORWARD="F_${RAW_TAG}_FWD"

MAPPINGS=(
EOF

for m in "${PARSED_MAPPINGS[@]}"; do
    echo "    \"$m\"" >> "$SCRIPT_PATH"
done

cat <<'EOSCRIPT' >> "$SCRIPT_PATH"
)

start() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    iptables -t nat -N "$CHAIN_PREROUTING" 2>/dev/null || true
    iptables -t nat -N "$CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t nat -N "$CHAIN_OUTPUT" 2>/dev/null || true
    iptables -N "$CHAIN_FORWARD" 2>/dev/null || true

    iptables -t nat -F "$CHAIN_PREROUTING"
    iptables -t nat -F "$CHAIN_POSTROUTING"
    iptables -t nat -F "$CHAIN_OUTPUT"
    iptables -F "$CHAIN_FORWARD"

    iptables -t nat -C PREROUTING -j "$CHAIN_PREROUTING" 2>/dev/null || iptables -t nat -I PREROUTING 1 -j "$CHAIN_PREROUTING"
    iptables -t nat -C POSTROUTING -j "$CHAIN_POSTROUTING" 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j "$CHAIN_POSTROUTING"
    iptables -t nat -C OUTPUT -j "$CHAIN_OUTPUT" 2>/dev/null || iptables -t nat -I OUTPUT 1 -j "$CHAIN_OUTPUT"
    iptables -C FORWARD -j "$CHAIN_FORWARD" 2>/dev/null || iptables -I FORWARD 1 -j "$CHAIN_FORWARD"

    iptables -A "$CHAIN_FORWARD" -m state --state RELATED,ESTABLISHED -j ACCEPT

    for m in "${MAPPINGS[@]}"; do
        IFS=':' read -r ext int proto <<< "$m"
        iptables -t nat -A "$CHAIN_PREROUTING" -p "$proto" --dport "$ext" -j DNAT --to-destination "${TARGET_IP}:${int}"
        iptables -t nat -A "$CHAIN_OUTPUT" -p "$proto" --dport "$ext" -j DNAT --to-destination "${TARGET_IP}:${int}"
        iptables -A "$CHAIN_FORWARD" -p "$proto" -d "$TARGET_IP" --dport "$int" -j ACCEPT
        iptables -t nat -A "$CHAIN_POSTROUTING" -p "$proto" -d "$TARGET_IP" --dport "$int" -j MASQUERADE
    done
    echo "[OK] Forwarding rules applied for ${TARGET_IP}."
}

stop() {
    iptables -t nat -D PREROUTING -j "$CHAIN_PREROUTING" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j "$CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t nat -D OUTPUT -j "$CHAIN_OUTPUT" 2>/dev/null || true
    iptables -D FORWARD -j "$CHAIN_FORWARD" 2>/dev/null || true

    iptables -t nat -F "$CHAIN_PREROUTING" 2>/dev/null || true
    iptables -t nat -F "$CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t nat -F "$CHAIN_OUTPUT" 2>/dev/null || true
    iptables -F "$CHAIN_FORWARD" 2>/dev/null || true

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
    start) start ;;
    stop) stop ;;
    restart|reload) stop; start ;;
    status) status ;;
    *) echo "Использование: $0 {start|stop|restart|reload|status}"; exit 1 ;;
esac
EOSCRIPT

chmod +x "$SCRIPT_PATH"

# 4. Создание systemd-юнита
echo -e "${CYAN}[4/4] Создание и запуск systemd-сервиса ${UNIT_PATH}...${NC}"
cat <<EOUNIT > "$UNIT_PATH"
[Unit]
Description=Kernel Traffic Forwarder (${SERVICE_NAME}) to ${TARGET_IP}
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

if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
    echo "Обнаружен активный UFW. Открытие внешних портов в UFW..."
    for m in "${PARSED_MAPPINGS[@]}"; do
        IFS=':' read -r ext int proto <<< "$m"
        ufw allow "${ext}/${proto}" comment "${SERVICE_NAME}" >/dev/null || true
    done
fi

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}   Сервис ${SERVICE_NAME} успешно установлен и запущен!${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "Имя службы:     ${YELLOW}${SERVICE_NAME}.service${NC}"
echo -e "Целевой хост:   ${BLUE}${TARGET_IP}${NC}"
echo -e "Маршруты проброса:"
for m in "${PARSED_MAPPINGS[@]}"; do
    IFS=':' read -r ext int proto <<< "$m"
    printf "  • Порт форвардера %-7s (%s)  --->  %s:%s\n" "${ext}" "${proto^^}" "${TARGET_IP}" "${int}"
done
echo ""
echo -e "Команды управления этим сервисом:"
echo -e "  Статус:       ${YELLOW}systemctl status ${SERVICE_NAME}${NC}"
echo -e "  Счётчики:     ${YELLOW}${SCRIPT_PATH} status${NC}"
echo -e "  Перезапуск:   ${YELLOW}systemctl restart ${SERVICE_NAME}${NC}"
echo -e "  Остановка:    ${YELLOW}systemctl stop ${SERVICE_NAME}${NC}"
echo -e "  Удаление:     ${YELLOW}sudo $0 -n ${SERVICE_NAME#forwarder-} --uninstall${NC}"
echo -e "  Все сервисы:  ${YELLOW}sudo $0 --list${NC}"
echo -e "${GREEN}================================================================${NC}"
