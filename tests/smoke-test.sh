#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:?usage: smoke-test.sh <bundle.tar.gz>}"
TEST_ID="${2:-${GITHUB_RUN_ID:-local}-${RANDOM}}"
WORK_DIR="$(mktemp -d /tmp/chroot-mysql-test.XXXXXX)"
PREFIX="/opt/chroot-mysql-test-$TEST_ID"
DATA_DIR="/var/lib/chroot-mysql-test-$TEST_ID"
SERVICE="chroot-mysql-test-$TEST_ID"
PORT="$(( 20000 + RANDOM % 20000 ))"
CREDENTIALS="/etc/chroot-mysql-test-$TEST_ID/credentials"
PACKAGE_DIR=''

cleanup() {
  if [[ -n "$PACKAGE_DIR" && -x "$PACKAGE_DIR/uninstall.sh" ]]; then
    "$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data || true
  fi
  umount "$PREFIX/rootfs/dev/shm" 2>/dev/null || true
  umount "$PREFIX/rootfs/var/lib/mysql" 2>/dev/null || true
  rm -rf "$PREFIX" "$DATA_DIR" "$(dirname "$CREDENTIALS")" "$WORK_DIR"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo 'smoke test requires root' >&2; exit 1; }
tar -xzf "$BUNDLE" -C "$WORK_DIR"
PACKAGE_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$PACKAGE_DIR" ]] || { echo 'bundle root directory missing' >&2; exit 1; }
"$PACKAGE_DIR/install.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --port "$PORT" --bind-address 127.0.0.1
systemctl is-active --quiet "$SERVICE"
source "$CREDENTIALS"

mysql_exec() {
  MYSQL_PWD="$MYSQL_PASSWORD" chroot "$PREFIX/rootfs" /usr/bin/mysql --protocol=TCP -h 127.0.0.1 -P "$PORT" -u "$MYSQL_USER" "$@"
}
wait_for_mysql() {
  for _ in $(seq 1 30); do
    if mysql_exec -e 'select 1' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "MySQL did not become ready on port $PORT" >&2
  return 1
}

wait_for_mysql
mysql_exec -e 'create database ci_smoke' -e 'create table ci_smoke.records(id int primary key, note varchar(32))' -e "insert into ci_smoke.records values (1, 'ok')" -e 'select * from ci_smoke.records'
systemctl restart "$SERVICE"
wait_for_mysql
mysql_exec -Nse 'select note from ci_smoke.records where id = 1' | grep -Fx ok
"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS"
[[ -d "$DATA_DIR/mysql" ]] || { echo 'uninstall unexpectedly removed database data' >&2; exit 1; }
"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data
[[ ! -e "$DATA_DIR" ]] || { echo 'purge-data did not remove test data' >&2; exit 1; }
echo 'chroot-mysql smoke test passed'

