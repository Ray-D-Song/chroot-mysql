#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/versions.env"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
ROOTFS="$BUILD_DIR/rootfs"

[[ "$(uname -m)" == "x86_64" ]] || { echo 'only amd64 hosts are supported' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo 'run build-rootfs.sh with sudo' >&2; exit 1; }
command -v debootstrap >/dev/null || { echo 'debootstrap is required' >&2; exit 1; }

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
debootstrap --arch=amd64 --variant=minbase "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"

chroot "$ROOTFS" /bin/bash -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates gnupg
  rm -rf /var/lib/apt/lists/* /var/cache/apt/*
'

install -d -m 0755 "$ROOTFS/usr/share/keyrings"
curl -fsSL "$MYSQL_APT_KEY" | gpg --dearmor > "$ROOTFS/usr/share/keyrings/mysql.gpg"
cat > "$ROOTFS/etc/apt/sources.list.d/mysql.list" <<EOF
deb [signed-by=/usr/share/keyrings/mysql.gpg] $MYSQL_APT_REPOSITORY $DEBIAN_SUITE $MYSQL_SERIES
EOF

cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"

chroot "$ROOTFS" /bin/bash -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends mysql-community-server="'"$MYSQL_PACKAGE_VERSION"'" mysql-client="'"$MYSQL_PACKAGE_VERSION"'"
  rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*
  rm -rf /var/lib/mysql/*
  rm -f /usr/sbin/policy-rc.d /etc/machine-id
'

actual_server="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' mysql-community-server)"
actual_client="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' mysql-client)"
[[ "$actual_server" == "$MYSQL_PACKAGE_VERSION" ]] || { echo "MySQL server version mismatch: $actual_server" >&2; exit 1; }
[[ "$actual_client" == "$MYSQL_PACKAGE_VERSION" ]] || { echo "MySQL client version mismatch: $actual_client" >&2; exit 1; }
install -d -m 0755 "$ROOTFS/var/lib/mysql" "$ROOTFS/run/mysqld" "$ROOTFS/dev/shm"
cat > "$ROOTFS/etc/chroot-mysql-build.env" <<EOF
MYSQL_SERIES=$MYSQL_SERIES
MYSQL_PACKAGE_VERSION=$actual_server
EOF
echo "rootfs ready: $ROOTFS"

