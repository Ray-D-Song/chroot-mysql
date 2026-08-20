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
BACKUP_SET=''

cleanup() {
  if [[ -n "$PACKAGE_DIR" && -x "$PACKAGE_DIR/uninstall.sh" ]]; then
    "$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data || true
  fi
  umount "$PREFIX/rootfs/dev/shm" 2>/dev/null || true
  umount "$PREFIX/rootfs/var/lib/mysql" 2>/dev/null || true
  rm -rf "$PREFIX" "$DATA_DIR" "$BACKUP_SET" "$(dirname "$CREDENTIALS")" "$WORK_DIR"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo 'smoke test requires root' >&2; exit 1; }
tar -xzf "$BUNDLE" -C "$WORK_DIR"
PACKAGE_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$PACKAGE_DIR" ]] || { echo 'bundle root directory missing' >&2; exit 1; }
"$PACKAGE_DIR/install.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --port "$PORT" --bind-address 127.0.0.1
systemctl is-active --quiet "$SERVICE"
[[ -x "$PREFIX/bin/chroot-mysql-pxb" ]] || { echo 'PXB CLI was not installed' >&2; exit 1; }
"$PREFIX/bin/chroot-mysql-pxb" --help >/dev/null
if "$PREFIX/bin/chroot-mysql-pxb" --backup-dir / backup-full >/dev/null 2>&1; then
  echo 'PXB CLI accepted a root backup directory' >&2
  exit 1
fi
source "$CREDENTIALS"
grep -Fxq 'lower_case_table_names=1' "$PREFIX/rootfs/etc/mysql/chroot-mysql.cnf"

mysql_exec() {
  local prefix="$PREFIX" port="$PORT" user="$MYSQL_USER" password="$MYSQL_PASSWORD"
  if [[ $# -ge 4 && "$1" == /* ]]; then
    prefix="$1" port="$2" user="$3" password="$4"
    shift 4
  fi
  MYSQL_PWD="$password" chroot "$prefix/rootfs" /usr/bin/mysql --protocol=TCP -h 127.0.0.1 -P "$port" -u "$user" "$@"
}
wait_for_mysql() {
  local prefix="${1:-$PREFIX}" port="${2:-$PORT}" user="${3:-$MYSQL_USER}" password="${4:-$MYSQL_PASSWORD}"
  for _ in $(seq 1 30); do
    if mysql_exec "$prefix" "$port" "$user" "$password" -e 'select 1' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "MySQL did not become ready on port $port" >&2
  return 1
}

wait_for_mysql
mysql_exec -e "create database ci_smoke; create table ci_smoke.MixedCaseRecords(id int primary key, note varchar(32)); insert into ci_smoke.MixedCaseRecords values (1, 'ok'); select * from ci_smoke.mixedcaserecords;"
BACKUP_SET="$(mktemp -d /tmp/chroot-mysql-pxb-test.XXXXXX)"
chown "$(stat -c '%u:%g' "$DATA_DIR")" "$BACKUP_SET"
pxb_args=("$PREFIX/bin/chroot-mysql-pxb" --rootfs "$PREFIX/rootfs" --data-dir "$DATA_DIR" --credentials-file "$CREDENTIALS" --backup-dir "$BACKUP_SET" --host 127.0.0.1 --port "$PORT" --user "$MYSQL_USER")
"${pxb_args[@]}" --compress backup-full > "$WORK_DIR/pxb-full.json"
grep -Fq '"toLSN"' "$WORK_DIR/pxb-full.json"
mysql_exec -e "insert into ci_smoke.MixedCaseRecords values (2, 'after-full');"
"${pxb_args[@]}" --compress --run-id inc-1 --base-run-id full backup-incremental > "$WORK_DIR/pxb-inc.json"
grep -Fq '"toLSN"' "$WORK_DIR/pxb-inc.json"
"${pxb_args[@]}" decompress > "$WORK_DIR/pxb-decompress.json"
"${pxb_args[@]}" prepare > "$WORK_DIR/pxb-prepare.json"
systemctl stop "$SERVICE"
find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
"${pxb_args[@]}" copy-back > "$WORK_DIR/pxb-copy-back.json"
systemctl start "$SERVICE"
wait_for_mysql
mysql_exec -Nse 'select count(*) from ci_smoke.MIXEDCASERECORDS' | grep -Fx 2
"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS"
[[ -d "$DATA_DIR/mysql" ]] || { echo 'uninstall unexpectedly removed database data' >&2; exit 1; }
"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data
[[ ! -e "$DATA_DIR" ]] || { echo 'purge-data did not remove test data' >&2; exit 1; }
rm -rf "$BACKUP_SET"
BACKUP_SET=''

# Custom password via environment variable on a fresh install.
CUSTOM_TEST_ID="${TEST_ID}-custom"
CUSTOM_PREFIX="/opt/chroot-mysql-test-$CUSTOM_TEST_ID"
CUSTOM_DATA_DIR="/var/lib/chroot-mysql-test-$CUSTOM_TEST_ID"
CUSTOM_SERVICE="chroot-mysql-test-$CUSTOM_TEST_ID"
CUSTOM_PORT="$(( 20000 + RANDOM % 20000 ))"
CUSTOM_CREDENTIALS="/etc/chroot-mysql-test-$CUSTOM_TEST_ID/credentials"
CUSTOM_PASSWORD='ci-fixed-pass-8chars'
OTHER_PASSWORD='other-pass-8chars'

custom_cleanup() {
  if [[ -x "$PACKAGE_DIR/uninstall.sh" ]]; then
    "$PACKAGE_DIR/uninstall.sh" --prefix "$CUSTOM_PREFIX" --data-dir "$CUSTOM_DATA_DIR" \
      --service-name "$CUSTOM_SERVICE" --credentials-file "$CUSTOM_CREDENTIALS" --purge-data || true
  fi
  umount "$CUSTOM_PREFIX/rootfs/dev/shm" 2>/dev/null || true
  umount "$CUSTOM_PREFIX/rootfs/var/lib/mysql" 2>/dev/null || true
  rm -rf "$CUSTOM_PREFIX" "$CUSTOM_DATA_DIR" "$(dirname "$CUSTOM_CREDENTIALS")"
}
trap custom_cleanup EXIT

CHROOT_MYSQL_PASSWORD="$CUSTOM_PASSWORD" "$PACKAGE_DIR/install.sh" \
  --prefix "$CUSTOM_PREFIX" --data-dir "$CUSTOM_DATA_DIR" --service-name "$CUSTOM_SERVICE" \
  --credentials-file "$CUSTOM_CREDENTIALS" --port "$CUSTOM_PORT" --bind-address 127.0.0.1
systemctl is-active --quiet "$CUSTOM_SERVICE"
source "$CUSTOM_CREDENTIALS"
[[ "$MYSQL_PASSWORD" == "$CUSTOM_PASSWORD" ]] || { echo 'custom password was not stored in credentials' >&2; exit 1; }
wait_for_mysql "$CUSTOM_PREFIX" "$CUSTOM_PORT" "$MYSQL_USER" "$MYSQL_PASSWORD"
mysql_exec "$CUSTOM_PREFIX" "$CUSTOM_PORT" "$MYSQL_USER" "$MYSQL_PASSWORD" -Nse 'select 1' | grep -Fx 1

systemctl stop "$CUSTOM_SERVICE"
reinstall_output="$(CHROOT_MYSQL_PASSWORD="$OTHER_PASSWORD" "$PACKAGE_DIR/install.sh" \
  --prefix "$CUSTOM_PREFIX" --data-dir "$CUSTOM_DATA_DIR" --service-name "$CUSTOM_SERVICE" \
  --credentials-file "$CUSTOM_CREDENTIALS" --port "$CUSTOM_PORT" --bind-address 127.0.0.1 \
  --password "$OTHER_PASSWORD" 2>&1)"
grep -q 'ignored' <<<"$reinstall_output" || { echo 'reinstall did not warn about ignored password' >&2; exit 1; }
systemctl is-active --quiet "$CUSTOM_SERVICE"
source "$CUSTOM_CREDENTIALS"
[[ "$MYSQL_PASSWORD" == "$CUSTOM_PASSWORD" ]] || { echo 'reinstall changed the stored password' >&2; exit 1; }
grep -Fxq 'lower_case_table_names=1' "$CUSTOM_PREFIX/rootfs/etc/mysql/chroot-mysql.cnf"
wait_for_mysql "$CUSTOM_PREFIX" "$CUSTOM_PORT" "$MYSQL_USER" "$MYSQL_PASSWORD"
mysql_exec "$CUSTOM_PREFIX" "$CUSTOM_PORT" "$MYSQL_USER" "$MYSQL_PASSWORD" -Nse 'select 1' | grep -Fx 1

custom_cleanup
trap - EXIT

echo 'chroot-mysql smoke test passed'
