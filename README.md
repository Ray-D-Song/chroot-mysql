# chroot-mysql

`chroot-mysql` ships MySQL Community Server 8.4 LTS in a Debian 12 AMD64 chroot for offline Linux deployments. The database rootfs is isolated under `/opt`, while data and generated credentials remain on the host.

## Install

Unpack a release and run:

```bash
sudo ./install.sh
sudo systemctl status chroot-mysql
sudo cat /etc/chroot-mysql/credentials
```

Defaults are `0.0.0.0:3306`, `/opt/chroot-mysql`, `/var/lib/chroot-mysql/data`, and `/etc/chroot-mysql/credentials`. The first installation creates a random MySQL root password. MySQL X Protocol is disabled; firewall policy remains the deployer's responsibility.

Use alternate locations or a port when needed:

```bash
sudo ./install.sh --prefix /opt/chroot-mysql --data-dir /var/lib/chroot-mysql/data \
  --port 3306 --bind-address 0.0.0.0
```

`sudo ./uninstall.sh` removes the service and rootfs but preserves data and credentials. Use `sudo ./uninstall.sh --purge-data` only when the database is no longer needed.

## Build

On Debian/Ubuntu AMD64 with `debootstrap`, `curl`, and GnuPG:

```bash
sudo bash scripts/build-rootfs.sh
sudo bash tests/verify-rootfs.sh build/rootfs
sudo bash scripts/package.sh local
```

The exact MySQL package version is locked in `versions.env`.

