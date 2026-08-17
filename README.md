# chroot-mysql

离线 MySQL Community Server 8.4 LTS 发行包，使用 Debian 12 AMD64 chroot 运行环境，供没有外网或宿主发行版不固定的 Linux 服务器使用。

## 构建与发布

`versions.env` 锁定 MySQL 官方 APT 仓库的精确包版本。推送分支或 Pull Request 时 GitHub Actions 构建并验证；推送 `v*` tag 后，只有 Ubuntu 24 Hosted Runner 与自建 CentOS 7 / Linux 3.10 Runner 都通过验证，才会创建 GitHub Release。

自建 Runner 必须包含标签：`self-hosted`、`linux`、`x64`、`centos7-kernel310-mysql`，并且允许无交互 `sudo`。它会真实安装、启动 systemd 服务、使用密码连接 MySQL、重启并验证数据持久化。

非 Release 的工作流和失败工作流都会在结束时删除本次构建 Artifact，避免持续占用仓库空间。

## 安装发行包

```bash
tar -xzf chroot-mysql-<version>-linux-amd64.tar.gz
cd chroot-mysql-<version>-linux-amd64
sudo ./install.sh
sudo systemctl status chroot-mysql
sudo cat /etc/chroot-mysql/credentials
```

默认路径为 `/opt/chroot-mysql`（rootfs）、`/var/lib/chroot-mysql/data`（数据）和 `/etc/chroot-mysql/credentials`（凭据）；数据目录不会随普通卸载或升级删除。

默认监听 `0.0.0.0:3306`，新实例启用 `lower_case_table_names=1`，表名大小写不敏感。远程连接使用 MySQL 8.4 默认的 `caching_sha2_password` 认证。安装时生成随机 `root` 密码，或通过 `--password` / `CHROOT_MYSQL_PASSWORD` 指定，并禁用 MySQL X Protocol（33060）；生产使用前必须通过防火墙限制来源地址。

`lower_case_table_names` 必须在初始化数据目录前确定。已有数据目录重新安装时会保留此前配置，不会直接切换大小写策略；如需将旧实例迁移为大小写不敏感，必须先导出数据，再使用新数据目录初始化并导入。

密码来源（仅全新实例）：`--password` > `CHROOT_MYSQL_PASSWORD` > 随机生成。已有数据目录时传入密码会被忽略并警告，密码以 credentials 文件为准。自动化场景优先使用环境变量：

```bash
sudo CHROOT_MYSQL_PASSWORD='your-secret-here' ./install.sh
```

可覆盖默认值：

```bash
sudo ./install.sh --prefix /opt/chroot-mysql --data-dir /var/lib/chroot-mysql/data \
  --port 3306 --bind-address '127.0.0.1' --password 'your-secret-here'
```

`sudo ./uninstall.sh` 删除服务和 rootfs、保留数据；仅在确认不再需要数据库时使用 `sudo ./uninstall.sh --purge-data`。
