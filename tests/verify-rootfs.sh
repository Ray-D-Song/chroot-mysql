#!/usr/bin/env bash
set -euo pipefail

ROOTFS="${1:?usage: verify-rootfs.sh <rootfs>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/versions.env"

[[ -x "$ROOTFS/usr/sbin/mysqld" ]] || { echo 'mysqld missing from rootfs' >&2; exit 1; }
[[ -x "$ROOTFS/usr/bin/mysql" ]] || { echo 'mysql client missing from rootfs' >&2; exit 1; }
[[ -x "$ROOTFS/usr/bin/mysqldump" ]] || { echo 'mysqldump client missing from rootfs' >&2; exit 1; }
[[ -x "$ROOTFS/usr/bin/mysqlbinlog" ]] || { echo 'mysqlbinlog client missing from rootfs' >&2; exit 1; }
[[ -x "$ROOTFS/usr/bin/xtrabackup" ]] || { echo 'xtrabackup missing from rootfs' >&2; exit 1; }
chroot "$ROOTFS" /usr/bin/env LD_LIBRARY_PATH=/usr/lib/private /usr/bin/xtrabackup --version >/dev/null
server_version="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' mysql-community-server)"
client_version="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' mysql-client)"
[[ "$server_version" == "$MYSQL_PACKAGE_VERSION" ]] || { echo "server version mismatch: $server_version" >&2; exit 1; }
[[ "$client_version" == "$MYSQL_PACKAGE_VERSION" ]] || { echo "client version mismatch: $client_version" >&2; exit 1; }
echo "verified MySQL $server_version"
