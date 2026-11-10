# 在 OpenWrt 上安装 LoKi

[Русский](INSTALL.ru.md) · [English](INSTALL.md) · 简体中文

LoKi 作为应用安装在使用 `opkg` 的 OpenWrt 24.10 和使用 `apk` 的 OpenWrt 25.12 上。安装程序根据固件的包管理器和架构选择软件包，不依据设备品牌或型号。发布文件中必须包含适合该架构的 `loki-core`。

## 安装

通过 SSH 以 `root` 登录 OpenWrt，执行：

```sh
(set -o pipefail; wget -O - https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install-loki.sh | sh)
```

这是固定的安装地址。引导脚本将完整的 `install.sh` 下载到仅当前用户可访问的临时文件中，下载成功后才执行。LuCI 的组件页面使用同一个安装程序。

安装程序读取最新发布版本的信息，选择应用软件包和兼容内核，验证 SHA256，再由原生包管理器模拟安装。缺少的必要依赖从已配置的 OpenWrt 软件源安装。此操作不刷写固件，也不导入其他应用的配置。

可用空间按实际安装软件包的文件系统计算。RAM 和 `/tmp` 的需求根据下载的软件包和安装操作计算，不要求固定的 160 MiB 空间或强制离线安装套件。

如果其他 `sing-box` 应用正在运行，请先停止它，再重试安装。脚本不会删除其软件包或设置。如果包管理器无法获取依赖、报告 Linux 内核不兼容或文件冲突，请保留具体错误，不要使用强制安装选项绕过检查。

安装成功后，重新打开 LuCI 和 LoKi 页面。添加连接，配置路由分区和 DNS，保存设置并点击 Start。首次安装不会应用空的路由配置。DNS 加密需单独设置：选择 DoH 或 DoT，并填写相应的服务器地址。

## 更新和卸载

更新时重新执行主安装命令，或使用 LuCI 的组件页面。安装程序保留 LoKi 配置和原有服务状态：已停止的服务继续保持停止，原先运行的服务在更新后启动。

卸载时下载同一个安装程序，并使用 `--uninstall`：

```sh
script=$(mktemp /tmp/loki-uninstall.XXXXXX) &&
wget -T 30 -O "$script" https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install.sh &&
sh "$script" --uninstall
rm -f "$script"
```

普通卸载会保留 LoKi 设置。在 `--uninstall` 后添加 `--purge` 可同时删除设置；仅在明确需要删除这些设置时使用。

## 操作中止时

安装程序会指出失败阶段和日志路径。请保留终端输出和该日志，并提供 OpenWrt 版本、架构和包管理器信息：

```sh
cat /etc/openwrt_release
grep MemAvailable /proc/meminfo
df -Pk / /tmp
```

日志可能包含临时签名下载链接。发布前请删除个人令牌、密码和连接信息。

SHA256 用于检查文件是否与发布的校验值一致。信任来源是项目仓库和 HTTPS；没有独立的数字签名。Linux 测试不能替代具体 OpenWrt 设备上真实的软件包钩子、rpcd/procd 和负载测试。
