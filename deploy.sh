#!/bin/sh
# =============================================================================
# deploy.sh - автоматическое локальное развертывание приложения TaskBoard
#
# Что делает скрипт:
#   1. устанавливает git, python3, pip, venv, PostgreSQL, curl (если их нет);
#   2. получает исходный код (клонирует репозиторий, если его ещё нет);
#   3. создаёт виртуальное окружение .venv;
#   4. устанавливает зависимости из requirements.txt;
#   5. запускает PostgreSQL, создаёт пользователя и базу данных;
#   6. запускает приложение через Uvicorn;
#   7. проверяет, что приложение отвечает (healthcheck).
#
# Скрипт идемпотентен: его можно запускать повторно.
# Запуск:  chmod +x deploy.sh && ./deploy.sh
# =============================================================================

set -eu

# ----------------------------- Настройки -------------------------------------
# Любую из переменных можно переопределить снаружи, например: APP_PORT=9000 ./deploy.sh
APP_NAME="${APP_NAME:-taskboard}"
REPOSITORY_URL="${REPOSITORY_URL:-https://github.com/Rain-006/taskboard}"  # <- укажите URL своего форка
APP_PORT="${APP_PORT:-8000}"

DB_NAME="${DB_NAME:-taskboard}"
DB_USER="${DB_USER:-taskboard}"
DB_PASSWORD="${DB_PASSWORD:-taskboard}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"   # сколько секунд ждать запуск приложения

# Каталог, где лежит сам скрипт.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Если скрипт запущен внутри репозитория - работаем в нём.
# Иначе приложение будет клонировано в подкаталог $APP_NAME рядом со скриптом.
if [ -f "$SCRIPT_DIR/requirements.txt" ] && [ -d "$SCRIPT_DIR/app" ]; then
    APP_DIR="${APP_DIR:-$SCRIPT_DIR}"
else
    APP_DIR="${APP_DIR:-$SCRIPT_DIR/$APP_NAME}"
fi

VENV_DIR="$APP_DIR/.venv"
PID_FILE="$APP_DIR/.taskboard.pid"
LOG_FILE="$APP_DIR/taskboard.log"
APP_URL="http://localhost:$APP_PORT"
DATABASE_URL="postgresql+psycopg://$DB_USER:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME"

# ----------------------------- Вспомогательные функции ------------------------
log() {
    printf '==> %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Сообщение при неожиданном падении (срабатывает при любом ненулевом коде выхода).
on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'Deployment FAILED (exit code %s). See messages above.\n' "$rc" >&2
    fi
}
trap on_exit EXIT

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Выполнить команду от имени пользователя postgres (из безопасного каталога).
as_postgres() {
    (
        cd /tmp
        if [ "$(id -u)" -eq 0 ]; then
            runuser -u postgres -- "$@"
        else
            sudo -u postgres "$@"
        fi
    )
}

# Запрос к PostgreSQL от имени суперпользователя (вывод без заголовков).
psql_admin() {
    as_postgres psql -v ON_ERROR_STOP=1 -tA "$@"
}

# ----------------------------- Этап 0: проверка окружения ---------------------
check_environment() {
    log "Checking environment"

    has_cmd apt-get || die "This script supports Debian/Ubuntu (apt-get) only."

    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    elif has_cmd sudo; then
        SUDO="sudo"
    else
        die "Root privileges are required: run as root or install sudo."
    fi
}

# ----------------------------- Этап 1: системные программы --------------------
install_packages() {
    log "Checking required programs"

    MISSING=""
    has_cmd git     || MISSING="$MISSING git"
    has_cmd curl    || MISSING="$MISSING curl"
    has_cmd python3 || MISSING="$MISSING python3"
    # pip и venv для python3 (в Ubuntu это отдельные пакеты)
    python3 -m pip --version >/dev/null 2>&1       || MISSING="$MISSING python3-pip"
    python3 -c 'import ensurepip, venv' >/dev/null 2>&1 || MISSING="$MISSING python3-venv"
    # PostgreSQL: нужен и клиент, и сервер
    if ! has_cmd psql || ! dpkg -s postgresql >/dev/null 2>&1; then
        MISSING="$MISSING postgresql postgresql-contrib"
    fi

    if [ -z "$MISSING" ]; then
        log "All required programs are already installed"
        return 0
    fi

    log "Installing missing packages:$MISSING"
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -y \
        || die "apt-get update failed (check network connection)."
    # shellcheck disable=SC2086  # список пакетов нужно разбить на слова
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING \
        || die "Failed to install packages:$MISSING"
}

# ----------------------------- Этап 2: исходный код ---------------------------
fetch_source() {
    if [ -d "$APP_DIR/.git" ] || { [ -f "$APP_DIR/requirements.txt" ] && [ -d "$APP_DIR/app" ]; }; then
        log "Source code already present in $APP_DIR - skipping clone"
    else
        log "Cloning $REPOSITORY_URL into $APP_DIR"
        git clone "$REPOSITORY_URL" "$APP_DIR" \
            || die "Failed to clone repository $REPOSITORY_URL"
    fi

    [ -f "$APP_DIR/requirements.txt" ] || die "requirements.txt not found in $APP_DIR"
}

# ----------------------------- Этап 3-4: venv и зависимости -------------------
setup_python() {
    if [ -x "$VENV_DIR/bin/python" ]; then
        log "Virtual environment already exists: $VENV_DIR"
    else
        log "Creating virtual environment: $VENV_DIR"
        rm -rf "$VENV_DIR"
        python3 -m venv "$VENV_DIR" || die "Failed to create virtual environment."
    fi

    log "Installing Python dependencies from requirements.txt"
    "$VENV_DIR/bin/python" -m pip install --quiet -r "$APP_DIR/requirements.txt" \
        || die "Failed to install Python dependencies."
}

# ----------------------------- Этап 5: PostgreSQL -----------------------------
setup_postgresql() {
    log "Starting PostgreSQL"
    if [ -d /run/systemd/system ]; then
        $SUDO systemctl enable --now postgresql \
            || die "Failed to start PostgreSQL via systemctl."
    else
        $SUDO service postgresql start \
            || die "Failed to start PostgreSQL via service."
    fi

    # Ждём, пока сервер начнёт принимать подключения.
    i=0
    until psql_admin -c 'SELECT 1' >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -le 30 ] || die "PostgreSQL did not become ready in 30 seconds."
        sleep 1
    done

    log "Configuring database user '$DB_USER'"
    if [ "$(psql_admin -c "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")" = "1" ]; then
        log "User '$DB_USER' already exists - updating password"
        psql_admin -c "ALTER ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$DB_PASSWORD'" >/dev/null \
            || die "Failed to update user '$DB_USER'."
    else
        psql_admin -c "CREATE ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$DB_PASSWORD'" >/dev/null \
            || die "Failed to create user '$DB_USER'."
    fi

    log "Configuring database '$DB_NAME'"
    if [ "$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")" = "1" ]; then
        log "Database '$DB_NAME' already exists"
    else
        psql_admin -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\"" >/dev/null \
            || die "Failed to create database '$DB_NAME'."
    fi
    # Владелец БД нужен, чтобы приложение могло создавать таблицы (PostgreSQL 15+).
    psql_admin -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\"" >/dev/null \
        || die "Failed to set owner of database '$DB_NAME'."
    psql_admin -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\"" >/dev/null \
        || die "Failed to grant privileges on '$DB_NAME'."

    # Проверяем, что приложение сможет подключиться с этими учётными данными.
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -tA -c 'SELECT 1' >/dev/null 2>&1 \
        || die "Cannot connect to database '$DB_NAME' as '$DB_USER' on $DB_HOST:$DB_PORT."
    log "Database is ready"
}

# ----------------------------- Этап 6: запуск приложения ----------------------
stop_previous() {
    # Останавливаем экземпляр, запущенный этим скриптом ранее.
    if [ -f "$PID_FILE" ]; then
        old_pid=$(cat "$PID_FILE")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            log "Stopping previous instance (PID $old_pid)"
            kill "$old_pid" 2>/dev/null || true
            i=0
            while kill -0 "$old_pid" 2>/dev/null && [ "$i" -lt 10 ]; do
                i=$((i + 1))
                sleep 1
            done
        fi
        rm -f "$PID_FILE"
    fi

    # Порт должен быть свободен.
    if has_cmd ss && ss -ltn 2>/dev/null | grep -q ":$APP_PORT "; then
        die "Port $APP_PORT is already in use by another process."
    fi
}

start_app() {
    stop_previous

    log "Starting application with Uvicorn on port $APP_PORT"
    cd "$APP_DIR"
    export DATABASE_URL
    nohup "$VENV_DIR/bin/uvicorn" app.main:app --host 0.0.0.0 --port "$APP_PORT" \
        >"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
}

# ----------------------------- Этап 7: проверка результата --------------------
check_health() {
    log "Waiting for application healthcheck ($APP_URL/api/health)"
    app_pid=$(cat "$PID_FILE")
    i=0
    until curl -fsS -o /dev/null "$APP_URL/api/health" 2>/dev/null; do
        if ! kill -0 "$app_pid" 2>/dev/null; then
            tail -n 20 "$LOG_FILE" >&2 || true
            die "Application process exited unexpectedly. Log: $LOG_FILE"
        fi
        i=$((i + 1))
        if [ "$i" -ge "$HEALTH_TIMEOUT" ]; then
            tail -n 20 "$LOG_FILE" >&2 || true
            die "Healthcheck failed after ${HEALTH_TIMEOUT}s. Log: $LOG_FILE"
        fi
        sleep 1
    done
    log "Healthcheck response: $(curl -fsS "$APP_URL/api/health")"
}

# ----------------------------- Главная последовательность ---------------------
main() {
    check_environment
    install_packages
    fetch_source
    setup_python
    setup_postgresql
    start_app
    check_health

    echo
    echo "Application deployed successfully."
    echo "Application is available at: $APP_URL"
    echo "Swagger API: $APP_URL/docs"
    echo "Healthcheck: $APP_URL/api/health"
    echo "Log file: $LOG_FILE (PID file: $PID_FILE)"
}

main "$@"
