#!/bin/bash
# ============================================================
#  SSTP VPN Client Setup — AlmaLinux 9
#  - sstp-client + pppd, TLS/443 transport
#  - БЕЗ defaultroute (SSH не отвалится)
#  - Маршруты через ppp0 по списку
#
#  Методы сборки:
#    native  — собрать прямо на хосте (ставит ~200МБ dev-пакетов)
#    docker  — собрать в контейнере podman/docker (на хосте только
#              runtime-библиотеки, dev-мусор остаётся в образе)
#
#  Режимы:
#    sudo ./sstp-setup.sh                    # меню
#    sudo ./sstp-setup.sh install            # установка (спросит метод)
#    sudo ./sstp-setup.sh install --docker   # установка через контейнер
#    sudo ./sstp-setup.sh install --native   # установка на хост
#    sudo ./sstp-setup.sh install --dry-run  # показать что будет сделано
#    sudo ./sstp-setup.sh uninstall [--dry-run]
#    sudo ./sstp-setup.sh uninstall --purge  # удалить всё сразу (включая
#                                             # бинарник и dev-пакеты)
# ============================================================

set -e

# ── Цвета и логгеры ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header()  { echo -e "\n${BOLD}=== $1 ===${NC}"; }
dry()     { echo -e "${YELLOW}[DRY]${NC}   $*"; }

# ── Константы ──
MARKER_DIR="/etc/sstp-setup"
MARKER_FILE="${MARKER_DIR}/installed.conf"

SSTP_VERSION="1.0.20"
SSTP_SRC_URL="https://gitlab.com/sstp-project/sstp-client/-/archive/${SSTP_VERSION}/sstp-client-${SSTP_VERSION}.tar.gz"

# Ожидаемый SHA256 исходников. Оставьте пустым чтобы пропустить проверку
# (но тогда вы доверяете HTTPS + GitLab без дополнительного контроля).
# Получить эталон можно на доверенной машине:
#   curl -sSL "$SSTP_SRC_URL" | sha256sum
# и вписать сюда.
SSTP_SHA256="9150c96c61c71aa3fd0ac7c2b95f60cecb8bf761febb07e00e34794c47eac9fa"

SSTP_PREFIX="/usr/local"
SSTP_BIN="${SSTP_PREFIX}/sbin/sstpc"
SSTP_RUNTIME_DIR="/var/run/sstpc"
DOCKER_IMAGE_TAG="sstp-builder:${SSTP_VERSION}"

# ── Флаги режима ──
DRY_RUN=0
BUILD_METHOD=""   # native | docker | (пусто → спросим)
PURGE=0
ACTION=""         # install | uninstall

# ────────────────────────────────────────────────
# run_cmd: выполнить команду или показать в dry-run
# ────────────────────────────────────────────────
run_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        dry "$*"
    else
        eval "$@"
    fi
}

# ────────────────────────────────────────────────
# parse_args
# ────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|uninstall|remove|menu)
                ACTION="$1"
                [[ "$ACTION" == "remove" ]] && ACTION="uninstall"
                ;;
            --dry-run|-n)    DRY_RUN=1 ;;
            --native)        BUILD_METHOD="native" ;;
            --docker|--podman) BUILD_METHOD="docker" ;;
            --purge)         PURGE=1 ;;
            -h|--help)
                sed -n '2,22p' "$0" | sed 's/^# \?//'
                exit 0
                ;;
            *)
                error "Неизвестный аргумент: $1 (--help для справки)"
                ;;
        esac
        shift
    done
}

# ────────────────────────────────────────────────
# Проверки окружения
# ────────────────────────────────────────────────
check_env() {
    [[ $EUID -ne 0 ]] && error "Запустите скрипт от root: sudo $0"

    if ! grep -q sbin <<< "$PATH"; then
        export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"
    fi

    [[ ! -f /etc/os-release ]] && error "Не удалось определить ОС"
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"

    case "$OS_ID" in
        almalinux|rocky|rhel|centos)
            MAJOR_VER="${OS_VERSION%%.*}"
            [[ "$MAJOR_VER" != "9" ]] && warn "Тестировалось на EL 9.x. Ваша: $OS_VERSION"
            ;;
        *)
            error "Рассчитан на AlmaLinux/Rocky/RHEL/CentOS 9. Ваша ОС: $OS_ID"
            ;;
    esac

    [[ "$DRY_RUN" == "1" ]] && warn "═══ DRY-RUN: ничего реально не делаем ═══"

    if systemd-detect-virt --container &>/dev/null; then
        warn "Контейнер ($(systemd-detect-virt)) — в LXC/Docker ppp может не работать"
        if [[ "$DRY_RUN" == "0" ]]; then
            read -p "Продолжить? [y/N]: " cont
            [[ ! "$cont" =~ ^[Yy]$ ]] && exit 0
        fi
    fi
}

# ────────────────────────────────────────────────
# Обнаружение container runtime
# ────────────────────────────────────────────────
detect_container_runtime() {
    if command -v podman &>/dev/null; then
        CRT="podman"
        return 0
    elif command -v docker &>/dev/null; then
        CRT="docker"
        return 0
    fi
    return 1
}

# ────────────────────────────────────────────────
# Проверка кириллицы в логине
# ────────────────────────────────────────────────
check_cyrillic() {
    local val="$1" label="$2"
    if echo -n "$val" | grep -qP '[\x{0400}-\x{04FF}]' 2>/dev/null; then
        warn "В '$label' кириллица! SSTP-серверы обычно ждут ASCII."
        warn "Проверьте раскладку (с/s, е/e, о/o)."
        [[ "$DRY_RUN" == "0" ]] && {
            read -p "Продолжить? [y/N]: " cont
            [[ ! "$cont" =~ ^[Yy]$ ]] && error "Отменено"
        }
    fi
}

# ────────────────────────────────────────────────
# Выбор метода сборки
# ────────────────────────────────────────────────
choose_build_method() {
    if [[ -n "$BUILD_METHOD" ]]; then
        info "Метод сборки: $BUILD_METHOD (из флага)"
        return 0
    fi

    if detect_container_runtime; then
        info "Найден container runtime: $CRT"
        echo
        echo "Метод сборки sstp-client:"
        echo "  1) Docker/Podman  — сборка в контейнере (рекомендуется)"
        echo "                      На хост — только runtime-библиотеки (~10МБ)"
        echo "                      Весь dev-мусор остаётся в образе и удаляется"
        echo "  2) Native         — сборка прямо на хосте"
        echo "                      Ставит Development Tools + -devel (~200МБ)"
        read -p "Выбор [1]: " bm
        case "${bm:-1}" in
            1) BUILD_METHOD="docker" ;;
            2) BUILD_METHOD="native" ;;
            *) error "Неверный выбор" ;;
        esac
    else
        warn "podman/docker не найдены — используем native сборку"
        warn "Для контейнерной сборки: dnf install -y podman"
        BUILD_METHOD="native"
    fi
}

# ────────────────────────────────────────────────
# Проверка SHA256
# ────────────────────────────────────────────────
verify_sha256() {
    local file="$1" expected="$2"
    if [[ -z "$expected" ]]; then
        warn "SSTP_SHA256 не задан — проверка целостности пропущена"
        warn "Источник: $SSTP_SRC_URL"
        warn "Для параноиков: вычислите хэш на доверенной машине и впишите в SSTP_SHA256"
        return 0
    fi
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        error "SHA256 mismatch!\n  Ожидалось: $expected\n  Получено:  $actual"
    fi
    success "SHA256 проверен: $actual"
}

# ────────────────────────────────────────────────
# Версия pppd (для plugin dir)
# ────────────────────────────────────────────────
get_pppd_version() {
    if ! command -v pppd &>/dev/null; then
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "2.4.9"
            return
        fi
        error "pppd не установлен: dnf install -y ppp"
    fi
    local v
    v=$(pppd --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "${v:-2.4.9}"
}

# ════════════════════════════════════════════════
# NATIVE сборка
# ════════════════════════════════════════════════
build_native() {
    header "Установка зависимостей (native)"

    run_cmd "dnf install -y dnf-plugins-core epel-release"

    # Включаем CRB / PowerTools / CodeReady — в нём живут -devel пакеты на EL 9
    info "Включаем CRB (CodeReady Builder) — он нужен для ppp-devel..."
    if dnf config-manager --set-enabled crb 2>/dev/null; then
        success "CRB репо включён"
    elif dnf config-manager --set-enabled powertools 2>/dev/null; then
        success "PowerTools репо включён"
    elif command -v subscription-manager &>/dev/null && \
         subscription-manager repos --enable "codeready-builder-for-rhel-9-$(arch)-rpms" 2>/dev/null; then
        success "CodeReady Builder репо включён (RHEL)"
    else
        warn "Не удалось автоматически включить CRB/PowerTools."
        warn "Если ppp-devel не найдётся — включите вручную:"
        warn "  dnf config-manager --set-enabled crb"
    fi

    run_cmd "dnf groupinstall -y 'Development Tools'"
    run_cmd "dnf install -y ppp ppp-devel openssl-devel libevent-devel \
                            pkgconfig wget tar autoconf automake libtool \
                            iproute iptables"

    success "Зависимости установлены"

    header "Сборка sstp-client ${SSTP_VERSION}"

    if [[ -x "$SSTP_BIN" && "$DRY_RUN" == "0" ]]; then
        info "sstpc уже установлен: $SSTP_BIN"
        read -p "Пересобрать? [y/N]: " rebuild
        [[ ! "$rebuild" =~ ^[Yy]$ ]] && { success "Пропускаем сборку"; return 0; }
    fi

    PPPD_VER=$(get_pppd_version)
    PPPD_PLUGIN_DIR="/usr/lib64/pppd/${PPPD_VER}"
    info "pppd версия: $PPPD_VER → плагины в $PPPD_PLUGIN_DIR"

    if [[ "$DRY_RUN" == "1" ]]; then
        dry "скачать $SSTP_SRC_URL"
        dry "проверить SHA256 (если задан)"
        dry "./configure --prefix=${SSTP_PREFIX} --with-pppd-plugin-dir=${PPPD_PLUGIN_DIR}"
        dry "make && make install"
        SSTP_PLUGIN_PATH="${PPPD_PLUGIN_DIR}/sstp-pppd-plugin.so"
        return 0
    fi

    BUILD_DIR="/tmp/sstp-build-$$"
    trap "rm -rf $BUILD_DIR" EXIT
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    info "Скачиваем ${SSTP_VERSION}..."
    wget -q --show-progress "$SSTP_SRC_URL" -O sstp.tar.gz \
        || error "Не удалось скачать"

    verify_sha256 sstp.tar.gz "$SSTP_SHA256"

    tar xf sstp.tar.gz
    cd sstp-client-${SSTP_VERSION}

    info "autoreconf..."
    autoreconf --install --force 2>&1 | tail -5

    info "./configure..."
    ./configure \
        --prefix=${SSTP_PREFIX} \
        --disable-static \
        --with-runtime-dir=${SSTP_RUNTIME_DIR} \
        --with-pppd-plugin-dir=${PPPD_PLUGIN_DIR} 2>&1 | tail -15

    info "make..."
    make -j$(nproc) 2>&1 | tail -5

    info "make install..."
    make install 2>&1 | tail -5

    mkdir -p "$SSTP_RUNTIME_DIR"
    chmod 755 "$SSTP_RUNTIME_DIR"
    cd /
    rm -rf "$BUILD_DIR"
    trap - EXIT

    [[ ! -x "$SSTP_BIN" ]] && error "$SSTP_BIN не создан"

    SSTP_PLUGIN_PATH="${PPPD_PLUGIN_DIR}/sstp-pppd-plugin.so"
    [[ ! -f "$SSTP_PLUGIN_PATH" ]] && SSTP_PLUGIN_PATH=$(find /usr/local/lib /usr/lib /usr/lib64 -name 'sstp-pppd-plugin.so' 2>/dev/null | head -1)
    [[ ! -f "$SSTP_PLUGIN_PATH" ]] && error "sstp-pppd-plugin.so не найден"

    success "sstpc:  $SSTP_BIN"
    success "plugin: $SSTP_PLUGIN_PATH"
}

# ════════════════════════════════════════════════
# DOCKER/PODMAN сборка
# ════════════════════════════════════════════════
build_docker() {
    header "Сборка в контейнере"

    if ! detect_container_runtime; then
        error "podman/docker не найдены. Установите: dnf install -y podman"
    fi
    info "Используем: $CRT"

    PPPD_VER=$(get_pppd_version)
    PPPD_PLUGIN_DIR="/usr/lib64/pppd/${PPPD_VER}"
    info "pppd на хосте: $PPPD_VER"

    info "Установка runtime-библиотек на хост (маленькие, обычно уже стоят)..."
    run_cmd "dnf install -y ppp openssl-libs libevent iproute iptables"

    if [[ "$DRY_RUN" == "1" ]]; then
        dry "создать Dockerfile в /tmp/sstp-docker-XXX"
        dry "$CRT build --build-arg PPPD_VERSION=$PPPD_VER -t $DOCKER_IMAGE_TAG ."
        dry "$CRT run --rm $DOCKER_IMAGE_TAG > /tmp/artifacts.tar"
        dry "tar -C / -xf /tmp/artifacts.tar (установить sstpc и плагин)"
        dry "$CRT rmi $DOCKER_IMAGE_TAG (удалить образ сборщик ~500МБ)"
        SSTP_PLUGIN_PATH="${PPPD_PLUGIN_DIR}/sstp-pppd-plugin.so"
        return 0
    fi

    BUILD_DIR="/tmp/sstp-docker-$$"
    trap "rm -rf $BUILD_DIR" EXIT
    mkdir -p "$BUILD_DIR"

    # ── Dockerfile (multi-stage) ──
    cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM almalinux:9 AS builder

ARG PPPD_VERSION=${PPPD_VER}
ARG SSTP_VERSION=${SSTP_VERSION}
ARG SSTP_URL=${SSTP_SRC_URL}
ARG SSTP_SHA256=${SSTP_SHA256}

RUN dnf install -y dnf-plugins-core epel-release && \\
    (dnf config-manager --set-enabled crb || \\
     dnf config-manager --set-enabled powertools || \\
     subscription-manager repos --enable codeready-builder-for-rhel-9-\$(arch)-rpms || \\
     true) && \\
    dnf groupinstall -y "Development Tools" && \\
    dnf install -y ppp-devel openssl-devel libevent-devel \\
                   autoconf automake libtool pkgconfig wget tar && \\
    dnf clean all

WORKDIR /build

RUN wget -q "\$SSTP_URL" -O sstp.tar.gz && \\
    if [ -n "\$SSTP_SHA256" ]; then \\
        echo "\$SSTP_SHA256  sstp.tar.gz" | sha256sum -c -; \\
    else \\
        echo "WARNING: SSTP_SHA256 not set"; \\
    fi && \\
    tar xf sstp.tar.gz && \\
    cd sstp-client-\${SSTP_VERSION} && \\
    autoreconf --install --force && \\
    ./configure \\
        --prefix=${SSTP_PREFIX} \\
        --disable-static \\
        --with-runtime-dir=${SSTP_RUNTIME_DIR} \\
        --with-pppd-plugin-dir=/usr/lib64/pppd/\${PPPD_VERSION} && \\
    make -j\$(nproc) && \\
    mkdir -p /artifacts && \\
    make install DESTDIR=/artifacts

# Минимальный финальный stage — только артефакты
FROM almalinux:9
COPY --from=builder /artifacts /artifacts
CMD ["tar", "-C", "/artifacts", "-cf", "-", "."]
EOF

    cd "$BUILD_DIR"

    info "Сборка образа (первый запуск ~3-5 минут)..."
    $CRT build -t "$DOCKER_IMAGE_TAG" . || error "Не удалось собрать образ"

    info "Извлекаем артефакты..."
    ARTIFACTS_TAR="/tmp/sstp-artifacts-$$.tar"
    $CRT run --rm "$DOCKER_IMAGE_TAG" > "$ARTIFACTS_TAR" \
        || error "Не удалось извлечь артефакты"

    info "Устанавливаем в систему..."
    tar -C / -xf "$ARTIFACTS_TAR"
    rm -f "$ARTIFACTS_TAR"

    mkdir -p "$SSTP_RUNTIME_DIR"
    chmod 755 "$SSTP_RUNTIME_DIR"

    info "Удаляем образ сборщик ($CRT rmi $DOCKER_IMAGE_TAG)..."
    $CRT rmi "$DOCKER_IMAGE_TAG" 2>/dev/null \
        || warn "Не удалось удалить образ: $CRT rmi $DOCKER_IMAGE_TAG"

    cd /
    rm -rf "$BUILD_DIR"
    trap - EXIT

    [[ ! -x "$SSTP_BIN" ]] && error "$SSTP_BIN не извлечён"

    SSTP_PLUGIN_PATH="${PPPD_PLUGIN_DIR}/sstp-pppd-plugin.so"
    [[ ! -f "$SSTP_PLUGIN_PATH" ]] && SSTP_PLUGIN_PATH=$(find /usr/local/lib /usr/lib /usr/lib64 -name 'sstp-pppd-plugin.so' 2>/dev/null | head -1)
    [[ ! -f "$SSTP_PLUGIN_PATH" ]] && error "sstp-pppd-plugin.so не установлен"

    success "sstpc:  $SSTP_BIN"
    success "plugin: $SSTP_PLUGIN_PATH"
    success "Dev-пакеты на хост не попали"
}

# ────────────────────────────────────────────────
# Конфиги PPP + credentials + hooks
# ────────────────────────────────────────────────
create_configs() {
    header "Конфигурация подключения"

    PEER_FILE="/etc/ppp/peers/${CONN_NAME}"
    CRED_FILE="${MARKER_DIR}/${CONN_NAME}.creds"
    IPUP_HOOK="/etc/ppp/ip-up.d/${CONN_NAME}-routes"
    IPDOWN_HOOK="/etc/ppp/ip-down.d/${CONN_NAME}-routes"
    PID_FILE="${MARKER_DIR}/${CONN_NAME}.pid"

    if [[ "$DRY_RUN" == "1" ]]; then
        dry "mkdir -p /etc/ppp/peers /etc/ppp/ip-up.d /etc/ppp/ip-down.d $MARKER_DIR"
        dry "создать $PEER_FILE (PPP peer, 600)"
        dry "создать $CRED_FILE (credentials, 600)"
        dry "создать $IPUP_HOOK (755)"
        dry "создать $IPDOWN_HOOK (755)"
        return 0
    fi

    mkdir -p /etc/ppp/peers /etc/ppp/ip-up.d /etc/ppp/ip-down.d "$MARKER_DIR"
    chmod 700 "$MARKER_DIR"

    info "PPP peer: $PEER_FILE"
    # Каноническая схема (как в man sstpc и upstream README):
    # pppd запускает sstpc через pty-команду. Тогда unix-сокет между
    # sstpc и sstp-pppd-plugin создаётся правильно: sstpc стартует первым,
    # биндит сокет, потом плагин в pppd к нему подключается за MPPE-ключами.
    SSTP_PTY_OPTS="--ipparam ${CONN_NAME} --nolaunchpppd --tls-ext --save-server-route"
    [[ -n "$VPN_CA_CERT" && -f "$VPN_CA_CERT" ]] && SSTP_PTY_OPTS="$SSTP_PTY_OPTS --ca-cert $VPN_CA_CERT"
    [[ -z "$VPN_CA_CERT" ]] && SSTP_PTY_OPTS="$SSTP_PTY_OPTS --cert-warn"

    cat > "$PEER_FILE" <<EOF
# SSTP VPN: ${CONN_NAME} — sstp-setup.sh $(date +%Y-%m-%d)
# Схема: pppd → pty(sstpc --nolaunchpppd) → sstp-pppd-plugin

remotename      ${CONN_NAME}
linkname        ${CONN_NAME}
ipparam         ${CONN_NAME}

# Pty-команда запускает sstpc, который и есть транспорт PPP-кадров.
# Логин — здесь (через name), пароль — в /etc/ppp/chap-secrets.
pty             "${SSTP_BIN} ${SSTP_PTY_OPTS} --log-syslog --log-level 2 ${VPN_SERVER}:${VPN_PORT}"

plugin          ${SSTP_PLUGIN_PATH}
sstp-sock       ${SSTP_RUNTIME_DIR}/sstpc-${CONN_NAME}

name            "${VPN_USER}"
remotename      ${CONN_NAME}

# Только MS-CHAPv2, остальное запрещаем
refuse-pap
refuse-eap
refuse-chap
refuse-mschap
require-mschap-v2

# MPPE НЕ требуем — SSTP уже зашифрован TLS снаружи, MPPE избыточен.
# Многие серверы (включая MikroTik с encryption=no) реджектят CCP, что
# с require-mppe приводит к разрыву. С noccp/nomppe всё работает.
# Если ваш сервер требует MPPE — закомментируйте noccp/nomppe и раскомментируйте require-mppe.
noccp
nomppe
# require-mppe
noauth

# НЕТ defaultroute / usepeerdns — трафик не перехватывается
mtu             1400
mru             1400

nobsdcomp
nodeflate
novj
novjccomp

# pppd сам пишет лог в syslog с тегом pppd
debug
lock
persist
maxfail         3
EOF
    chmod 600 "$PEER_FILE"

    # ── chap-secrets — пароль для MS-CHAPv2 ──
    # Формат: client server secret IP-addresses
    # client = name из peer-файла, server = remotename
    CHAP_SECRETS="/etc/ppp/chap-secrets"
    info "Добавляем запись в $CHAP_SECRETS"

    # Бэкап если впервые трогаем
    [[ -f "$CHAP_SECRETS" && ! -f "${CHAP_SECRETS}.sstp-setup-backup" ]] && \
        cp "$CHAP_SECRETS" "${CHAP_SECRETS}.sstp-setup-backup"

    # Удаляем старые записи для этого пользователя/remotename (на случай переустановки)
    if [[ -f "$CHAP_SECRETS" ]]; then
        # Помечаем нашу запись комментарием для лёгкого удаления
        sed -i "/# sstp-setup: ${CONN_NAME}/,+1d" "$CHAP_SECRETS"
    else
        touch "$CHAP_SECRETS"
        chmod 600 "$CHAP_SECRETS"
    fi

    # Экранируем спецсимволы в пароле для chap-secrets
    # (chap-secrets не использует bash escape, кавычки внутри пароля надо удвоить)
    CHAP_PASSWORD_ESC="${VPN_PASSWORD//\"/\\\"}"
    cat >> "$CHAP_SECRETS" <<EOF
# sstp-setup: ${CONN_NAME}
${VPN_USER}	${CONN_NAME}	"${CHAP_PASSWORD_ESC}"	*
EOF
    chmod 600 "$CHAP_SECRETS"

    info "credentials: $CRED_FILE"
    cat > "$CRED_FILE" <<EOF
SSTP_SERVER="${VPN_SERVER}"
SSTP_PORT="${VPN_PORT}"
SSTP_USER="${VPN_USER}"
SSTP_PASSWORD="${VPN_PASSWORD}"
SSTP_ROUTES="${VPN_ROUTES}"
SSTP_CA_CERT="${VPN_CA_CERT}"
EOF
    chmod 600 "$CRED_FILE"

    info "ip-up: $IPUP_HOOK"
    cat > "$IPUP_HOOK" <<EOF
#!/bin/bash
# ip-up: \$1=iface \$6=ipparam
CONN_NAME_EXPECT="${CONN_NAME}"
PPP_IFNAME="\$1"
[[ "\$6" != "\$CONN_NAME_EXPECT" ]] && exit 0

CRED_FILE="${CRED_FILE}"
[[ -f "\$CRED_FILE" ]] && . "\$CRED_FILE"

logger -t sstp-${CONN_NAME} "Tunnel up on \$PPP_IFNAME (local \$4)"

IFS=',' read -ra ROUTES <<< "\$SSTP_ROUTES"
for R in "\${ROUTES[@]}"; do
    R="\${R// /}"; [[ -z "\$R" ]] && continue
    ip route add "\$R" dev "\$PPP_IFNAME" 2>/dev/null \\
        && logger -t sstp-${CONN_NAME} "Route \$R added" \\
        || logger -t sstp-${CONN_NAME} "Route \$R not added (maybe exists)"
done
exit 0
EOF
    chmod 755 "$IPUP_HOOK"

    info "ip-down: $IPDOWN_HOOK"
    cat > "$IPDOWN_HOOK" <<EOF
#!/bin/bash
CONN_NAME_EXPECT="${CONN_NAME}"
PPP_IFNAME="\$1"
[[ "\$6" != "\$CONN_NAME_EXPECT" ]] && exit 0

CRED_FILE="${CRED_FILE}"
[[ -f "\$CRED_FILE" ]] && . "\$CRED_FILE"

logger -t sstp-${CONN_NAME} "Tunnel down on \$PPP_IFNAME"

IFS=',' read -ra ROUTES <<< "\$SSTP_ROUTES"
for R in "\${ROUTES[@]}"; do
    R="\${R// /}"; [[ -z "\$R" ]] && continue
    ip route del "\$R" dev "\$PPP_IFNAME" 2>/dev/null || true
done
exit 0
EOF
    chmod 755 "$IPDOWN_HOOK"

    success "Конфиги созданы"
}

# ────────────────────────────────────────────────
# sstp-up / sstp-down / sstp-status с PID-файлом
# ────────────────────────────────────────────────
create_commands() {
    header "Команды управления"

    if [[ "$DRY_RUN" == "1" ]]; then
        dry "создать /usr/local/bin/sstp-up (PID пишется в $PID_FILE)"
        dry "создать /usr/local/bin/sstp-down (kill по PID из файла, fallback — по /proc/*/cmdline)"
        dry "создать /usr/local/bin/sstp-status"
        dry "создать /usr/local/bin/sstp-route (add/del/list/reload/flush)"
        return 0
    fi

    # ── sstp-up ──
    cat > /usr/local/bin/sstp-up <<EOF
#!/bin/bash
# Запуск SSTP VPN '${CONN_NAME}'
set -e

CRED_FILE="${CRED_FILE}"
CONN_NAME="${CONN_NAME}"
SSTP_BIN="${SSTP_BIN}"
PID_FILE="${PID_FILE}"
RUNTIME_DIR="${SSTP_RUNTIME_DIR}"

[[ \$EUID -ne 0 ]] && { echo "Запустите через sudo"; exit 1; }
[[ ! -f "\$CRED_FILE" ]] && { echo "Credentials не найдены: \$CRED_FILE"; exit 1; }
. "\$CRED_FILE"

# Защита от двойного запуска — проверка PID
if [[ -f "\$PID_FILE" ]]; then
    OLD_PID=\$(cat "\$PID_FILE" 2>/dev/null)
    if [[ -n "\$OLD_PID" ]] && kill -0 "\$OLD_PID" 2>/dev/null; then
        echo "VPN '\$CONN_NAME' уже запущен (PID \$OLD_PID). Используйте sstp-down."
        exit 0
    else
        rm -f "\$PID_FILE"
    fi
fi

mkdir -p "\$RUNTIME_DIR"

# Все sstpc-опции, включая логин/cert, теперь в pty-строке peer-файла.
# Пароль — в /etc/ppp/chap-secrets.
echo "Подключаемся к \${SSTP_SERVER}:\${SSTP_PORT}..."

# Запускаем pppd, который через pty-команду запускает sstpc сам.
# pppd идёт в фон; с опцией updetach он сам разделится — родитель умрёт
# после того как линк поднимется, дочерний продолжит. Поэтому смерть
# родителя ≠ ошибка. Главный критерий успеха — появление ppp-интерфейса с IP.
pppd call "\$CONN_NAME" updetach &
PPPD_PID=\$!
echo "\$PPPD_PID" > "\$PID_FILE"
chmod 600 "\$PID_FILE"
disown \$PPPD_PID 2>/dev/null || true

echo "pppd запущен (PID \$PPPD_PID), ждём ppp интерфейс..."

INTERFACE_UP=0
for i in {1..25}; do
    sleep 1
    # Проверка успеха: появился ppp с IP (это работает независимо от updetach)
    for IF in \$(ip -o link show type ppp 2>/dev/null | awk -F': ' '{print \$2}' | sed 's/@.*//'); do
        if ip -4 addr show "\$IF" 2>/dev/null | grep -q 'inet '; then
            echo "Готово! \$IF:"
            ip -4 addr show "\$IF" | grep 'inet '
            echo
            # После updetach родитель умирает — найдём настоящий PID живого pppd
            # (по cmdline, по 'call CONN_NAME')
            for pid in \$(pgrep -x pppd 2>/dev/null); do
                cmdline=\$(tr '\0' ' ' < /proc/\$pid/cmdline 2>/dev/null)
                if [[ "\$cmdline" == *"call \$CONN_NAME"* ]]; then
                    echo "\$pid" > "\$PID_FILE"
                    break
                fi
            done
            INTERFACE_UP=1
            echo "Статус: sudo sstp-status"
            exit 0
        fi
    done

    # Если pppd умер И интерфейс не появился — это реальная ошибка
    if ! kill -0 \$PPPD_PID 2>/dev/null; then
        # Возможно это просто updetach — проверим есть ли живой pppd с нашим CONN_NAME
        ALIVE=0
        for pid in \$(pgrep -x pppd 2>/dev/null); do
            cmdline=\$(tr '\0' ' ' < /proc/\$pid/cmdline 2>/dev/null)
            [[ "\$cmdline" == *"call \$CONN_NAME"* ]] && ALIVE=1 && break
        done
        if [[ "\$ALIVE" == "0" ]]; then
            echo "pppd завершился без поднятия интерфейса. Логи:"
            journalctl -t pppd  --since '30 seconds ago' --no-pager 2>/dev/null | tail -25
            echo "---"
            journalctl -t sstpc --since '30 seconds ago' --no-pager 2>/dev/null | tail -10
            rm -f "\$PID_FILE"
            exit 1
        fi
        # Pppd-родитель ушёл по updetach, но дочерний жив — продолжаем ждать интерфейс
    fi
done

echo "Интерфейс не поднялся за 25с. Логи:"
echo "  journalctl -t pppd  --since '1 minute ago'"
echo "  journalctl -t sstpc --since '1 minute ago'"
exit 1
EOF
    chmod 755 /usr/local/bin/sstp-up

    # ── sstp-down: строго по PID-файлу ──
    cat > /usr/local/bin/sstp-down <<EOF
#!/bin/bash
# Остановка SSTP '${CONN_NAME}'
CONN_NAME="${CONN_NAME}"
PID_FILE="${PID_FILE}"

[[ \$EUID -ne 0 ]] && { echo "sudo"; exit 1; }

echo "Останавливаем VPN '\$CONN_NAME'..."

# 1) Точечный kill pppd по PID-файлу.
#    pppd сам убивает свой pty-child (sstpc), так что отдельно его убивать не нужно.
if [[ -f "\$PID_FILE" ]]; then
    PPPD_PID=\$(cat "\$PID_FILE" 2>/dev/null)
    if [[ -n "\$PPPD_PID" ]] && kill -0 "\$PPPD_PID" 2>/dev/null; then
        COMM=\$(ps -p "\$PPPD_PID" -o comm= 2>/dev/null)
        if [[ "\$COMM" == "pppd" ]]; then
            echo "  kill \$PPPD_PID (pppd, child sstpc остановится сам)"
            kill "\$PPPD_PID" 2>/dev/null || true
            for i in 1 2 3 4 5; do
                kill -0 "\$PPPD_PID" 2>/dev/null || break
                sleep 1
            done
            if kill -0 "\$PPPD_PID" 2>/dev/null; then
                echo "  kill -9 \$PPPD_PID"
                kill -9 "\$PPPD_PID" 2>/dev/null || true
            fi
        else
            echo "  PID \$PPPD_PID уже не pppd (comm=\$COMM) — пропускаем"
        fi
    else
        echo "  PID из файла уже не активен"
    fi
    rm -f "\$PID_FILE"
else
    # 2) Fallback: по /proc/*/cmdline ищем ТОЛЬКО свой pppd (по 'call CONN_NAME')
    echo "  PID-файл не найден — ищем pppd с 'call \$CONN_NAME'..."
    FOUND=0
    for pid in \$(pgrep -x pppd 2>/dev/null); do
        cmdline=\$(tr '\0' ' ' < /proc/\$pid/cmdline 2>/dev/null)
        if [[ "\$cmdline" == *"call \$CONN_NAME"* ]]; then
            echo "  kill \$pid"
            kill "\$pid" 2>/dev/null || true
            FOUND=1
        fi
    done
    [[ "\$FOUND" == "0" ]] && echo "  pppd нашего подключения не найден"
fi

sleep 1

# 3) На всякий случай добиваем sstpc нашего подключения (по ipparam)
#    — обычно не нужно, pppd уже его прибил, но если sstpc отвалился сам и
#    остался zombie, чистим.
for pid in \$(pgrep -x sstpc 2>/dev/null); do
    cmdline=\$(tr '\0' ' ' < /proc/\$pid/cmdline 2>/dev/null)
    if [[ "\$cmdline" == *"ipparam \$CONN_NAME"* ]]; then
        kill "\$pid" 2>/dev/null || true
    fi
done

echo "VPN остановлен"
EOF
    chmod 755 /usr/local/bin/sstp-down

    # ── sstp-status ──
    cat > /usr/local/bin/sstp-status <<EOF
#!/bin/bash
CONN_NAME="${CONN_NAME}"
CRED_FILE="${CRED_FILE}"
PID_FILE="${PID_FILE}"
[[ -f "\$CRED_FILE" ]] && . "\$CRED_FILE"

echo "=== Процессы ==="
if [[ -f "\$PID_FILE" ]]; then
    PID=\$(cat "\$PID_FILE" 2>/dev/null)
    if [[ -n "\$PID" ]] && kill -0 "\$PID" 2>/dev/null; then
        ps -p "\$PID" -o pid,comm,etime,args --no-headers
    else
        echo "pppd: PID-файл есть, но процесс мёртв (\$PID)"
    fi
else
    echo "pppd: не запущен"
fi

# Дочерний sstpc (запущен через pty)
for pid in \$(pgrep -x sstpc 2>/dev/null); do
    cmdline=\$(tr '\0' ' ' < /proc/\$pid/cmdline 2>/dev/null)
    [[ "\$cmdline" == *"ipparam \$CONN_NAME"* ]] && \\
        ps -p "\$pid" -o pid,comm,etime,args --no-headers
done

echo
echo "=== PPP интерфейс ==="
PPP_IF=\$(ip -o link show type ppp 2>/dev/null | awk -F': ' '{print \$2}' | sed 's/@.*//' | head -1)
if [[ -n "\$PPP_IF" ]]; then
    ip -4 addr show "\$PPP_IF"
else
    echo "нет"
fi

echo
echo "=== Маршруты VPN ==="
[[ -n "\$PPP_IF" ]] && ip route show dev "\$PPP_IF" 2>/dev/null || echo "(нет интерфейса)"

echo
echo "=== Параметры ==="
echo "Сервер:   \${SSTP_SERVER}:\${SSTP_PORT}"
echo "Маршруты: \${SSTP_ROUTES}"
echo "PID-файл: \$PID_FILE"

echo
echo "=== Внешний IP ==="
timeout 5 curl -s https://ifconfig.me 2>/dev/null || echo "(таймаут)"
echo
EOF
    chmod 755 /usr/local/bin/sstp-status

    # ── sstp-route: управление маршрутами ──
    cat > /usr/local/bin/sstp-route <<EOF
#!/bin/bash
# Управление маршрутами SSTP VPN '${CONN_NAME}'
# Использование:
#   sstp-route add <CIDR>       — добавить маршрут (применить сейчас если VPN поднят + сохранить)
#   sstp-route del <CIDR>       — удалить маршрут
#   sstp-route list             — показать сохранённые маршруты
#   sstp-route reload           — применить все сохранённые (например после reconnect)
#   sstp-route flush            — удалить все маршруты

set -e

CONN_NAME="${CONN_NAME}"
CRED_FILE="${CRED_FILE}"
PID_FILE="${PID_FILE}"

[[ \$EUID -ne 0 ]] && { echo "Запустите через sudo"; exit 1; }
[[ ! -f "\$CRED_FILE" ]] && { echo "Credentials не найдены: \$CRED_FILE"; exit 1; }

# ── Получить активный ppp-интерфейс (или пусто) ──
get_ppp_if() {
    if [[ -f "\$PID_FILE" ]]; then
        local pid
        pid=\$(cat "\$PID_FILE" 2>/dev/null)
        if [[ -n "\$pid" ]] && kill -0 "\$pid" 2>/dev/null; then
            ip -o link show type ppp 2>/dev/null | awk -F': ' '{print \$2}' | sed 's/@.*//' | head -1
        fi
    fi
}

# ── Прочитать текущий SSTP_ROUTES из credentials ──
get_routes() {
    grep '^SSTP_ROUTES=' "\$CRED_FILE" | sed 's/^SSTP_ROUTES="//; s/"\$//'
}

# ── Записать новый SSTP_ROUTES (через временный файл — атомарно) ──
set_routes() {
    local new="\$1"
    local tmp
    tmp=\$(mktemp "\${CRED_FILE}.XXXXXX")
    chmod 600 "\$tmp"
    # Заменяем строку SSTP_ROUTES=, остальное оставляем как есть
    awk -v new="\$new" '
        /^SSTP_ROUTES=/ { print "SSTP_ROUTES=\"" new "\""; next }
        { print }
    ' "\$CRED_FILE" > "\$tmp"
    mv "\$tmp" "\$CRED_FILE"
    chmod 600 "\$CRED_FILE"
}

# ── Нормализовать CIDR (уберём пробелы, проверим формат) ──
normalize_cidr() {
    local c="\${1// /}"
    if ! echo "\$c" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?\$'; then
        echo "Невалидный CIDR: \$c" >&2
        return 1
    fi
    # Если маска не указана — считаем /32
    [[ "\$c" != */* ]] && c="\${c}/32"
    echo "\$c"
}

cmd_list() {
    local routes
    routes=\$(get_routes)
    echo "=== Сохранённые маршруты (в \$CRED_FILE) ==="
    if [[ -z "\$routes" ]]; then
        echo "  (нет)"
    else
        IFS=',' read -ra R <<< "\$routes"
        for r in "\${R[@]}"; do echo "  \${r// /}"; done
    fi

    local ppp
    ppp=\$(get_ppp_if)
    echo
    echo "=== Активные маршруты на интерфейсе ==="
    if [[ -n "\$ppp" ]]; then
        echo "  (интерфейс: \$ppp)"
        ip route show dev "\$ppp" 2>/dev/null | sed 's/^/  /'
    else
        echo "  (VPN не поднят — только сохранённые применятся при подключении)"
    fi
}

cmd_add() {
    local cidr
    cidr=\$(normalize_cidr "\$1") || exit 1

    local routes
    routes=\$(get_routes)

    # Проверка дубликата
    IFS=',' read -ra R <<< "\$routes"
    for r in "\${R[@]}"; do
        if [[ "\${r// /}" == "\$cidr" ]]; then
            echo "Маршрут \$cidr уже в списке"
            break_add=1
            break
        fi
    done

    if [[ "\${break_add:-0}" != "1" ]]; then
        # Добавляем в список
        if [[ -z "\$routes" ]]; then
            set_routes "\$cidr"
        else
            set_routes "\${routes},\${cidr}"
        fi
        echo "Сохранён: \$cidr"
    fi

    # Применяем немедленно, если VPN поднят
    local ppp
    ppp=\$(get_ppp_if)
    if [[ -n "\$ppp" ]]; then
        if ip route show "\$cidr" dev "\$ppp" 2>/dev/null | grep -q .; then
            echo "Уже активен на \$ppp"
        else
            ip route add "\$cidr" dev "\$ppp" && echo "Применён на \$ppp"
        fi
    else
        echo "(VPN не поднят — применится автоматически при sstp-up)"
    fi
}

cmd_del() {
    local cidr
    cidr=\$(normalize_cidr "\$1") || exit 1

    local routes
    routes=\$(get_routes)

    # Убираем из сохранённого списка
    local new=""
    IFS=',' read -ra R <<< "\$routes"
    for r in "\${R[@]}"; do
        local rn="\${r// /}"
        [[ -z "\$rn" ]] && continue
        if [[ "\$rn" != "\$cidr" ]]; then
            if [[ -z "\$new" ]]; then new="\$rn"; else new="\${new},\${rn}"; fi
        fi
    done

    if [[ "\$new" == "\$routes" ]]; then
        echo "Маршрут \$cidr не найден в сохранённых"
    else
        set_routes "\$new"
        echo "Удалён из сохранённых: \$cidr"
    fi

    # Снимаем с активного интерфейса
    local ppp
    ppp=\$(get_ppp_if)
    if [[ -n "\$ppp" ]]; then
        ip route del "\$cidr" dev "\$ppp" 2>/dev/null \\
            && echo "Снят с \$ppp" \\
            || echo "(на \$ppp не было)"
    fi
}

cmd_reload() {
    local ppp
    ppp=\$(get_ppp_if)
    [[ -z "\$ppp" ]] && { echo "VPN не поднят — маршруты применятся при sstp-up"; exit 0; }

    local routes
    routes=\$(get_routes)
    [[ -z "\$routes" ]] && { echo "Сохранённых маршрутов нет"; exit 0; }

    echo "Применяем маршруты на \$ppp..."
    IFS=',' read -ra R <<< "\$routes"
    for r in "\${R[@]}"; do
        local rn="\${r// /}"
        [[ -z "\$rn" ]] && continue
        if ip route show "\$rn" dev "\$ppp" 2>/dev/null | grep -q .; then
            echo "  \$rn — уже активен"
        else
            ip route add "\$rn" dev "\$ppp" 2>/dev/null \\
                && echo "  \$rn — добавлен" \\
                || echo "  \$rn — ошибка"
        fi
    done
}

cmd_flush() {
    local ppp
    ppp=\$(get_ppp_if)
    local routes
    routes=\$(get_routes)

    if [[ -n "\$ppp" && -n "\$routes" ]]; then
        echo "Снимаем маршруты с \$ppp..."
        IFS=',' read -ra R <<< "\$routes"
        for r in "\${R[@]}"; do
            local rn="\${r// /}"
            [[ -z "\$rn" ]] && continue
            ip route del "\$rn" dev "\$ppp" 2>/dev/null || true
        done
    fi

    set_routes ""
    echo "Список сохранённых маршрутов очищен"
}

case "\${1:-}" in
    add)    [[ -z "\${2:-}" ]] && { echo "sstp-route add <CIDR>"; exit 1; }; cmd_add "\$2" ;;
    del|rm|remove) [[ -z "\${2:-}" ]] && { echo "sstp-route del <CIDR>"; exit 1; }; cmd_del "\$2" ;;
    list|ls|"")  cmd_list ;;
    reload) cmd_reload ;;
    flush)  cmd_flush ;;
    -h|--help)
        echo "Использование:"
        echo "  sstp-route add <CIDR>   — добавить маршрут"
        echo "  sstp-route del <CIDR>   — удалить маршрут"
        echo "  sstp-route list         — показать (по умолчанию)"
        echo "  sstp-route reload       — перечитать и применить все"
        echo "  sstp-route flush        — удалить все"
        ;;
    *) echo "Неизвестная команда: \$1 (--help для справки)"; exit 1 ;;
esac
EOF
    chmod 755 /usr/local/bin/sstp-route

    success "Команды: sstp-up, sstp-down, sstp-status, sstp-route"
}

# ────────────────────────────────────────────────
# Маркер установки
# ────────────────────────────────────────────────
save_marker() {
    if [[ "$DRY_RUN" == "1" ]]; then
        dry "создать $MARKER_FILE"
        return 0
    fi

    mkdir -p "$MARKER_DIR"
    chmod 700 "$MARKER_DIR"
    cat > "$MARKER_FILE" <<EOF
# sstp-setup installation marker
INSTALLED_AT="$(date -Iseconds)"
BUILD_METHOD="${BUILD_METHOD}"
CONN_NAME="${CONN_NAME}"
VPN_SERVER="${VPN_SERVER}"
VPN_PORT="${VPN_PORT}"
VPN_USER="${VPN_USER}"
VPN_ROUTES="${VPN_ROUTES}"
VPN_CA_CERT="${VPN_CA_CERT}"
SSTP_VERSION="${SSTP_VERSION}"
SSTP_BIN="${SSTP_BIN}"
SSTP_PLUGIN_PATH="${SSTP_PLUGIN_PATH}"
SSTP_PREFIX="${SSTP_PREFIX}"
SSTP_RUNTIME_DIR="${SSTP_RUNTIME_DIR}"
DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG}"
PEER_FILE="${PEER_FILE}"
CRED_FILE="${CRED_FILE}"
IPUP_HOOK="${IPUP_HOOK}"
IPDOWN_HOOK="${IPDOWN_HOOK}"
PID_FILE="${PID_FILE}"
EOF
    chmod 600 "$MARKER_FILE"
}

# ════════════════════════════════════════════════
# УСТАНОВКА
# ════════════════════════════════════════════════
prompt_params() {
    header "Параметры подключения"

    if [[ "$DRY_RUN" == "1" ]]; then
        info "DRY-RUN: используем демо-параметры"
        VPN_SERVER="vpn.example.com"
        VPN_PORT="443"
        VPN_USER="demo-user"
        VPN_PASSWORD="(не запрашивается)"
        VPN_CA_CERT=""
        VPN_ROUTES="192.168.11.0/24"
        CONN_NAME="sstp-vpn"
        return 0
    fi

    read -p "SSTP сервер (IP/домен): " VPN_SERVER
    [[ -z "$VPN_SERVER" ]] && error "Сервер не указан"

    read -p "Порт [443]: " VPN_PORT
    VPN_PORT="${VPN_PORT:-443}"

    read -p "Логин: " VPN_USER
    [[ -z "$VPN_USER" ]] && error "Логин не указан"
    check_cyrillic "$VPN_USER" "логин"

    read -s -p "Пароль: " VPN_PASSWORD; echo
    [[ -z "$VPN_PASSWORD" ]] && error "Пароль не указан"

    echo
    echo "CA сертификат (опц., Enter → --cert-warn)"
    read -p "Путь: " VPN_CA_CERT
    if [[ -n "$VPN_CA_CERT" && ! -f "$VPN_CA_CERT" ]]; then
        warn "$VPN_CA_CERT не найден → --cert-warn"
        VPN_CA_CERT=""
    fi

    echo
    echo "Маршруты через VPN (CIDR, через запятую)"
    echo "Можно оставить пустым — добавить позже через 'sstp-route add <CIDR>'"
    read -p "Маршруты: " VPN_ROUTES
    # Пустой список — валидный случай (маршруты добавятся потом)

    read -p "Имя подключения [sstp-vpn]: " CONN_NAME
    CONN_NAME="${CONN_NAME:-sstp-vpn}"
    # Убираем все символы кроме alnum, _ и -. Дефис в конце набора — чтоб не считался диапазоном.
    CONN_NAME=$(printf '%s' "$CONN_NAME" | tr -cd 'A-Za-z0-9_-')
    [[ -z "$CONN_NAME" ]] && CONN_NAME="sstp-vpn"

    echo
    header "Сводка"
    echo "  Сервер:   ${VPN_SERVER}:${VPN_PORT}"
    echo "  Логин:    ${VPN_USER}"
    echo "  CA cert:  ${VPN_CA_CERT:-(нет)}"
    echo "  Маршруты: ${VPN_ROUTES:-(нет, добавить через sstp-route)}"
    echo "  Имя:      ${CONN_NAME}"
    echo "  Сборка:   ${BUILD_METHOD}"
    if [[ -n "$SSTP_SHA256" ]]; then
        echo "  SHA256:   ${SSTP_SHA256}"
    else
        echo "  SHA256:   (не проверяется)"
    fi
    echo
    read -p "Продолжить? [Y/n]: " c
    if [[ "$c" =~ ^[Nn]$ ]]; then
        error "Отменено"
    fi
    return 0
}

do_install() {
    header "Установка SSTP VPN клиента"

    if [[ -f "$MARKER_FILE" && "$DRY_RUN" == "0" ]]; then
        warn "sstp-setup уже установлен:"
        grep -E '^(CONN_NAME|VPN_SERVER|INSTALLED_AT|BUILD_METHOD)=' "$MARKER_FILE" | sed 's/^/  /'
        echo
        read -p "Переустановить? [y/N]: " r
        [[ ! "$r" =~ ^[Yy]$ ]] && error "Отменено"
        do_uninstall_silent
    fi

    choose_build_method
    prompt_params

    case "$BUILD_METHOD" in
        native)  build_native ;;
        docker)  build_docker ;;
        *)       error "Неизвестный метод: $BUILD_METHOD" ;;
    esac

    create_configs
    create_commands
    save_marker

    echo
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${BOLD}${YELLOW}─── DRY RUN завершён ───${NC}"
        echo "Реальная установка: sudo $0 install --${BUILD_METHOD}"
    else
        echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${GREEN}║         SSTP VPN клиент установлен!          ║${NC}"
        echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
        echo
        echo -e "  ${BOLD}Метод сборки:${NC}  ${BUILD_METHOD}"
        echo -e "  ${BOLD}Подключиться:${NC}  sudo sstp-up"
        echo -e "  ${BOLD}Отключиться:${NC}   sudo sstp-down"
        echo -e "  ${BOLD}Статус:${NC}        sudo sstp-status"
        echo -e "  ${BOLD}Маршруты:${NC}      sudo sstp-route add|del|list|reload|flush"
        echo -e "  ${BOLD}Удалить всё:${NC}   sudo $0 uninstall"
        echo
        echo -e "  ${BOLD}Маршруты через VPN:${NC}"
        if [[ -z "$VPN_ROUTES" ]]; then
            echo -e "    ${YELLOW}(не заданы — добавьте командой: sudo sstp-route add <CIDR>)${NC}"
        else
            IFS=',' read -ra R <<< "$VPN_ROUTES"
            for x in "${R[@]}"; do echo -e "    → ${x// /}"; done
        fi
        echo
        echo -e "  ${YELLOW}defaultroute отключён — SSH соединение не пострадает${NC}"
        [[ "$BUILD_METHOD" == "docker" ]] && \
            echo -e "  ${GREEN}Dev-пакеты на хост НЕ попали (собрано в контейнере)${NC}"
        echo
    fi
}

# ════════════════════════════════════════════════
# УДАЛЕНИЕ
# ════════════════════════════════════════════════
do_uninstall_silent() {
    [[ -f "$MARKER_FILE" ]] && . "$MARKER_FILE"

    # Kill pppd по PID (если PID-файл валиден)
    if [[ -n "$PID_FILE" && -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == "pppd" ]] && kill "$pid" 2>/dev/null
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    # Fallback: pppd по cmdline
    for p in $(pgrep -x pppd 2>/dev/null); do
        cl=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
        [[ "$cl" == *"call $CONN_NAME"* ]] && kill "$p" 2>/dev/null || true
    done

    # Зачистка sstpc (наш) на случай если остался один
    for p in $(pgrep -x sstpc 2>/dev/null); do
        cl=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
        [[ "$cl" == *"ipparam $CONN_NAME"* ]] && kill "$p" 2>/dev/null || true
    done

    [[ -n "$PEER_FILE"   && -f "$PEER_FILE"   ]] && rm -f "$PEER_FILE"
    [[ -n "$IPUP_HOOK"   && -f "$IPUP_HOOK"   ]] && rm -f "$IPUP_HOOK"
    [[ -n "$IPDOWN_HOOK" && -f "$IPDOWN_HOOK" ]] && rm -f "$IPDOWN_HOOK"
    [[ -n "$CRED_FILE"   && -f "$CRED_FILE"   ]] && rm -f "$CRED_FILE"
    [[ -n "$PID_FILE"    && -f "$PID_FILE"    ]] && rm -f "$PID_FILE"

    # Удаляем нашу запись из /etc/ppp/chap-secrets
    if [[ -n "$CONN_NAME" && -f /etc/ppp/chap-secrets ]]; then
        sed -i "/# sstp-setup: ${CONN_NAME}/,+1d" /etc/ppp/chap-secrets
    fi

    rm -f /usr/local/bin/sstp-up /usr/local/bin/sstp-down /usr/local/bin/sstp-status /usr/local/bin/sstp-route
    rm -rf "$MARKER_DIR"
}

do_uninstall() {
    header "Удаление SSTP VPN клиента"

    if [[ ! -f "$MARKER_FILE" ]]; then
        warn "Маркер установки не найден: $MARKER_FILE"
        warn "Выполню чистку на всякий случай."
    else
        echo "Установка:"
        grep -E '^(CONN_NAME|VPN_SERVER|INSTALLED_AT|BUILD_METHOD)=' "$MARKER_FILE" | sed 's/^/  /'
        echo
    fi

    [[ -f "$MARKER_FILE" ]] && . "$MARKER_FILE"

    # ── Шаг 1: конфиги и команды ──
    local c1 c2 c3 c3b
    if [[ "$PURGE" == "1" ]]; then
        info "--purge: без вопросов"
        c1="y"; c2="y"; c3="y"; c3b="y"
    elif [[ "$DRY_RUN" == "0" ]]; then
        read -p "Шаг 1/3 — удалить конфиги, credentials и команды sstp-*? [y/N]: " c1
        [[ ! "$c1" =~ ^[Yy]$ ]] && error "Отменено"
    else
        c1="y"
    fi

    info "Шаг 1/3: остановка и удаление конфигов"
    if [[ "$DRY_RUN" == "1" ]]; then
        dry "убить sstpc по PID из $PID_FILE (если жив)"
        dry "убить наш pppd (call $CONN_NAME) если есть"
        dry "rm $PEER_FILE $IPUP_HOOK $IPDOWN_HOOK $CRED_FILE $PID_FILE"
        dry "rm /usr/local/bin/sstp-{up,down,status,route}"
        dry "rm -r $MARKER_DIR"
    else
        if [[ -n "$PID_FILE" && -f "$PID_FILE" ]]; then
            pid=$(cat "$PID_FILE" 2>/dev/null)
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && \
               [[ "$(ps -p $pid -o comm= 2>/dev/null)" == "pppd" ]]; then
                echo "  kill pppd PID=$pid (child sstpc остановится сам)"
                kill "$pid" 2>/dev/null || true
                sleep 1
                kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        # Fallback - наш pppd по cmdline
        for p in $(pgrep -x pppd 2>/dev/null); do
            cl=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
            [[ "$cl" == *"call $CONN_NAME"* ]] && { echo "  kill pppd PID=$p"; kill "$p" 2>/dev/null || true; }
        done
        # Зачистка sstpc на всякий случай
        for p in $(pgrep -x sstpc 2>/dev/null); do
            cl=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
            [[ "$cl" == *"ipparam $CONN_NAME"* ]] && kill "$p" 2>/dev/null || true
        done

        [[ -n "$PEER_FILE"   && -f "$PEER_FILE"   ]] && rm -v "$PEER_FILE"
        [[ -n "$IPUP_HOOK"   && -f "$IPUP_HOOK"   ]] && rm -v "$IPUP_HOOK"
        [[ -n "$IPDOWN_HOOK" && -f "$IPDOWN_HOOK" ]] && rm -v "$IPDOWN_HOOK"
        [[ -n "$CRED_FILE"   && -f "$CRED_FILE"   ]] && rm -v "$CRED_FILE"
        [[ -n "$PID_FILE"    && -f "$PID_FILE"    ]] && rm -v "$PID_FILE"

        # Удаляем нашу запись из chap-secrets (по комментарию-маркеру)
        if [[ -n "$CONN_NAME" && -f /etc/ppp/chap-secrets ]]; then
            if grep -q "# sstp-setup: ${CONN_NAME}" /etc/ppp/chap-secrets; then
                echo "  очищаем запись в /etc/ppp/chap-secrets"
                sed -i "/# sstp-setup: ${CONN_NAME}/,+1d" /etc/ppp/chap-secrets
            fi
        fi

        rm -fv /usr/local/bin/sstp-up /usr/local/bin/sstp-down /usr/local/bin/sstp-status /usr/local/bin/sstp-route
        rm -rfv "$MARKER_DIR"
    fi

    # ── Шаг 2: бинарник и плагин ──
    echo
    if [[ "$PURGE" == "1" ]]; then
        c2="y"
    elif [[ "$DRY_RUN" == "0" ]]; then
        read -p "Шаг 2/3 — удалить бинарник sstpc и плагин pppd? [y/N]: " c2
    else
        c2="y"
    fi

    if [[ "$c2" =~ ^[Yy]$ ]]; then
        info "Шаг 2/3: удаление sstpc и плагина"

        # Docker-образ
        if [[ "$BUILD_METHOD" == "docker" && -n "$DOCKER_IMAGE_TAG" ]] && detect_container_runtime; then
            if $CRT inspect "$DOCKER_IMAGE_TAG" &>/dev/null; then
                if [[ "$DRY_RUN" == "1" ]]; then
                    dry "$CRT rmi $DOCKER_IMAGE_TAG"
                else
                    info "Удаляем образ $DOCKER_IMAGE_TAG..."
                    $CRT rmi "$DOCKER_IMAGE_TAG" 2>/dev/null || true
                fi
            fi
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
            dry "rm $SSTP_BIN"
            dry "rm $SSTP_PLUGIN_PATH (точный путь из маркера, НЕ глобальный glob)"
            dry "rm -r $SSTP_RUNTIME_DIR"
        else
            [[ -n "$SSTP_BIN" && -f "$SSTP_BIN" ]] && rm -v "$SSTP_BIN"
            # ВАЖНО: удаляем ТОЛЬКО точный путь, никаких globов
            if [[ -n "$SSTP_PLUGIN_PATH" && -f "$SSTP_PLUGIN_PATH" ]]; then
                rm -v "$SSTP_PLUGIN_PATH"
            fi
            rm -rfv "${SSTP_PREFIX}/share/doc/sstp-client" 2>/dev/null || true
            rm -fv  "${SSTP_PREFIX}/share/man/man8/sstpc.8"* 2>/dev/null || true
            rm -rfv "$SSTP_RUNTIME_DIR"
        fi
    fi

    # ── Шаг 3: пакеты (только для native) ──
    if [[ "$BUILD_METHOD" == "native" ]]; then
        echo
        if [[ "$PURGE" == "1" ]]; then
            c3="y"; c3b="y"
        elif [[ "$DRY_RUN" == "0" ]]; then
            echo "Можно удалить dev-пакеты:"
            echo "  ppp-devel openssl-devel libevent-devel autoconf automake libtool"
            warn "Эти пакеты могут быть нужны другому ПО! Проверка зависимостей:"
            warn "  dnf repoquery --installed --whatrequires openssl-devel"
            read -p "Шаг 3/3 — удалить dev-пакеты? [y/N]: " c3
            if [[ "$c3" =~ ^[Yy]$ ]]; then
                read -p "Точно? [y/N]: " c3b
            fi
        else
            c3="y"; c3b="y"
        fi

        if [[ "$c3" =~ ^[Yy]$ && "$c3b" =~ ^[Yy]$ ]]; then
            info "Шаг 3/3: удаление dev-пакетов"
            run_cmd "dnf remove -y ppp-devel openssl-devel libevent-devel autoconf automake libtool || true"
            warn "ppp и Development Tools НЕ удалены (могут требоваться системе)"
        fi
    else
        info "Шаг 3/3: пропущен — dev-пакеты на хост не ставились (docker)"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        echo
        echo -e "${BOLD}${YELLOW}─── DRY RUN завершён ───${NC}"
        echo "Реальное удаление:         sudo $0 uninstall"
        echo "Удаление без вопросов:     sudo $0 uninstall --purge"
    else
        success "Удаление завершено"
    fi
}

# ════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════
main() {
    parse_args "$@"
    check_env

    case "$ACTION" in
        install)   do_install ;;
        uninstall) do_uninstall ;;
        menu|"")
            echo -e "${BOLD}SSTP VPN setup for AlmaLinux 9${NC}"
            [[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}(DRY-RUN)${NC}"
            echo
            echo "  1) Установить"
            echo "  2) Удалить"
            echo "  3) Выход"
            echo
            read -p "Выбор: " c
            case "$c" in
                1) do_install ;;
                2) do_uninstall ;;
                *) exit 0 ;;
            esac
            ;;
        *) error "Неизвестное действие: $ACTION" ;;
    esac
}

main "$@"
