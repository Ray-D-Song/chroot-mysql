#!/usr/bin/env bash
set -euo pipefail

PREFIX=/opt/chroot-mysql
DATA_DIR=/var/lib/chroot-mysql/data
CREDENTIALS=/etc/chroot-mysql/credentials
SERVICE_NAME=chroot-mysql
RUN_USER=chroot-mysql
PORT=3306
BIND_ADDRESS=0.0.0.0
PASSWORD_CLI=''

usage() {
  cat <<EOF
Usage: sudo ./install.sh [options]
  --prefix PATH             Rootfs install directory (default: $PREFIX)
  --data-dir PATH           Persistent database directory (default: $DATA_DIR)
  --port PORT               MySQL port (default: $PORT)
  --bind-address ADDRESS    MySQL bind address (default: $BIND_ADDRESS)
  --service-name NAME       systemd service name (default: $SERVICE_NAME)
  --credentials-file PATH   Root-only credentials file (default: $CREDENTIALS)
  --password VALUE          root password for a new instance (or set CHROOT_MYSQL_PASSWORD)
EOF
}

validate_password() {
  local pw="$1"
  [[ -n "$pw" ]] || { echo 'password must not be empty' >&2; exit 2; }
  (( ${#pw} >= 8 )) || { echo 'password must be at least 8 characters' >&2; exit 2; }
  [[ "${pw//$'\n'}" == "$pw" ]] || { echo 'password must not contain newline' >&2; exit 2; }
  (( $(printf '%s' "$pw" | tr -cd '\0' | wc -c) == 0 )) \
    || { echo 'password must not contain null bytes' >&2; exit 2; }
  [[ ! "$pw" =~ [[:cntrl:]] ]] || { echo 'password must not contain control characters' >&2; exit 2; }
}

password_was_provided() {
  [[ -n "$PASSWORD_CLI" || -n "${CHROOT_MYSQL_PASSWORD:-}" ]]
}

warn_if_password_ignored() {
  if password_was_provided; then
    echo 'Warning: existing data directory detected; --password and CHROOT_MYSQL_PASSWORD were ignored.' >&2
  fi
}

resolve_password_for_new_install() {
  if [[ -n "$PASSWORD_CLI" ]]; then
    password="$PASSWORD_CLI"
    echo "Using password from --password. It will be stored in $CREDENTIALS (root only)."
  elif [[ -n "${CHROOT_MYSQL_PASSWORD:-}" ]]; then
    password="$CHROOT_MYSQL_PASSWORD"
    echo "Using password from CHROOT_MYSQL_PASSWORD. It will be stored in $CREDENTIALS (root only)."
  else
    password="$(openssl rand -hex 24)"
    echo "Generated MySQL root password. It is stored in $CREDENTIALS (root only)."
  fi
  validate_password "$password"
}

read_credentials_password() {
  password="$(awk -F= '$1 == "MYSQL_PASSWORD" { print substr($0, index($0, "=") + 1) }' "$CREDENTIALS")"
  [[ -n "$password" ]] || { echo "credentials file has no MYSQL_PASSWORD: $CREDENTIALS" >&2; exit 1; }
}

resolve_lower_case_table_names() {
  LOWER_CASE_TABLE_NAMES_CONFIG=''
  if [[ ! -d "$DATA_DIR/mysql" ]]; then
    LOWER_CASE_TABLE_NAMES_CONFIG=$'lower_case_table_names=1\n'
    return
  fi

  local previous_config="$PREFIX/rootfs/etc/mysql/chroot-mysql.cnf"
  if [[ -f "$previous_config" ]]; then
    local previous_value
    previous_value="$(awk -F= '
      $1 ~ /^[[:space:]]*lower_case_table_names[[:space:]]*$/ { value = $2 }
      END {
        gsub(/[[:space:]]/, "", value)
        if (value == "0" || value == "1") print value
      }
    ' "$previous_config")"
    if [[ -n "$previous_value" ]]; then
      LOWER_CASE_TABLE_NAMES_CONFIG="lower_case_table_names=$previous_value"$'\n'
    fi
  fi
}

escape_sql_string() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf '%s' "$s"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix|--data-dir|--port|--bind-address|--service-name|--credentials-file|--password)
      key="$1"; shift; [[ $# -gt 0 ]] || { echo "missing value for $key" >&2; exit 2; }
      case "$key" in
        --prefix) PREFIX="$1" ;;
        --data-dir) DATA_DIR="$1" ;;
        --port) PORT="$1" ;;
        --bind-address) BIND_ADDRESS="$1" ;;
        --service-name) SERVICE_NAME="$1" ;;
        --credentials-file) CREDENTIALS="$1" ;;
        --password) PASSWORD_CLI="$1" ;;
      esac
      shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'run install.sh with sudo or as root' >&2; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { echo 'chroot-mysql supports Linux amd64 only' >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || { echo 'port must be 1..65535' >&2; exit 2; }
[[ "$BIND_ADDRESS" =~ ^[a-zA-Z0-9.:_-]+$ ]] || { echo 'invalid bind address' >&2; exit 2; }
[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_.@-]+$ ]] || { echo 'invalid service name' >&2; exit 2; }
[[ "$PREFIX" == /* && "$PREFIX" != / && "$DATA_DIR" == /* && "$DATA_DIR" != / ]] || { echo 'prefix and data-dir must be non-root absolute paths' >&2; exit 2; }
[[ "$CREDENTIALS" == /* && "$CREDENTIALS" != / ]] || { echo 'credentials-file must be a non-root absolute path' >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOTFS="$SCRIPT_DIR/rootfs"
[[ -x "$SOURCE_ROOTFS/usr/sbin/mysqld" ]] || { echo "rootfs is missing from $SOURCE_ROOTFS" >&2; exit 1; }
resolve_lower_case_table_names

if ! id "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$RUN_USER"
fi
RUN_UID="$(id -u "$RUN_USER")"
RUN_GID="$(id -g "$RUN_USER")"

ensure_chroot_identity() {
  local rootfs="$1"
  if ! awk -F: -v gid="$RUN_GID" '$3 == gid { found=1 } END { exit !found }' "$rootfs/etc/group"; then
    printf '%s:x:%s:\n' "$RUN_USER" "$RUN_GID" >> "$rootfs/etc/group"
  fi
  if ! awk -F: -v uid="$RUN_UID" '$3 == uid { found=1 } END { exit !found }' "$rootfs/etc/passwd"; then
    printf '%s:x:%s:%s:chroot-mysql runtime:/nonexistent:/usr/sbin/nologin\n' "$RUN_USER" "$RUN_UID" "$RUN_GID" >> "$rootfs/etc/passwd"
  fi
}

cleanup_mounts() {
  umount "$PREFIX/rootfs/dev/shm" 2>/dev/null || true
  umount "$PREFIX/rootfs/var/lib/mysql" 2>/dev/null || true
}

if systemctl is-active --quiet "$SERVICE_NAME"; then systemctl stop "$SERVICE_NAME"; fi
mkdir -p "$PREFIX" "$DATA_DIR" "$(dirname "$CREDENTIALS")"
chmod 0750 "$(dirname "$CREDENTIALS")"
chown "$RUN_UID:$RUN_GID" "$DATA_DIR"

new_rootfs="$PREFIX/rootfs.new"
rm -rf "$new_rootfs"
cp -a "$SOURCE_ROOTFS" "$new_rootfs"
if [[ -d "$PREFIX/rootfs" ]]; then rm -rf "$PREFIX/rootfs"; fi
mv "$new_rootfs" "$PREFIX/rootfs"
install -D -m 0755 "$SCRIPT_DIR/bin/chroot-mysql-run" "$PREFIX/bin/chroot-mysql-run"
ensure_chroot_identity "$PREFIX/rootfs"
install -d -o "$RUN_UID" -g "$RUN_GID" -m 0755 "$PREFIX/rootfs/run/mysqld"

cat > "$PREFIX/rootfs/etc/mysql/chroot-mysql.cnf" <<EOF
[mysqld]
datadir=/var/lib/mysql
socket=/run/mysqld/mysqld.sock
pid-file=/run/mysqld/mysqld.pid
port=$PORT
bind-address=$BIND_ADDRESS
${LOWER_CASE_TABLE_NAMES_CONFIG}skip-name-resolve
mysqlx=0
EOF
chown root:root "$PREFIX/rootfs/etc/mysql/chroot-mysql.cnf"
chmod 0644 "$PREFIX/rootfs/etc/mysql/chroot-mysql.cnf"

if [[ ! -d "$DATA_DIR/mysql" ]]; then
  resolve_password_for_new_install
  sql_password="$(escape_sql_string "$password")"
  umask 077
  cat > "$CREDENTIALS" <<EOF
MYSQL_USER=root
MYSQL_PASSWORD=$password
MYSQL_PORT=$PORT
EOF
  install -d -o "$RUN_UID" -g "$RUN_GID" -m 0750 "$PREFIX/rootfs/var/lib/mysql" "$PREFIX/rootfs/dev/shm"
  mount --bind "$DATA_DIR" "$PREFIX/rootfs/var/lib/mysql"
  mount --bind /dev/shm "$PREFIX/rootfs/dev/shm"
  trap cleanup_mounts EXIT
  chroot --userspec="$RUN_UID:$RUN_GID" "$PREFIX/rootfs" /usr/sbin/mysqld --defaults-file=/etc/mysql/chroot-mysql.cnf --initialize-insecure
  chroot --userspec="$RUN_UID:$RUN_GID" "$PREFIX/rootfs" /usr/sbin/mysqld --defaults-file=/etc/mysql/chroot-mysql.cnf --skip-networking --socket=/run/mysqld/bootstrap.sock --pid-file=/run/mysqld/bootstrap.pid &
  bootstrap_pid=$!
  for _ in $(seq 1 30); do
    if chroot "$PREFIX/rootfs" /usr/bin/mysql --protocol=socket --socket=/run/mysqld/bootstrap.sock -u root -e 'select 1' >/dev/null 2>&1; then break; fi
    sleep 1
  done
  chroot "$PREFIX/rootfs" /usr/bin/mysql --protocol=socket --socket=/run/mysqld/bootstrap.sock -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$sql_password';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$sql_password';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
  kill "$bootstrap_pid"
  wait "$bootstrap_pid" || true
  cleanup_mounts
  trap - EXIT
else
  [[ -f "$CREDENTIALS" ]] || { echo "existing data directory requires credentials file: $CREDENTIALS" >&2; exit 1; }
  read_credentials_password
  warn_if_password_ignored
fi

sed -e "s|@PREFIX@|$PREFIX|g" -e "s|@DATA_DIR@|$DATA_DIR|g" -e "s|@RUN_UID@|$RUN_UID|g" -e "s|@RUN_GID@|$RUN_GID|g" \
  "$SCRIPT_DIR/systemd/chroot-mysql.service.in" > "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"
echo "Installed $SERVICE_NAME. Check: systemctl status $SERVICE_NAME"
