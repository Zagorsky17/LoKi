# LoKi

LoKi 是面向 OpenWrt 的规则路由应用，使用专用 loki-core 内核。

[![LoKi 稳定版](https://img.shields.io/github/v/release/Zagorsky17/LoKi?label=%E7%89%88%E6%9C%AC&color=178f83&style=flat)](https://github.com/Zagorsky17/LoKi/releases/latest)

[Русский](README.ru.md) · [English](README.md) · 简体中文

[运行要求](#兼容的路由器) · [功能](#功能) · [稳定性](#稳定运行的机制) · [安装](#安装) · [报告问题](https://github.com/Zagorsky17/LoKi/issues)

## 兼容的路由器

LoKi 在 OpenWrt 设备上运行。兼容性取决于固件、处理器架构和可用资源。

| 参数 | 要求 |
| --- | --- |
| 固件 | 使用 `opkg` 的 OpenWrt **24.10**，或使用 `apk` 的 **25.12**。 |
| 处理器 | ARM/ARM64、MIPS/MIPS64、x86/x86-64、RISC-V64 和 LoongArch64，前提是[发行版](https://github.com/Zagorsky17/LoKi/releases/latest)包含与固件精确架构匹配的软件包。 |
| 内存 | 安装程序以 **128 MB** 为参考；建议 **256 MB 或更多**以保留余量。用量取决于订阅、规则列表和连接数；128 MB 设备上的运行尚未单独验证。 |
| 闪存 | 需有空间存放应用、内核和依赖。所需容量取决于架构和已安装的软件包，安装程序会在安装前计算。 |
| 访问条件 | 以 `root` 使用 SSH，通过 LuCI 在浏览器中管理，并能通过 HTTPS 访问 GitHub 和 OpenWrt 软件源。 |

> **LoKi 2.0.5 稳定版。** 已确认在运行 OpenWrt 25.12.6 的 Cudy WR3000S v1 上正常运行、卸载和故障恢复。其他设备和 OpenWrt 24.10 仍需单独测试。

## 功能

- **分区路由：** 为域名、子网和设备设置独立规则，支持内置与外部列表。
- **连接链接：** VLESS、VMess、Trojan、Shadowsocks、Hysteria2、TUIC 及内核支持的其他协议。
- **订阅：** 链接列表、sing-box/Xray JSON、SIP008 和 Clash YAML；从客户端配置中提取连接参数。
- **服务器选择：** 手动切换、按延迟选择的 URLTest，以及备用连接 Fallback。
- **DNS：** UDP、DNS over HTTPS（DoH）、DNS over TLS（DoT）及备用解析器，明确选择加密模式。
- **监控与日志：** 在 LuCI 中查看流量、连接、设备和路由，提供附加 YACD 面板及秘密信息脱敏的诊断报告。
- **安装与更新：** 一条 SSH 命令安装，在 LuCI 中更新组件，保留 LoKi 设置及原有服务状态。

## 稳定运行的机制

- **通过 Unix 套接字本地控制。** 后端通过私有文件系统套接字与内核通信，检查所有者、权限及对端 UID；控制器密钥不会发送到浏览器。
- **通过 WebSocket 传输实时数据。** 流量和连接经 LuCI 授权的安全 WSS 网关传输。连接断开后，界面以递增间隔重连；网关不可用时，仪表盘可通过 RPC 获取快照。
- **拦截流量前检查。** LoKi 在启用路由前检查配置与内核就绪状态；内核崩溃监视器在恢复期间暂停拦截。
- **启动失败重试。** 启用开机自启后，LoKi 在启动失败 30 秒后重试；Stop 或 Disable 取消重试。
- **保留可用订阅。** 错误或截断响应不会替换工作集合。手动选择与连接参数绑定，重命名或重排节点不会改变选择。
- **串行执行操作。** Start、Apply 和 Stop 使用同一把锁；规则列表工作进程从最近确认应用成功的配置代次恢复。
- **检查更新并合并重复日志。** 安装程序校验 SHA256 并模拟包管理器操作；内核将完全相同的重复错误合并为摘要，保留首条记录和不同的错误。

## 安装

通过 SSH 以 `root` 登录 OpenWrt，执行：

```sh
(set -o pipefail; wget -O - https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install-loki.sh | sh)
```

安装程序识别固件架构，从最新发布版本下载匹配的软件包，检查 SHA256，并由原生包管理器解析依赖和模拟安装。

[安装、更新和卸载说明](INSTALL.zh.md)。SSH 和 LuCI 使用同一个 `install.sh`。更新保留 LoKi 配置及原有服务状态。LoKi 使用自身的 `loki-core`，不迁移其他应用配置。真实设备安装与负载仍需由所有者验证。

## 更新和卸载

更新时重新执行安装命令，或使用 LuCI 的组件页面。LoKi 设置和原有服务状态会保留。

若要卸载 LoKi 并保留设置，请通过 SSH 以 `root` 执行：

```sh
(set -o pipefail; wget -O - https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install-loki.sh | sh -s -- --uninstall)
```

若要同时删除 LoKi 设置，在 `--uninstall` 后添加 `--purge`。此选项会删除已保存的配置；普通卸载会保留配置。

## LuCI 界面与 YACD 面板

LoKi 的主界面位于 LuCI。具有 LoKi 写入权限的用户可以在流量设置中点击 YACD 链接，在新标签页打开 `https://<router-address>:9091/cgi-bin/luci/loki-gateway/`。请把 `<router-address>` 换成访问 HTTPS LuCI 时使用的地址或主机名。面板沿用该会话的 cookie，浏览器不保存控制器密钥。会话过期或被撤销后，访问随之结束。网关不可用时，LuCI 仍是主界面。

在 **设置 → LoKi 界面语言** 中可以只为 LoKi 的 LuCI 页面选择英语或俄语。选项以 `ui_language` 保存在 `/etc/config/loki`；在 LuCI 中保存并应用后，重新打开页面即可加载所选语言。此操作不写入 `luci.main.lang`、不注册 LuCI 全局语言，也不更改其他 LuCI 页面。俄语文字来自已安装的 `luci-i18n-loki-ru` 目录；目录缺失或无效时，缺少译文的 LoKi 标签使用英语。没有 `ui_language` 的早期开发配置暂时沿用 LuCI 语言，直到保存新选择。安装后请在 LuCI 中选择界面语言。

YACD 显示流量、连接、代理、规则和实时日志。文件位于 `/usr/share/loki/yacd`；网关核实写入权限后才会提供这些文件。只读用户不能打开面板及其 API，但仍可使用 LuCI 的“监控”和“日志”。面板不能修改共享系统设置，也不提供任意后端、内核更新或 Clash API 配置修改。网关使用 uhttpd 的 HTTPS 证书；浏览器必须信任该证书。真实 OpenWrt 行为尚未验证。

“监控”保留活动及已关闭连接、设备和路由筛选、搜索、刷新、排序与计数器。通过 RPC 关闭单个或全部连接需要写入权限。只读会话轮询固定的状态快照，不会获得控制器密钥。“日志”支持查看、刷新，以及常驻服务重启后的游标恢复。RPC 快照忙碌或过大时会明确报错。

本地 HTTP 传输最多接受 64 KiB 响应头和 4 MiB 缓冲响应体；超过限制时失败，不返回不完整快照。流式规则集提供者快照保留原有解码器。这些输入上限不等于进程总内存上限。

应用使用 `loki`、`luci-app-loki`、`/etc/config/loki` 和专用二进制文件 `/usr/bin/loki-core`。仅支持使用自身配置的全新安装，不支持导入或迁移其他应用的配置。

## 环境诊断

`preflight.sh` 保留为独立诊断工具，其扩展报告不再是常规安装或启动的强制准入条件。正常流程使用安装程序、包管理器以及 LoKi 的配置与内核检查。

## 订阅与兼容性

支持 JSON 出站连接和现有网络接口。不支持内置客户端 VPN 隧道（WireGuard、AmneziaWG、WARP、Tailscale、OpenVPN、OpenConnect）、JSON 端点及在路由器上运行 VPN/代理服务器。自定义 JSON 出站配置不能启用已移除的 VPN 类型。迁移框架仅用于未来 LoKi 版本。

目标平台为 OpenWrt 24.10 和 25.12。仅支持 LoKi 自己构建的内核；标准 sing-box 和其他派生版本不在支持范围内。早期有限的 schema 比较仅用于诊断和回归测试。

需要复现历史 Linux schema 比较时，运行 `python3 core/tests/compatibility.py REFERENCE_CORE STOCK_BINARY_DIR OUTPUT_DIR`。将 `REFERENCE_CORE` 换为可信的当前 LoKi 内核路径，`STOCK_BINARY_DIR` 换为含有 `core/tests/compatibility_releases.json` 所列官方归档和重命名为 `sing-box-VERSION` 的二进制文件的目录，`OUTPUT_DIR` 换为结果目录。执行前会核实归档摘要和提取出的字节。预期完成 40 项检查。早期 36 项 DNS/provider 比较在独立副本中使用历史 loopback TCP 控制器：三个官方版本都接受有限的手动配置和三类普通链接配置，1.14.4 还接受自定义 timeout。另四项使用真实生成的 Unix 控制器：参考内核接受，三个标准版本均拒绝 `external_controller_unix`。其余案例拒绝已知 schema 扩展。空 provider 和未启用的订阅缓存、unified-delay 字段会被省略。这不证明标准内核端到端兼容；软件包依赖和启动要求仍需要 r7。

r5 的合成测试覆盖部分 sing-box/Xray JSON、SIP008、Clash YAML 和原始链接列表，包括 base64 包装。真实 loopback HTTP(S)、VLESS WebSocket/TLS/Reality 和 Shadowsocks AES-128-GCM/ChaCha20 握手验证了受测连接参数。结构化测试数据中的客户端全局字段不会替换 LoKi 的 DNS、路由、监听器/TUN、日志或缓存设置；受测 HTTP/解析错误及截断响应保留当前工作集合和选择，重名节点保留各自订阅的命名空间。以非特权 Linux 用户和可信内核运行 `python3 core/tests/subscription_profiles.py CORE NEW_OUTPUT_DIR`。脚本还会以 30+20 和 60+40 个具有唯一认证信息的 HTTP/HTTPS 节点，依次测试每个节点的流量。这些测试不证明路由器的并发容量、所有协议与选项组合、用户提供的订阅或 OpenWrt 行为；输入字节数和节点数上限仍在评估中。

保留 [forkop-lists](https://github.com/ushan0v/forkop-lists) 内置列表以及诊断域名 `ip.podkop.fyi`、`fakeip.podkop.fyi` 作为外部依赖。

## LoKi 内核

loki-core 以 `core/upstream.env` 固定的 `ushan0v/sing-box-forkop` 为基础，继承订阅提供者、连接格式解析和 DNS 扩展。LoKi 的补丁位于 `core/patches/`。当前构建为 `1.14.4-r11`，技术软件包名为 `loki-core`。软件包、服务、命令、UCI 与路径的重命名已实现；不支持其他应用的配置。

r10 内核增加了有大小和时间限制的 HTTPS 下载器，用于获取 LoKi 的公开发布文件。它检查重定向目标和响应限制，不读取代理配置。请按通用安装说明操作；内核下载器不能代替软件包安装程序。

r11 在订阅响应报告缺少 X-HWID 或达到设备数量限制时，将具体原因写入日志并保留原有可用连接。地址为 `0.0.0.0` 或 `::` 的节点不会被导入。如果较早版本创建了没有 HTTP 请求头的订阅记录，请使用同一链接创建新记录，并在应用前确认“Headers”中存在 `X-HWID`。此标识符属于路由器；服务商可能将其计为另一台设备。已保存的自定义请求头不会被自动替换。

在 Linux 上，`loki-core check` 会在读取配置前禁止进程内存转储。如果内核拒绝启用此保护，检查会在读取文件前失败。此保护不能替代文件系统和网络隔离；非 Linux 系统上的配置检查会被拒绝。

启动或应用前的现有配置检查限制为 10 秒及 64 KiB 的合并输出。检查拒绝、中断或输出超限时，会删除临时输入并保留原有的已生成配置文件。此检查复用 RPC 工作进程基于 BusyBox `ash`、`setsid` 和 `sleep` 的监控机制，在期限到达时终止独立进程组。不需要可选的 `timeout` 小程序或额外软件包。

r8 将同一底层节点在一次 fallback 健康检查周期中只探测一次，即使多个组成员引用它。r7 中的快速响应可能使同一周期产生第二次探测。配置格式未改变。应用要求保留了此修复的 r9；路由器行为仍未验证。

r7 使用私有目录中的固定 Unix 控制器套接字 `/tmp/loki/controller.sock`。网关和后端 RPC 检查端点所有者及权限，并在发送控制器凭据前验证对端 UID。浏览器不会取得凭据。浏览器通过受 LuCI 授权的独立 HTTPS/WSS 网关访问；本地 YACD 文件已通过 Linux 检查，仍待真实 OpenWrt 验证。 读取凭据或随机字节时，如果关闭文件失败，就拒绝使用结果；现有凭据文件保持不变。

通过明确选择的 DNS 解析器连接域名时，优先地址族已有结果即可开始连接，无需等待另一个沉默的地址族。该行为覆盖 TCP/UDP 和网络接口选择，同时保留 IPv6。IPv4-only/IPv6-only 模式以及未指定解析器的 DNS 规则遍历保持原路径。此修复不会关闭 DNS 加密，也不会在失败时直接绕过代理。

r4 起，provider 选择使用所选订阅中的连接参数识别节点，因此重排重名节点或改名不会切换连接。认证、传输或 TLS 参数变化会产生新身份；所选身份不可用时，仍按现有默认/首个成员策略处理，直到节点恢复或用户重新选择。r4 之前的缓存只保存名称，无法安全识别旧选择：升级后请重新选择所需订阅节点。显示名称不变；缓存写入失败时，手动选择会被拒绝，运行中的选择不变。

r5 缓存要求由内核进程持有的私有目录（权限 `0700`）以及只有一个硬链接的自有普通文件（权限 `0600`）。RAM 预设路径为 `/tmp/loki/cache.db`，闪存预设路径为 `/etc/loki/cache/cache.db`。不安全路径、符号链接和没有格式标记的数据库会被拒绝，不导入、删除或修改其他应用的数据。现有 r4 数据库没有标记，不能继续使用；开发版本升级时应选择新的私有缓存位置，并重新选择订阅节点。显式 UCI 路径保持原值，所以仅改变默认值不会移动已有配置。RAM 缓存在重启后丢失。

订阅响应体以不可变版本保存；元数据和已验证的响应体引用先一起提交，然后才改变 provider 的运行状态。发布失败时保留工作集合。收到的响应体被拒绝时，只有在旧响应体和更新后的元数据持久化后才清除 HTTP validator，防止后续 `304` 掩盖失败的更新。

r6 新保存的规则集/SRS 响应体也使用不可变文件，其大小和 SHA-256 引用与元数据一起提交。数据库提交结果不确定时，阻止后续订阅/SRS 写入及清理，保留可能有效的两个版本直到重启。启动前必须成功同步数据库，才允许迁移、压缩或清理孤立文件；失败则拒绝启动。清理按批次扫描两个响应体目录直到结尾，保留已引用、待提交及无关文件。这只限制目录项内存，不限制引用映射的总内存或扫描时间。

只能复用带标记的 LoKi r5 存储：旧 SRS 项在成功更新之前仍使用历史上的仅大小校验。首次按新格式提交 SRS 时，存储标记原子升级；新存储直接使用格式 2。r5 拒绝格式 2，因此开发版本降级时需要另设私有缓存位置。旧确定性命名的 SRS 文件仍作为私有遗留项，不会自动删除。无效的新格式引用不会回退到旧项。运行时 SRS 更新维持现有行为：缓存保存失败时，已解析规则可能已生效；持久化配对完整性不提供运行时回滚。完整安装预检、资源上限和断电持久性仍未验证。

LoKi 内核会在十秒窗口内合并同一组件的完全相同 ERROR。首条错误立即显示，后续重复项生成数字摘要。缓存最多保存 64 组组件和消息哈希，不保留消息正文。未缓存的新错误、其他等级以及 FATAL/PANIC 原样显示。摘要在窗口结束后的下一条记录或正常关机时输出；没有后台定时器。突然终止可能丢失待输出的摘要。不同消息不会合并，因此这不是全部日志流量的上限。

SSH 与 LuCI 使用同一套基于 Forkop 的安装程序，通过原生包管理器安装 LoKi 及所需依赖，不刷写固件或迁移其他应用配置。测试环境的检查不能证明每台 OpenWrt 设备上的实际结果。

## 启动恢复

启用开机自启后，启动失败会在 30 秒后重试，无需等待新 WAN 事件。成功、Stop 或 Disable 后停止重试；Disable 不会停止已正常运行的服务。内核就绪后才允许应用流量拦截。恢复使用临时 procd 实例，不依赖 LuCI 状态服务。实际断电后的恢复和闪存持久性仍需 OpenWrt 实验室测试。

规则集工作进程只使用最近一次确认应用成功的配置代次。保存不同的设置，不会在修复或进程重启时改变它所使用的提供者、地址、端口或控制器凭据。对正常运行的服务执行 Start，可以恢复缺失的工作进程，而不应用新保存的设置。私有上下文保存在 tmpfs 中，大小限制为 4 MiB，不是配置备份；这个限制不代表进程总内存上限。

中断的 Apply 可能留下未经确认的内核与 nft 状态组合。自动 Start、排队的重新加载和接口事件触发的重新加载不会自动完成这次操作。请显式执行 Apply，或先完成 Stop 再执行 Start；这些操作使用已保存的配置。Stop 必须在清理前记录停止意图。正常重启会丢失 tmpfs 上下文，并从已保存的配置启动。内核进程重启后的恢复会在 LoKi 自身的生命周期协议中核实 procd 命令、PID/启动时间及受保护配置的摘要；不支持自动恢复其他 root 进程在该协议之外进行的更改。

生命周期操作使用 Linux 内核锁，持有进程退出时自动释放。操作结束后临时锁目录会保留，目录存在本身不表示操作仍在执行。旧锁的持有者仍存活或无法确认时，竞争操作会被拒绝。

## 配置备份

LoKi 配置除 schema 版本外还包含 `option config_format 'loki'`。仅版本号相同不能使 Forkop 或 Podkop 配置兼容。安装、启动和备份恢复在遇到其他应用、未支持或损坏的 schema 时会拒绝处理，不移动或重置该文件。没有 LoKi 标记的中间开发配置不会自动转换。

配置上传会将 LoKi 自己的备份作为当前 LuCI 会话中尚未保存的更改；应用后才生效。上传文件必须是普通文件，大小不超过 1 MiB。当前配置无需迁移；未来 LoKi schema 更新保留迁移框架和私有备份。应用前仍会执行 LoKi 配置检查。连接链接与订阅仍是单独支持的输入；不会导入客户端的全局设置。

## DNS 设置

界面要求对整个主 DNS 列表明确选择加密模式：关闭时使用 UDP；开启时明确选 DoH 或 DoT。地址必须与模式匹配：DoH 为 `https://dns.example/dns-query`，DoT 为 `tls://dns.example`，UDP 为 IP 地址。请将示例域名 `dns.example` 换成自己的解析器。更改模式不会重写地址，服务器失败时也不会自动切换协议。

Bootstrap 使用 IP 地址上的 UDP。未单独指定解析器的出站连接使用 bootstrap；显式 JSON 和接口解析器设置保持不变。新配置保留当前 UDP 默认值。没有加密字段的旧配置在用户于界面明确选择模式之前，继续使用原 URI 协议。这些变更仍需在实验室 OpenWrt 上测试。

生成的 JSON 只省略完全等于 `10s` 的 DNS timeout，这与四个固定内核已核实的默认值一致。其他值（包括 `10000ms`）保持不变；已存储的设置不会被修改。在 Linux 上运行 `python3 -B core/tests/dns_timeout.py CORE NEW_OUTPUT_DIR`，使用合成 loopback DNS 对端检查真实超时。将 `CORE` 换为可信的固定内核二进制路径，并使用新的结果目录。Keepalive 查询及“12 秒 timeout、11 秒响应”用来区分客户端截止时间和入站连接独立的 10 秒空闲上限。旧版标准内核必须拒绝显式 timeout，不能静默忽略。

对指定解析器的出站连接，修补后的内核在一个地址族可用时即可开始连接，另一个 DNS 查询仍可继续等待；需要后备连接时，第二个地址族仍可使用。`ipv4_only` 和 `ipv6_only` 的含义不变。这也适用于解析 DoH/DoT 服务器域名。普通 DNS 规则遍历仍取得完整结果；失败时不会降级到 UDP 或直接路由。

被拦截的 PTR 查询会对本地提供的反向区域，以及已配置 LAN 拦截接口的当前 IPv4/IPv6 前缀（包括公网 LAN 前缀），使用本地解析器。其他 PTR 查询遵循所选 DNS 规则。LAN 地址快照不可用、格式错误或超限时，会记录警告，所有 PTR 查询继续走原有本地路由。前缀在服务启动或重新加载时刷新；LAN 重新编号后请再次应用设置。`router` 模式继续将未匹配查询交给本地解析器。真实 OpenWrt 行为仍需测试。

## 构建内核

`core/` 包含补丁、测试和构建脚本。loki-core 源码固定到提交 `60d96c99815a672712915a5c00114bf0f690ad80`；解压前检查归档的 SHA-256，应用补丁前先检查补丁。源码更新需要显式操作。LoKi 仓库不复制完整内核源码；每次软件包构建还会生成 `core-source-VERSION.tar.gz`（`VERSION` 为 `core/upstream.env` 中的内核版本），包含打补丁后的源码树，供与二进制文件一起分发。

在 Linux 上使用 `core/GO_VERSION` 指定的 Go、Bash、Git、curl、Python 3 及现有软件包构建工具。下面的例子为 `aarch64_cortex-a53` 构建应用软件包和 base 内核；`0.1.0` 只是示例版本，并非已发布版本。构建应用后，APK 工具位于默认 SDK 缓存中；如果使用其他 SDK 目录，请调整该路径。

应用构建器通过 SHA-256 和精确字节数固定 OpenWrt 24.10.8、25.12.6 SDK 归档。下载与重定向都必须使用 HTTPS；缓存归档在解压前重新校验。`IPK_SDK_URL` 和 `APK_SDK_URL` 可指定这些归档的 HTTPS 镜像。若使用不同 SDK，还必须分别提供独立核实的 `IPK_SDK_SHA256`/`IPK_SDK_BYTES` 或 `APK_SDK_SHA256`/`APK_SDK_BYTES`；仅换 URL 不会信任新内容。构建目录与缓存目录应由构建用户控制。旧的“仅 URL”解压标记会触发重新解压。解压或 SDK 根目录检查失败时，先前已提取的 SDK 保留。可以在 Linux 上运行 `python3 -m unittest discover -s tests/packaging -p 'test_*.py'` 进行本地 HTTPS 回归测试；需要 curl、OpenSSL 和 zstd。

```sh
./build.sh 0.1.0 "$PWD/release"
export PATH="$HOME/.cache/loki/openwrt-sdk/extracted/apk/staging_dir/host/bin:$PATH"
core/build.sh 0.1.0 "$PWD/release" --arch aarch64_cortex-a53 --variant base
(cd release && sha256sum -c SHA256SUMS)
```

`core/build.sh` 接受继承的构建器变体和目标；不指定架构时会构建全部目标。full 变体还可能下载数 GB 的 Chromium 源码和工具。发布工作流按照支持的架构矩阵构建 base 内核，并加入单独的内核清单。构建不会发布版本，也不会安装软件包。

构建器还会导出用于初始引导（bootstrap）的独立二进制文件 `loki-core_VERSION_VARIANT_ARCH.bin`。复制到输出目录前，会将其大小和 SHA-256 与每个 IPK/APK 中的 `/usr/bin/loki-core` 核对；同一构建配置的两种格式必须包含相同字节。文件权限为 `0644`，并加入 `SHA256SUMS`。应与对应的软件包、源码和许可证声明一起分发。此文件不是安装器；请使用完整校验套件。

每次成功构建软件包还会生成 `core-module-sources-VERSION-SHA256.tar.gz`，其中包含已核实的外部 Go 模块源码 ZIP、可用的 `go.sum` 校验依赖图元数据，以及固定的 Public Suffix List 源码及其 MPL 2.0 文本。`SOURCES.json` 将文件绑定到二进制哈希、构建设置、Go 版本和已打补丁的源码树。在同一输出目录合并多个构建配置时，各配置保留单独归档。源码清单 schema 2 要求 Go 归档；旧清单仅作为历史记录，不能通过此检查。

归档还包含未修改的官方 `go1.26.10.src.tar.gz`，其中有 Go runtime、标准库、工具链源码及其原始声明。收集器固定并再次核查其精确大小和 SHA-256。源码归档只作为数据复制，收集时不会解压到磁盘或执行。已安装的 Go 源码文件必须与归档相同；缺失或改变会阻止收集。

构建前，封装脚本通过 HTTPS 明确准备该文件，将其放在 `XDG_CACHE_HOME`（或 `~/.cache`）下的 `loki/core` 子目录。收集器随后离线使用已有缓存；缺少必要源码、校验和改变或存在无法确定的组件时，封装脚本会在复制新软件包之前停止。软件包验证器要求每个包含的二进制构建配置都有匹配的模块文件。

Core CI 使用 [`core/isolate_toolchain.py`](core/isolate_toolchain.py) 准备已安装 Go 工具链的私有副本。内容与文件元数据检查只针对这一自有副本；共享工具缓存保留原有字节和权限。

离线重建 base 版本时，使用固定的 Go 版本，把 `core-source-*` 解压到新目录，并把匹配的模块归档解压到另一目录。将 `GOMODCACHE` 指向第二目录的 `modules` 子目录，设置 `GOTOOLCHAIN=local`、`GOPROXY=off`、`GOSUMDB=off`。在内核源码目录执行 `git init` 和 `git add .`，建立本地 Git 索引供继承的行尾检查使用。使用 `core/upstream.env` 中的 `SOURCE_DATE_EPOCH`，运行 `./build.sh --binary-only --version VERSION --output /path/to/output amd64`，并替换 `VERSION` 和输出路径。嵌套的 `toolchain/go1.26.10.src.tar.gz` 提供固定的 Go 源码；从源码构建编译器还需满足 [Go 文档](https://go.dev/doc/install/source)中的引导要求。单独获取的 Cronet 材料不在此文件内。base 成功重建不证明其他构建配置的对应源码已齐全。

内核软件包包含 `usr/share/licenses/loki-core/THIRD_PARTY_NOTICES` 和 `build-info.json`。构建器不修改 `core/notice-files.json` 中已审查文件的字节，记录其来源、偏移、哈希以及二进制哈希、所链接 Go 模块和打补丁源码树的摘要。它离线读取已有模块缓存；审查过的声明缺失或改变会阻止打包。未经审查的模块、替换项或原生组件，在开发包中仍明确标为未解决。在应用和内核合并的输出目录上运行 `python3 core/tests/verify_packages.py "$PWD/release"`：此发布检查会拒绝未解决的清单，核对真实二进制元数据、源码归档和 IPK/APK 中的声明。该有限声明映射还不能证明每种构建配置的许可证和对应源码审计均已完成。

运行 `core/test.sh -race -count=1` 和 `python3 core/tests/test_release.py`。`python3 core/tests/dns_bootstrap.py /path/to/sing-box /results/directory` 需要 ucode，只在 loopback 启动合成 DNS、TLS 和代理对端。`python3 core/tests/log_repeats.py /path/to/sing-box /results/directory` 检查重复 TCP 故障、十秒窗口和关机摘要。结果保存在指定目录中；这些检查不能替代 OpenWrt 测试。

## 诊断报告

同一启用的分区同时使用内置列表和已识别的外部引用时，应用设置与服务检查会警告来源相同或可能重叠。识别范围仅限规范的 forkop-lists URL、内置短名称和两个历史 itdog URL（`russia_inside.srs`、`meta.srs`）。警告不能证明不同文件内容完全相同；删除列表前应比较域名和子网。保存不会被阻止，列表与路由也不会自动修改。未知 URL 和本地文件不会为了比较而下载。新警告及响应字段不包含完整外部 URL 或令牌。这项诊断不减少内存消耗。

FakeIP 将合成 IP 地址映射到域名，用于路由。流量检查中，浏览器得到否定的 FakeIP 结果只产生信息提示，不单独将该分组判为异常；它也不能识别设备实际使用的 DNS 设置。无响应的检查仍产生警告，路由器和出口故障保持原有严重程度。文本报告用 ℹ 标记信息提示。

服务检查显示可用日志中最近 60 秒的 sing-box ERROR/FATAL 记录数。它统计日志记录，而非网络故障：DNS 重复摘要算一条。按需读取上限为 64 KiB 和 1000 行；超限或格式错误标为不完整，读取失败标为不可用。不会创建历史记录或单独日志文件，新响应字段也不包含日志正文。logd 淘汰旧记录和时钟变动会影响准确性；计数器不会减少原始日志流量。

DNS 验证错误指出受影响的设置和原因，不打印原始 DNS URI。报告默认以脱敏值打开。切换为未脱敏报告需要确认，页面会警告其中可能包含密钥和密码。切换模式时禁用复制与下载，完成后只导出当前显示的模式。要分享报告，请使用脱敏模式或 `loki report masked`，发送前自行检查：掩码无法识别所有可能的秘密。后端和 LuCI 软件包应一起更新，保持报告格式一致。

在 Linux 上，`python3 core/tests/plain_links.py CORE OUTPUT_DIR [REFERENCE_CORE]` 通过本地有认证的对端，将生成的 HTTP(S)/SOCKS 出站连接与现有解析器比较，也检查密码错误和不受信任证书时的拒绝行为。使用可信、已验证的二进制路径和新的输出目录；当 `CORE` 是官方 1.14.4 二进制时，传入 LoKi 内核作为参考。测试只更改它自己的监听器和文件。

检查生成的代理级联时，以同样可信的二进制文件运行 `python3 core/tests/cascade_links.py CORE NEW_OUTPUT_DIR [REFERENCE_CORE]`。它测试 HTTP/HTTPS 首跳、HTTP/HTTPS/SOCKS5 出口、两个对端不可用、认证/TLS 拒绝、流中断和恢复。即使响应成功，刻意删除的 detour 也必须被发现。所有对端均在本机；这不证明路由器上的路由行为或所有级联协议。

`/etc` 下自有的可变配置文件以 `0600` 权限安装。新写入的内核配置和自有原子状态使用 `0600`；临时内核检查输入也保持私有，并在成功、拒绝或执行异常后删除。临时名称已被占用时拒绝操作，不覆盖或删除原有文件。已有目录及未改变的旧文件不会自动修复；这项保护假定父目录可信，也不保证断电持久性。

## 文档与测试

公开产品文档维护在本文件、[README.md](README.md) 和 [README.ru.md](README.ru.md)。继承的文档网站及其 GitHub Pages 工作流已移除。

测试和软件包构建在专用 Linux 开发服务器上运行。发布前还必须在实验室 OpenWrt 路由器上测试 DNS 故障、流量拦截和安装。安全测试使用合成凭据及本地测试端点。

## 来源与许可证

内核声明包包含固定 Public Suffix List 源码的完整 MPL 2.0 文本和署名。内置旗帜字体保留其[作品署名](luci-app-loki/htdocs/luci-static/resources/view/loki/fonts/LICENSE.md)、[未修改的 npm 许可证](luci-app-loki/htdocs/luci-static/resources/view/loki/fonts/UPSTREAM_LICENSE.md)和[制品来源](luci-app-loki/htdocs/luci-static/resources/view/loki/fonts/PROVENANCE.md)。WOFF2 与 npm 版本 0.1.8 一致；尚未验证能否由上游 TTF 重现。

内嵌 Lucide SVG 及 Feather 衍生图标的声明安装到 `/usr/share/licenses/luci-app-loki/LUCIDE-LICENSE`，补充声明的来源记录在旁边的 `LUCIDE-PROVENANCE`。[固定版本的许可文本](fe-app-loki/licenses/lucide-LICENSE.txt) 不修改图形或界面代码；项目未记录最初复制 SVG 时的上游修订。

Forkop 由 [ushan0v 及贡献者](https://github.com/ushan0v/forkop/graphs/contributors)开发。LoKi 由 [Zagorsky17/LoKi](https://github.com/Zagorsky17/LoKi) 独立维护，并非 Forkop 上游发布版本。

LoKi 保留项目的 [GPL-2.0-or-later 许可证](LICENSE)。内核补丁和生成的 loki-core 二进制另按 [GPL-3.0-or-later](core/COPYING) 分发；构建会生成带本地 `third_party` 替换内容的补丁后源码归档 `core-source-VERSION.tar.gz`，以及上文所述的 `core-module-sources-*` 归档。分发二进制文件还需要相应的构建材料、依赖源码和声明；仅有这些归档尚不能算完成对应源码审计。必须保留现有版权、许可及署名声明。第三方组件继续保留自己的声明，包括[内置字体资源](luci-app-loki/htdocs/luci-static/resources/view/loki/fonts/LICENSE.md)。

分发修改版或二进制软件包时，保留适用的声明和许可证，指出修改过的文件及日期，并按 [GNU GPL 第 2 版](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)要求提供对应源码。软件按许可证条款提供，不附带保证。

本中文 README 于 2026 年 11 月 6 日编写，依据同期的英语和俄语版本。

二进制发布的许可证审计仍未结束。YACD 从 [MetaCubeX/Yacd-meta 提交 `24151c3`](https://github.com/MetaCubeX/Yacd-meta/tree/24151c331027ff176b45ed417180c6f1220474a3) 内置；其源码、锁文件和 MIT 许可文本保存在 `yacd-loki/`。LuCI 软件包包含 MIT 文本、Inter/Roboto Mono OFL 声明，以及构建时生成的依赖声明和哈希清单。两个未附许可证文件的 npm 归档保留原始声明，并明确标注补充文本；参见 [YACD 来源和重建检查](yacd-loki/README.md)。发布前仍需完成权利与源码审查，核查字体来源、链接的 Go 代码以及每种构建配置的对应源码。继承的主前端许可证仍是单独的审查项。
