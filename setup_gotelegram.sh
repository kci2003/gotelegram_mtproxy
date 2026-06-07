#!/bin/bash
set -euo pipefail

# --- КОНФИГУРАЦИЯ ---
# запуск
# wget -O setup_gotelegram.sh https://raw.githubusercontent.com/kci2003/gotelegram_mtproxy/main/setup_gotelegram.sh && chmod +x setup_gotelegram.sh && sudo ./setup_gotelegram.sh
ALIAS_NAME="gotelegram"
BINARY_PATH="/usr/local/bin/gotelegram"
CONFIG_DIR="/etc/gotelegram"
CONFIG_FILE="$CONFIG_DIR/config.conf"
VERSION="2.1.0"
SCRIPT_URL="https://raw.githubusercontent.com/kci2003/gotelegram/main/gotelegram.sh"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'

# --- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ---
DOCKER_CONTAINER_NAME="mtproto-proxy"
DOCKER_IMAGE="nineseconds/mtg:2"
TEMP_FILES=()
SCRIPT_ARGS=()

# --- ФУНКЦИИ ОБРАБОТКИ ОШИБОК ---
error_exit() {
    echo -e "${RED}Ошибка: $1${NC}" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}Предупреждение: $1${NC}" >&2
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

info() {
    echo -e "${CYAN}[*] $1${NC}"
}

# --- УПРАВЛЕНИЕ ВРЕМЕННЫМИ ФАЙЛАМИ ---
register_temp() {
    TEMP_FILES+=("$1")
}

cleanup() {
    for f in "${TEMP_FILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
}

trap cleanup EXIT INT TERM

# --- ПРОВЕРКА ПОРТА НА ЗАНЯТОСТЬ ---
check_port_available() {
    local port=$1
    # 'if' автоматически подавляет set -e для условия
    if ss -tuln 2>/dev/null | grep -qE ":${port}(\s|$)"; then
        echo -e "${RED}Порт $port уже используется!${NC}"
        return 1
    fi
    if docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER_NAME" && \
       docker port "$DOCKER_CONTAINER_NAME" 2>/dev/null | grep -qE ":${port}(\s|$)"; then
        echo -e "${RED}Порт $port уже используется другим контейнером!${NC}"
        return 1
    fi
    return 0
}

# --- СИСТЕМНЫЕ ПРОВЕРКИ ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "Запустите скрипт через sudo!"
    fi
}

check_docker() {
    if ! command -v systemctl &>/dev/null; then
        if ! docker info &>/dev/null; then
            warning "Docker не запущен"
            return 1
        fi
        return 0
    fi

    if ! systemctl is-active --quiet docker 2>/dev/null; then
        warning "Docker не запущен, пробуем запустить..."
        systemctl start docker 2>/dev/null || return 1
        sleep 2
    fi
    return 0
}

validate_ip() {
    local ip=$1
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS=.
        read -r a b c d <<< "$ip"
        if [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ]; then
            return 0
        fi
    fi
    return 1
}

get_ip() {
    local ip=""
    local sources=(
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ifconfig.me/ip"
    )

    for source in "${sources[@]}"; do
        ip=$(curl -s -4 --max-time 3 "$source" 2>/dev/null | tr -d '\n\r' || true)
        if [[ -n "$ip" ]] && validate_ip "$ip"; then
            echo "$ip"
            return 0
        fi
    done

    warning "Не удалось определить внешний IP"
    return 1
}

install_deps() {
    info "Проверка зависимостей..."

    if ! command -v docker &> /dev/null; then
        info "Установка Docker..."
        curl -fsSL https://get.docker.com | sh || {
            error_exit "Не удалось установить Docker"
        }

        if command -v systemctl &>/dev/null; then
            systemctl enable --now docker
        fi
        sleep 3
    fi

    if ! command -v qrencode &> /dev/null; then
        info "Установка qrencode..."
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y -qq qrencode || warning "Не удалось установить qrencode"
        elif command -v yum &> /dev/null; then
            yum install -y -q qrencode || warning "Не удалось установить qrencode"
        elif command -v apk &> /dev/null; then
            apk add --no-cache qrencode || warning "Не удалось установить qrencode"
        else
            warning "Не удалось установить qrencode (менеджер пакетов не найден)"
        fi
    fi

    if ! check_docker; then
        error_exit "Docker не запущен и не может быть запущен"
    fi

    if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
        info "Загрузка Docker образа $DOCKER_IMAGE..."
        docker pull "$DOCKER_IMAGE" || error_exit "Не удалось загрузить Docker образ"
    fi
}

update_manager() {
    # --- УСТАНОВКА МЕНЕДЖЕРА ПРИ ПЕРВОМ ЗАПУСКЕ ---
    # Если скрипт запущен не из BINARY_PATH и BINARY_PATH не существует
    if [[ ! -f "$BINARY_PATH" ]] && [[ "$0" != "$BINARY_PATH" ]]; then
        info "Первая установка менеджера в $BINARY_PATH..."

        # Создаем директорию, если её нет
        local bin_dir=$(dirname "$BINARY_PATH")
        if [[ ! -d "$bin_dir" ]]; then
            mkdir -p "$bin_dir" || error_exit "Не удалось создать директорию $bin_dir"
        fi

        # Копируем текущий скрипт
        cp "$0" "$BINARY_PATH" || error_exit "Не удалось скопировать скрипт в $BINARY_PATH"
        chmod +x "$BINARY_PATH" || error_exit "Не удалось установить права на выполнение"

        success "Менеджер установлен в $BINARY_PATH"

        # Проверяем, что установка прошла успешно
        if [[ ! -f "$BINARY_PATH" ]]; then
            error_exit "Не удалось установить менеджер: файл не создан"
        fi

        # Если скрипт запущен в интерактивном режиме, перезапускаемся
        if [[ -t 0 ]] && [[ -t 1 ]]; then
            info "Перезапуск менеджера..."
            exec "$BINARY_PATH" "${SCRIPT_ARGS[@]}"
        else
            info "Для использования менеджера запустите: sudo $ALIAS_NAME"
            exit 0
        fi
    fi

    # --- ПРОВЕРКА ОБНОВЛЕНИЙ МЕНЕДЖЕРА ---
    # Если BINARY_PATH существует и это не тот же файл, что мы запустили
    if [[ -f "$BINARY_PATH" ]] && [[ "$0" != "$BINARY_PATH" ]]; then
        local current_version=""
        local script_version=""

        # Получаем версии, || true защищает от set -e
        current_version=$(grep "^VERSION=" "$0" 2>/dev/null | cut -d'"' -f2 || true)
        script_version=$(grep "^VERSION=" "$BINARY_PATH" 2>/dev/null | cut -d'"' -f2 || true)

        # Проверяем, что версии не пустые
        if [[ -z "$current_version" ]] || [[ -z "$script_version" ]]; then
            warning "Не удалось определить версию менеджера"
        elif [[ "$current_version" != "$script_version" ]]; then
            info "Доступна новая версия менеджера ($current_version), текущая: $script_version"

            # В неинтерактивном режиме обновляемся автоматически
            local auto_update=false
            if [[ -t 0 ]] && [[ -t 1 ]]; then
                read -r -p "Обновить менеджер? (y/n): " update_choice || true
                [[ "$update_choice" == "y" ]] && auto_update=true
            else
                # Неинтерактивный режим - обновляемся автоматически с предупреждением
                warning "Неинтерактивный режим: менеджер будет обновлен автоматически"
                auto_update=false
            fi

            if [[ "$auto_update" == true ]]; then
                info "Загрузка новой версии менеджера..."

                # Создаем временный файл для загрузки
                local temp_script=""
                temp_script=$(mktemp) || error_exit "Не удалось создать временный файл"
                register_temp "$temp_script"

                # Загружаем новую версию
                if [[ -n "$SCRIPT_URL" ]]; then
                    if curl -fsSL --max-time 30 --retry 3 --retry-delay 2 "$SCRIPT_URL" -o "$temp_script" 2>/dev/null; then
                        # Проверяем, что скачанный файл - валидный скрипт
                        if grep -q "^#!/bin/bash" "$temp_script" && grep -q "^VERSION=" "$temp_script"; then
                            # Сохраняем старую версию как бэкап
                            local backup_path="${BINARY_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
                            cp "$BINARY_PATH" "$backup_path" 2>/dev/null || true
                            success "Создан бэкап: $backup_path"

                            # Заменяем скрипт
                            mv "$temp_script" "$BINARY_PATH" || error_exit "Не удалось заменить менеджер"
                            chmod +x "$BINARY_PATH" || error_exit "Не удалось установить права"

                            success "Менеджер обновлен до версии $current_version"

                            # Очищаем временный файл из списка (он уже перемещен)
                            TEMP_FILES=(${TEMP_FILES[@]/$temp_script/})

                            # Перезапускаемся с новым менеджером
                            if [[ -t 0 ]] && [[ -t 1 ]]; then
                                info "Перезапуск с новой версией менеджера..."
                                exec "$BINARY_PATH" "${SCRIPT_ARGS[@]}"
                            else
                                exit 0
                            fi
                        else
                            warning "Скачанный файл поврежден или имеет неверный формат"
                            rm -f "$temp_script" 2>/dev/null || true
                        fi
                    else
                        warning "Не удалось загрузить обновление (недоступен URL: $SCRIPT_URL)"
                    fi
                else
                    warning "URL для обновления не указан"
                fi
            fi
        fi
    fi

    # --- СОЗДАНИЕ КОНФИГУРАЦИИ ---
    # Создаем директорию конфигурации, если её нет
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR" || error_exit "Не удалось создать директорию конфигурации"
    fi

    # Проверяем, можем ли писать в директорию
    if [[ ! -w "$CONFIG_DIR" ]]; then
        error_exit "Нет прав на запись в директорию конфигурации: $CONFIG_DIR"
    fi

    # Сохраняем конфигурацию (перезаписываем существующую)
    cat > "$CONFIG_FILE" <<EOF || warning "Не удалось сохранить конфигурацию"
# GoTelegram Manager Configuration
# Автоматически сгенерировано $(date '+%Y-%m-%d %H:%M:%S')

VERSION=$VERSION
DOCKER_CONTAINER_NAME=$DOCKER_CONTAINER_NAME
DOCKER_IMAGE=$DOCKER_IMAGE
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
LAST_UPDATE=$(date '+%Y-%m-%d %H:%M:%S')

# Системная информация
HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
OS=$(uname -s 2>/dev/null || echo "unknown")
ARCH=$(uname -m 2>/dev/null || echo "unknown")
EOF

    # Устанавливаем правильные права на конфигурационный файл
    chmod 644 "$CONFIG_FILE" 2>/dev/null || true

    success "Конфигурация сохранена в $CONFIG_FILE"
}

# --- ФУНКЦИИ РАБОТЫ С ПРОКСИ ---
get_container_secret() {
    local secret=""

    # || true защищает от set -e, если grep не найдет совпадений
    secret=$(docker inspect "$DOCKER_CONTAINER_NAME" --format='{{range .Config.Cmd}}{{.}} {{end}}' 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -n 1 || true)

    if [[ -z "$secret" ]]; then
        secret=$(docker logs "$DOCKER_CONTAINER_NAME" 2>&1 | grep -oE 'secret[=:][0-9a-f]{64}' | grep -oE '[0-9a-f]{64}' | head -n 1 || true)
    fi

    if [[ -z "$secret" ]] && command -v docker &>/dev/null; then
        secret=$(docker exec "$DOCKER_CONTAINER_NAME" env 2>/dev/null | grep -oE 'MTG_SECRET=[0-9a-f]{64}' | cut -d'=' -f2 || true)
    fi

    echo "$secret"
}

get_container_port() {
    local port=""
    port=$(docker port "$DOCKER_CONTAINER_NAME" 2>/dev/null | grep -oE '[0-9]+/tcp' | cut -d'/' -f1 | head -n 1 || true)
    if [[ -z "$port" ]]; then
        port=$(docker inspect "$DOCKER_CONTAINER_NAME" --format='{{range $p, $conf := .HostConfig.PortBindings}}{{$p}}{{end}}' 2>/dev/null | grep -oE '[0-9]+' | head -n 1 || true)
    fi
    echo "${port:-443}"
}

stop_and_remove_container() {
    if docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER_NAME"; then
        info "Остановка и удаление старого контейнера..."
        docker stop "$DOCKER_CONTAINER_NAME" &>/dev/null || true
        docker rm "$DOCKER_CONTAINER_NAME" &>/dev/null || true
        success "Старый контейнер удален"
        sleep 2
    fi
}

generate_secret() {
    local domain=$1
    local secret=""

    # Пытаемся только через mtg
    if ! secret=$(docker run --rm "$DOCKER_IMAGE" generate-secret --hex "$domain" 2>/dev/null | tr -d '\n\r'); then
        error_exit "Не удалось сгенерировать Fake TLS секрет.

Для домена '$domain' требуется специальный секрет с префиксом 'ee'.
Docker образ '$DOCKER_IMAGE' не смог его создать.

Попробуйте:
1. docker pull $DOCKER_IMAGE
2. Выберите другой домен
3. Проверьте интернет соединение"
    fi

    # Валидация
    if [[ ! "$secret" =~ ^ee[0-9a-f]{62}$ ]]; then
        error_exit "Сгенерирован некорректный Fake TLS секрет: $secret"
    fi

    echo "$secret"
}

validate_tg_link() {
    local link=$1
    if [[ ! "$link" =~ ^tg://proxy\?server=[a-zA-Z0-9.-]+&port=[0-9]+&secret=[0-9a-f]{64}$ ]]; then
        return 1
    fi
    return 0
}

# --- ПАНЕЛЬ ДАННЫХ ---
show_config() {
    if ! docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER_NAME"; then
        echo -e "${RED}Прокси не найден!${NC}"
        return 1
    fi

    local secret
    secret=$(get_container_secret)
    local ip
    ip=$(get_ip) || true
    local port
    port=$(get_container_port)

    if [[ -z "$secret" ]]; then
        echo -e "${RED}Ошибка: не удалось получить секрет прокси!${NC}"
        return 1
    fi

    if [[ -z "$ip" ]]; then
        echo -e "${YELLOW}Не удалось определить внешний IP автоматически.${NC}"
        read -r -p "Введите ваш внешний IP вручную: " ip || true
        if ! validate_ip "$ip"; then
            error_exit "Некорректный IP адрес"
        fi
    fi

    local link="tg://proxy?server=$ip&port=$port&secret=$secret"

    if ! validate_tg_link "$link"; then
        warning "Сгенерирована некорректная ссылка, проверьте настройки"
    fi

    echo -e "\n${GREEN}=== ПАНЕЛЬ ДАННЫХ ===${NC}"
    echo -e "IP: ${CYAN}$ip${NC} | Port: ${CYAN}$port${NC}"
    echo -e "Secret: ${YELLOW}$secret${NC}"
    echo -e "Link: ${BLUE}$link${NC}"
    echo -e "\n${GREEN}QR-код для подключения:${NC}"

    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$link" 2>/dev/null || echo -e "${YELLOW}Не удалось создать QR-код${NC}"
    else
        echo -e "${YELLOW}qrencode не установлен, QR-код недоступен${NC}"
    fi
}

# --- УСТАНОВКА ---
menu_install() {
    clear
    echo -e "${MAGENTA}=== Установка MTProto Proxy ===${NC}\n"

    if docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER_NAME"; then
        echo -e "${YELLOW}Внимание: прокси уже установлен!${NC}"
        read -r -p "Переустановить? (y/n): " reinstall || true
        if [[ "$reinstall" != "y" ]]; then
            info "Операция отменена"
            return
        fi
        stop_and_remove_container
    fi

    echo -e "${CYAN}--- Выберите домен для маскировки (Fake TLS) ---${NC}"
    local domains=(
        "google.com" "wikipedia.org" "github.com" "cloudflare.com"
        "microsoft.com" "amazon.com" "yahoo.com" "duckduckgo.com"
        "apple.com" "vaihe.org"
    )

    for i in "${!domains[@]}"; do
        printf "${YELLOW}%2d)${NC} %-20s " "$((i+1))" "${domains[$i]}"
        if [ $(( (i+1) % 2 )) -eq 0 ] && [ $((i+1)) -ne ${#domains[@]} ]; then
            echo ""
        fi
    done
    echo -e "\n${YELLOW} 0) Свой домен${NC}"
    echo ""

    local domain=""
    while true; do
        read -r -p "Ваш выбор [0-${#domains[@]}]: " d_idx || exit 0
        if [[ "$d_idx" =~ ^[0-9]+$ ]]; then
            if [ "$d_idx" -eq 0 ]; then
                read -r -p "Введите домен (например, example.com): " domain || exit 0
                if [[ -n "$domain" ]] && [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                    break
                else
                    echo -e "${RED}Неверный формат домена!${NC}"
                fi
            elif [ "$d_idx" -ge 1 ] && [ "$d_idx" -le ${#domains[@]} ]; then
                domain="${domains[$((d_idx-1))]}"
                break
            else
                echo -e "${RED}Неверный выбор!${NC}"
            fi
        else
            echo -e "${RED}Введите число!${NC}"
        fi
    done

    echo -e "\n${CYAN}--- Выберите порт ---${NC}"
    echo -e "1) 443 (Рекомендуется)"
    echo -e "2) 8443"
    echo -e "3) 9443"
    echo -e "4) Свой порт"

    local port=""
    while true; do
        read -r -p "Выбор [1-4]: " p_choice || exit 0
        case $p_choice in
            1) port=443; break ;;
            2) port=8443; break ;;
            3) port=9443; break ;;
            4)
                while true; do
                    read -r -p "Введите свой порт (1-65535): " port || exit 0
                    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                        break
                    else
                        echo -e "${RED}Ошибка: введите число от 1 до 65535${NC}"
                    fi
                done
                break
                ;;
            *)
                echo -e "${RED}Неверный выбор!${NC}"
                ;;
        esac
    done

    if ! check_port_available "$port"; then
        echo -e "${YELLOW}Порт занят, выберите другой порт${NC}"
        read -r -p "Нажмите Enter чтобы продолжить..." || true
        return
    fi

    info "Генерация секрета для домена $domain..."
    local secret
    secret=$(generate_secret "$domain")
    if [[ -z "$secret" ]]; then
        error_exit "Не удалось сгенерировать секрет!"
    fi

    info "Запуск прокси на порту $port..."
    local temp_log
    temp_log=$(mktemp)
    register_temp "$temp_log"

    if docker run -d \
        --name "$DOCKER_CONTAINER_NAME" \
        --restart always \
        -p "$port:$port" \
        "$DOCKER_IMAGE" \
        simple-run -n 1.1.1.1 -i prefer-ipv4 0.0.0.0:"$port" "$secret" > "$temp_log" 2>&1; then

        success "Прокси успешно запущен"
        sleep 3

        if ! docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER_NAME"; then
            echo -e "${RED}Контейнер запустился, но не работает!${NC}"
            docker logs "$DOCKER_CONTAINER_NAME" --tail 20 || true
            docker rm -f "$DOCKER_CONTAINER_NAME" &>/dev/null || true
            read -r -p "Нажмите Enter..." || true
            return
        fi
    else
        echo -e "${RED}Ошибка запуска прокси!${NC}"
        echo -e "${YELLOW}Логи ошибки:${NC}"
        cat "$temp_log" || true
        docker rm -f "$DOCKER_CONTAINER_NAME" &>/dev/null || true
        read -r -p "Нажмите Enter..." || true
        return
    fi

    clear
    show_config
    echo -e "\n${GREEN}✓ Установка завершена!${NC}"
    read -r -p "Нажмите Enter..." || true
}

# --- УДАЛЕНИЕ ---
menu_uninstall() {
    clear
    if ! docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER_NAME"; then
        echo -e "${YELLOW}Прокси не найден${NC}"
        read -r -p "Нажмите Enter..." || true
        return
    fi

    echo -e "${RED}⚠️  ВНИМАНИЕ: будет удален MTProto Proxy ⚠️${NC}"
    echo -e "${YELLOW}Будут удалены:${NC}"
    echo -e "  • Docker контейнер $DOCKER_CONTAINER_NAME"
    echo -e "  • Все данные прокси"
    echo ""
    read -r -p "Точно удалить? (y/n): " confirm || exit 0

    if [[ "$confirm" == "y" ]]; then
        stop_and_remove_container
        success "Прокси удален"

        read -r -p "Удалить конфигурацию менеджера? (y/n): " rm_config || exit 0
        if [[ "$rm_config" == "y" ]]; then
            rm -rf "$CONFIG_DIR"
            success "Конфигурация удалена"
        fi
    else
        info "Операция отменена"
    fi
    read -r -p "Нажмите Enter..." || true
}

# --- ЛОГИ ---
show_logs() {
    if ! docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER_NAME"; then
        echo -e "${RED}Прокси не найден!${NC}"
        read -r -p "Нажмите Enter..." || true
        return
    fi

    clear
    echo -e "${MAGENTA}=== ЛОГИ ПРОКСИ ===${NC}\n"

    local lines=30
    if [[ "${1:-}" == "all" ]] || [[ "${1:-}" == "-a" ]]; then
        lines="all"
        info "Показаны все логи (нажмите Ctrl+C для выхода)"
    fi

    if [[ "$lines" == "all" ]]; then
        if command -v less &>/dev/null; then
            docker logs "$DOCKER_CONTAINER_NAME" 2>&1 | less -R || true
        else
            docker logs "$DOCKER_CONTAINER_NAME" 2>&1 | cat || true
        fi
    else
        docker logs "$DOCKER_CONTAINER_NAME" --tail "$lines" 2>/dev/null || echo -e "${YELLOW}Логи недоступны${NC}"
        echo -e "\n${CYAN}Для просмотра всех логов используйте: $ALIAS_NAME logs -a${NC}"
        echo -e "${CYAN}Для выхода нажмите Enter...${NC}"
        read -r -p "" || true
    fi
}

# --- О СКРИПТЕ ---
show_about() {
    clear
    echo -e "${MAGENTA}=== О программе ===${NC}\n"
    echo -e "${CYAN}GoTelegram Manager v$VERSION${NC}"
    echo -e "\n${YELLOW}Описание:${NC}"
    echo -e "Утилита для установки и управления MTProto прокси"
    echo -e "с поддержкой Fake TLS маскировки трафика."
    echo -e "\n${YELLOW}Возможности:${NC}"
    echo -e "• Установка/переустановка прокси"
    echo -e "• Автоматическое обновление менеджера"
    echo -e "• Просмотр данных подключения (IP, порт, секрет)"
    echo -e "• Генерация QR-кодов для быстрого подключения"
    echo -e "• Просмотр логов контейнера"
    echo -e "• Полное удаление прокси"
    echo -e "\n${YELLOW}Лицензия:${NC} MIT"
    echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
    read -r -p "" || true
}

# --- ВЫХОД ---
show_exit() {
    clear
    echo -e "${GREEN}=== Текущие данные прокси ===${NC}"
    show_config || true
    echo -e "\n${GREEN}Спасибо за использование! До свидания!${NC}"
    exit 0
}

# --- ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ ---
parse_arguments() {
    case "${1:-}" in
        install|i)
            menu_install
            exit 0
            ;;
        remove|r|uninstall)
            menu_uninstall
            exit 0
            ;;
        show|s|config)
            clear
            show_config
            exit 0
            ;;
        logs|l)
            show_logs "${2:-}"
            exit 0
            ;;
        about|version|-v|--version)
            show_about
            exit 0
            ;;
        help|-h|--help)
            echo -e "${CYAN}Использование: $ALIAS_NAME [КОМАНДА]${NC}"
            echo -e "\n${YELLOW}Команды:${NC}"
            echo -e "  install, i    - Установить/обновить прокси"
            echo -e "  remove, r     - Удалить прокси"
            echo -e "  show, s       - Показать данные подключения"
            echo -e "  logs, l       - Показать логи (logs -a для всех логов)"
            echo -e "  about, -v     - Информация о программе"
            echo -e "  help          - Показать эту справку"
            echo -e "\n${YELLOW}Без аргументов запускается интерактивное меню${NC}"
            exit 0
            ;;
        "")
            ;;
        *)
            echo -e "${RED}Неизвестная команда: $1${NC}"
            echo -e "Используйте '$ALIAS_NAME help' для списка команд"
            exit 1
            ;;
    esac
}

# --- СТАРТ СКРИПТА ---
main() {
    SCRIPT_ARGS=("$@")

    check_root
    update_manager
    install_deps

    parse_arguments "$@"

    while true; do
        echo -e "\n${MAGENTA}=== GoTelegram Manager v$VERSION ===${NC}"
        echo -e "1) ${GREEN}Установить / Переустановить прокси${NC}"
        echo -e "2) ${CYAN}Показать данные подключения${NC}"
        echo -e "3) ${BLUE}Показать логи прокси${NC}"
        echo -e "4) ${RED}Удалить прокси${NC}"
        echo -e "5) ${WHITE}О программе${NC}"
        echo -e "0) ${WHITE}Выход${NC}"
        echo -e "${MAGENTA}----------------------------------------${NC}"
        # || exit 0 корректно обрабатывает Ctrl+D (EOF)
        read -r -p "Ваш выбор: " m_idx || exit 0

        case $m_idx in
            1) menu_install ;;
            2)
                clear
                show_config
                read -r -p "Нажмите Enter..." || true
                ;;
            3) show_logs ;;
            4) menu_uninstall ;;
            5) show_about ;;
            0) show_exit ;;
            *)
                echo -e "${RED}Неверный ввод! Пожалуйста, выберите 0-5${NC}"
                sleep 1
                ;;
        esac
    done
}

main "$@"