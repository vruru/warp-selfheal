# 【WGCF】连接CF WARP为服务器添加IPv4/IPv6网络

[English](README_EN.md) | 中文

* * *

> 本仓库是 [fscarmen/warp](https://gitlab.com/fscarmen/warp) 的 GPLv3 派生版，由 `vruru` 于 2026-08-28 修改。主要变化：WireProxy SOCKS 数据面持续健康检查，以及高性能 `sockswg`（内核 WireGuard + 本机 SOCKS）分流模式。原项目版权及 GPLv3 许可证保持不变。

自愈版一键安装或升级：

```bash
wget -N https://raw.githubusercontent.com/vruru/warp-selfheal/main/menu.sh && bash menu.sh
```

全新安装 WireProxy 时，脚本会校验并使用仓库内的 `v1.1.3-selfheal.1` 修复构建，同时自动创建 watchdog；旧版建议先卸载干净再重新安装，不执行自动二进制升级。修复版不靠内存超限重启：它会在 SOCKS 连接的一侧结束后继续放行仍在传输的数据，只有另一侧连续静默两分钟才清理孤儿连接，同时把单方向复制缓冲区从 256 KiB 降到 32 KiB。`GOMEMLIMIT=160MiB` 仅辅助 Go 主动回收堆，不会触发进程重启。watchdog 会根据 WireProxy 配置分别强制检测 IPv4 与 IPv6；`warp=on`、`warp=plus` 都视为健康，同一栈连续失败两次才恢复服务，避免 IPv6 正常时掩盖 IPv4 故障。

### sockswg 高性能 SOCKS 分流

`sockswg` 保持应用原有的 `127.0.0.1:40000` SOCKS 分流方式，但把隧道数据面换成 Linux 内核 WireGuard，并由 Dante 或 MicroSocks 提供仅监听本机的 SOCKS5。A/B WARP 均严格为 IPv4-only，不配置 WARP IPv6 地址、`::/0` 或 IPv6 策略规则；没有经过 SOCKS 的流量始终走 VPS 原生出口。纯 IPv6 目的地不受支持。相比单进程用户态 WireProxy，WireGuard 的加解密和转发在内核完成，适合多核、高连接数场景。

```bash
warp p       # 全新安装，或把当前 WireProxy 安全迁移为 sockswg
warp q       # 开关 sockswg
```

迁移时先在空闲临时端口验证 WARP IPv4，成功后才接管原 SOCKS 端口；失败会自动恢复 WireProxy。旧 WireProxy 二进制和配置会禁用并保留作回滚，不会继续占用端口。`sockswg` watchdog 每 30 秒检测 IPv4，服务/网卡消失会立即重建，连续两次数据面失败会依次轮换 `2408 → 4500 → 500 → 1701` UDP Endpoint 并复测。当前安装支持使用 systemd 的 Debian/Ubuntu；Debian 12 优先使用 Dante，Debian 13 在官方源没有 Dante 时自动改用 MicroSocks，强制绑定 WARP IPv4 并使用专用 UID 策略路由。

#### sockswg IPv4 蓝绿灾备（Debian 12/Dante 与 Debian 13/MicroSocks）

`sockswg-bluegreen` 在同一台 VPS 上运行地位平等的 A/B 两条隧道，其中纯 IPv4 的 B 位于独立网络命名空间。安装时从初始 A 自动识别并保存期望地区。iptables 连接跟踪只把新 SOCKS 连接切到另一槽，已经建立的 TCP 连接继续沿原隧道传输并自然排空。每 20 秒同时检查 Cloudflare 地区、`warp=on/plus` 和 Google HTTP 状态；当前活动槽连续失败两次才切换。切换后，只要新活动槽正常就一直使用，修复后的旧槽仅作为空闲灾备，不自动回切。

空闲槽不健康时会自动修复；健康但不是 `optimal` 时，每小时最多启动一轮 IP 筛选，并且会先等待该槽的旧连接排空。筛选先轮换 Endpoint 并重连同一个 Peer，连续验收地区、Google 非 `429` 以及与活动槽的出口差异；多次失败后才注销并注册候选 Peer，失败候选会注销并回滚。候选另外记录 Google/YouTube 地区：与该机 WARP 地区一致为 `optimal`，Google 可访问但地区不同（包括 `.com.hk`）为 `usable`，两级都可用于灾备。A/B IP 相同本身不会触发筛选。WARP 出口由 Cloudflare 分配，蓝绿机制提高可用性但不能保证永久固定或无限生成不同公网 IP。

当前支持已有 `sockswg` 的 Debian 12/Dante 和 Debian 13/MicroSocks；脚本根据现有 `sockswg.service` 自动选择 B 槽后端。MicroSocks B 槽在独立网络命名空间内以非特权用户运行。该功能尚未默认集成到 `warp p`。

```bash
wget -qO /usr/local/sbin/sockswg-bluegreen https://raw.githubusercontent.com/vruru/warp-selfheal/main/sockswg/sockswg-bluegreen
wget -qO /usr/local/lib/warp-selfheal/api.sh https://raw.githubusercontent.com/vruru/warp-selfheal/main/api.sh
chmod 755 /usr/local/sbin/sockswg-bluegreen /usr/local/lib/warp-selfheal/api.sh
sockswg-bluegreen install
sockswg-bluegreen status
```

本仓库保留了上游完整历史和安装所需的 `api.sh`、WireProxy、wireguard-go、wgcf、warp-go、endpoint 等文件，并把脚本的运行时回源和自更新地址改为本仓库。原仓库中未包含但菜单会调用的 `warp_unlock` 与 `resolvconf` 也已连同各自许可证镜像到 [`vendor/`](vendor/README.md)；旧版 Docker 模式改为使用仓库内 Dockerfile 在本机生成镜像，不再拉取原作者镜像。因此原项目仓库下线后，已镜像的安装功能仍可从本仓库使用；Cloudflare API、系统软件源及第三方官方服务仍需联网。

* * *

# 目录

- [更新信息](README.md#更新信息)
- [脚本特点](README.md#脚本特点)
- [WARP好处](README.md#WARP好处)
- [warp 运行脚本](README.md#warp-运行脚本)
- [warp-go 运行脚本](README.md#warp-go-运行脚本)
- [Cloudflare api](README.md#cloudflare-api)
- [刷 Netflix 解锁 WARP IP 的方法](README.md#刷-Netflix-解锁-WARP-IP-的方法)
- [WARP socks5 或 interface 分流模板及解锁 chatGPT 的方法](README.md#warp-socks5-或-interface-分流模板及解锁-chatgpt-的方法)
- [WARP+ License 及 ID 获取](README.md#warp-license-及-id-获取)
- [WARP Teams 获取并用于 Linux 的方法](README.md#WARP-Teams-获取并用于-Linux-的方法)
- [WARP原理](README.md#WARP原理)
- [鸣谢 WARP 贡献者和 CloudFlare WARP 全球站点服务状态列表](README.md#鸣谢下列作者的文章和项目)

* * *

## 更新信息
2026.08.29 menu.sh v3.2.7-selfheal.10 将 `sockswg` 统一为严格 IPv4-only：新装不再写入 WARP IPv6 地址、`::/0` 或 IPv6 策略规则，watchdog 只检测 IPv4；Debian 13/MicroSocks 强制绑定 WARP IPv4，防止纯 IPv6 请求回落到 VPS 原生出口。非 SOCKS 本机流量不会进入 WARP。

2026.08.29 sockswg-bluegreen 试运行版：在同一 VPS 上增加 IPv4-only A/B WARP 对等灾备。当前活动槽只在连续健康失败时切换；切换后不自动回切，正常槽会持续使用。空闲槽位于独立网络命名空间，切换只影响新连接，旧连接自然排空。健康判断同时验证地区、WARP 状态和 Google 非 `429`；健康但非 `optimal` 的空闲槽每小时最多筛选一次 IP，先轮换 Endpoint，新 Peer 注册仅作为兜底。B 槽自动适配 Debian 12/Dante 与 Debian 13/MicroSocks，暂不随 `warp p` 默认安装。

2026.08.29 menu.sh v3.2.7-selfheal.9 修复 Debian 12/Dante 与 Soga 的本机对接：Soga 连接 `127.0.0.1` SOCKS 时可能绑定 VPS 公网源地址，旧配置仅允许来源 `127.0.0.1/32`，导致 SOCKS 握手立即被重置。监听仍严格绑定回环地址，不向公网开放，但现在接受本机进程使用任一本地源地址连接。

2026.08.28 menu.sh v3.2.7-selfheal.8 强化批量迁移：临时端口预检也会自动尝试全部官方 Endpoint 端口；正式接管原 SOCKS 端口时保留已验证并完成握手的 WireGuard 网卡，只切换 SOCKS 监听，避免大量 Soga 连接同时重连时与隧道冷启动竞争。

2026.08.28 menu.sh v3.2.7-selfheal.7 增加 Debian 13 兼容后端：若系统源没有 `dante-server`，自动安装 MicroSocks，并用独立的 `sockswg-proxy` 系统用户和 UID 策略路由确保 IPv4/IPv6 出站只进入 `sockswg`，主机默认路由不变。

2026.08.28 menu.sh v3.2.7-selfheal.6 新增 `sockswg`：使用内核 WireGuard 承载 WARP，由 Dante 在本机提供 SOCKS5，保留 Soga 等应用既有的按规则 SOCKS 分流，同时绕开 WireProxy 单进程用户态数据面的性能上限。迁移采用临时端口双栈预检、失败自动回滚；独立 watchdog 支持服务拉起、IPv4/IPv6 分栈检测和官方 UDP Endpoint 轮换。

2026.08.28 menu.sh v3.2.7-selfheal.5 增加 WireProxy Endpoint 自动故障转移：任意已配置栈连续检测失败达到阈值后，按 Cloudflare 官方 WireGuard 端口 `2408 → 4500 → 500 → 1701 → 2408` 轮换 Endpoint，再重启并复测。避免当前运营商或防火墙阻断某个 UDP 端口时只能手动修改配置；可通过 `/etc/default/warp-wireproxy-watchdog` 关闭或自定义端口顺序。

2026.08.28 menu.sh v3.2.7-selfheal.4 修复 WireProxy 单栈故障漏检：watchdog 从配置自动识别 IPv4/IPv6，分别访问 Cloudflare 的 IPv4 与 IPv6 trace 地址并独立累计连续失败次数；任意已配置栈连续失败两次即恢复 WireProxy，`warp=on` 与 `warp=plus` 均视为健康。新增双栈、单栈、Plus 与交替故障回归测试。

2026.08.28 menu.sh v3.2.7-selfheal.3 根治 WireProxy 长期运行的孤儿连接泄漏：仓库内保存完整的 v1.1.3 修复源码、回归测试与三架构构建；活跃的半关闭响应保持不断，静默孤儿连接才会被回收，不再使用内存阈值重启。保留 SOCKS 数据面自动保活及完整生命周期集成。

2026.08.08 menu.sh v3.2.7 1. 优化 IPv6 路由规则，同网段地址均能正常访问; 2. 新增内置自动保活 —— 定时检测 WARP 接口状态，掉线后自动重新获取新的 WARP IP，避免网络中断

2026.07.06 menu.sh v3.2.6 通过缩小 CIDR 范围解决 WARP 接口的路由冲突

2026.05.01 menu.sh v3.2.5 在 wireguard 内核获取 WARP IP 失败后回退重试 wireguard-go

<details>
    <summary>历史更新（点击展开或收起）</summary>
<br>

>2026.04.28 menu.sh v3.2.4 1. 修复 wireproxy 获取双栈 WARP 网络的问题; 2. 将 wireproxy DNS 解析策略设置为 auto
>
>2026.04.10 menu.sh v3.2.3 1. 菜单调整：已移除更换 License (warp a) 功能; 2. 优化函数，提升执行效率
>
>2026.03.01 warp-go.sh v1.3.2 为 IPv4 / IPv6 only 主机使用固定 IP 端点
>
>2026.02.25 menu.sh v3.2.2 Restore Reserved configuration for Warp usage; 由于部分地区使用 Warp，仍需保留 Reserved 配置，因此恢复之前的配置文件
>
>2026.02.22 menu.sh v3.2.1 / warp-go.sh v1.3.1 1. 移除系统版本号判断，以支持滚动发行版; 2. cloudflare.now.cc -> cloudflare.nyc.mn
>
>2026.01.02 menu.sh v3.2.0 / warp-go.sh v1.3.0 1. 账户管理优化： 顺应 Cloudflare 对 WARP 账户政策的调整，移除了已过时的 WARP+ 和 Teams 账户类型，精简了安装流程及账户升级功能（受影响命令：warp a）; 2. 修复卸载 Bug： 修正了 Linux Client 在 Proxy 模式下，卸载程序后误操作路由规则而导致的网络故障问题; 3. 性能提升： 引入自建 IP API 替代第三方接口，显著提升了 IP 信息获取和脚本初始化的速度; 4. 脚本清理： 移除了部分不再使用的冗余脚本提示语及过时代码块，使输出界面更加简洁; 5. 刷 IP 逻辑： 将 Netflix 解锁检测的默认首选项从 IPv4 调整为 IPv6
>
>2025.09.10 menu.sh v3.1.8 增强脚本对 Arch Linux 及 EndeavourOS 系统的兼容性
>
>2025.08.24 menu.sh v3.1.7 1. 适配 Ubuntu 24.04 及以上版本安装 Warp，感谢网友 [Michaol] 提供的解决方案; 2. 适配 Debian 13 安装 Client，感谢用户 [ainp] 的反馈
>
>2025.08.11 menu.sh v3.1.6 / warp-go.sh v1.2.4 删除最优 Endpoint 功能以适应官方调整
>
>2025.03.24 menu.sh v3.1.5 1. 处理了 Client 的 Warp 模式(网络接口)重启后不工作的问题; 2. 修正 Team IPv6 判断的正则
>
>2024.12.24 menu.sh v3.1.4 / warp-go.sh v1.2.3 支持 Docker 在无需使用 host 网络模式的情况下，对外监听 0.0.0.0/0。感谢网友 @Anthony_Tel
>
>2024.9.24 menu.sh v3.1.3 Linux Client 增加 MASQUE 协议可选项，Proxy 模式（菜单5）和 WarpProxy 模式（菜单14）都可以使用
>
>2024.9.14 menu.sh v3.1.2 / warp-go.sh v1.2.2 1. 由于官方禁止了克隆 Warp+ license，故去掉生成 license 的功能; 2. 去掉不必要的依赖 python3
>
>2024.7.25 menu.sh v3.1.1 / warp-go.sh v1.2.1 1. 支持使用自建 warp api: https://warp.cloudflare.now.cc/?run=pluskey，生成 1920 PB WARP+ license 升级为 Plus 账户; 2. Client 对 WARP+ 支持不够，只能使用 IPv4，不能使用 IPv6; 3. 优化安装程序，缩短脚本运行时间
>
>2024.7.18 menu.sh v3.1.0 / warp-go.sh v1.2.0 1. 使用自建 warp api: https://warp.cloudflare.now.cc/ ，升级为 Teams 账户，不需要提前获取 Token; 2. 由于 Client 的设置需要到 Cloudflare 控制后台设置，处理不好会导致 vps 失去联系，所以 Client 并没有升级为 Teams 账户的处理
>
>2024.7.8 menu.sh v3.0.10 / warp-go.sh v1.1.9 1. 发布 warp api，可以注册账户，加入 Zero Trust，查账户信息等所有的操作; 2. 脚本更新 warp api
>
>2024.6.30 menu.sh v3.0.9 1. 通过多线程，并行处理最优 MTU，最优 endpoint，下载 wireguard-go 和安装依赖，脚本运行时间缩短一半以上; 2. 用 Cloudflare worker 反向代理，以更好支持双栈及提升获取速度; 3. DNS 优先级: Cloudflare 1.1.1.1 > Google 8.8.8.8
>
>2024.6.28 menu.sh v3.0.8 官方 WARP Linux Client 支持 arm64 系统，Socks5 proxy 模式和 Warp interface 模式均可用
>
>2024.6.2 menu.sh v3.0.7 支持 CentOS 9 / Alma Linux 9 / Rocky Linux 9 系统
>
>2024.5.5 menu.sh v3.0.6 / warp-go.sh v1.1.8 支持 Alpine edge 系统
>
>2024.5.1 menu.sh v3.0.5 处理 Debian 10 安装 wireguard-tools 的 apt 库变更的问题
>
>2024.4.14 menu.sh v3.0.4 1. Alpine 检测并更新 wget 版本； 2. 获取 IP 失败时增加提示信息以便反馈
>
>2024.3.21 menu.sh v3.0.3 / warp-go.sh 1.1.7 1. 根据 warp-cli 官方更新部分命令； 2. 去掉 Github cdn
>
>2024.2.7 menu.sh v3.0.2 判断系统是否已经加载 wireguard 内核模块，如果还没有则尝试加载，再重新判断
>
>2023.12.19 menu.sh v3.0.1 / warp-go.sh 1.1.6 增加是否允许 udp 的检测，如果 WARP 的所有 endpoint 均不能连通，脚本将中止
>
>2023.8.22 menu.sh v3.0.0 / warp-go.sh 1.1.5 添加 Github CDN
>
>2023.8.15 menu.sh v3.0.0 1. 增加warp的非全局工作模式，可以通过 [warp g] 切换，需要重装脚本; 2. 支持被Cloudflare制裁地区，如俄罗斯，使用共享账户; 3. IPv6 only 使用预设 nat64，卸载时恢复原始 nameserver 文件
>
>2023.7.21 menu.sh v3.0.0 beta2 1. 如果系统支持 wireguard kernel 和 wireguard-go-reserved，可以通过 [warp k] 切换，需要重装脚本; 2. 支持 Fedora 系统; 3. 修复 client 2023.7.40-1 版本导致的开关错误
>
>2023.6.30 menu.sh v3.0.0 beta 重要更新: 1. 全面用 Cloudflare 官方 warp api 替代 wgcf; 2. 使用 wireguard-go with reserved 替代内核。使香港，洛杉矶等受限地区使用 warp; 3.由于改动太大，请用户重新安装
>
>2023.6.27 menu.sh V2.53 Wireproxy proxy 模式支持 warp 双栈
>
>2023.6.21 menu.sh V2.52 1. Client Proxy 模式支持 warp 双栈; 2. Client warp 模式支持 warp 双栈; 3. 加快脚本启动速度
>
>2023.6.18 menu.sh V2.51 Client 支持 Debian 12 (bookworm)
>
>2023.5.20 menu.sh V2.50 1. Client 支持 IPv6 only VPS 安装; 2. 支持包括 token 等4种方式升级为 teams 账户; 3. 卸载的同时使用 api 删除 warp 账户
>
>2023.5.15 发布 Cloudflare WARP api，感谢 badafans的开源项目
>
>2023.5.10 warp-go V1.1.4 1. 对接 warp-go 官方账户池 api; 2. 非全局从ipv4 only 改为双栈; 3. 修复双栈时使用原生 IPv6 不能登陆的 bug; 4. 更新最佳 Endpoint 应用; 5. 更换 ip api
>
>2023.3.26 warp-go V1.1.3 / menu.sh 2.49 1. warp endpoint 优选改为标准端口 [500,1701,2408,4500]; 2. 升级奈飞解锁部分
>
>2023.3.14 warp-go V1.1.2 / menu.sh 2.48 自动寻找最适合本机使用的 endpoint，应用在 wgcf, warp-go 和 client
>
>2023.3.2 warp-go V1.1.1 1. 支持 warp-go v1.0.8 , 允许在配置文件自定义 MTU 值; 2. Singbox配置导出 reseved 使用三个数字的数组代替字符串
>
>2023.2.7 menu.sh V2.47 Iptables + dnsmasq + ipset 方案支持 chatGPT
>
>2022.12.17 warp-go V1.1.0 支持 OpenWrt 系统
>
>2022.12.10 warp-go V1.0.9 1. 使用 [warp-go e] 导出 wireguard 和 sing-box 配置文件; 2.获取 teams token 网站更换
>
>2022.10.19 menu V2.46 / warp-go V1.0.8 通过 [warp s 4/6/d] 或者 [warp-go 4/6/d]来切换 IPv4 / IPv6 的优先级别
>
>2022.10.7 warp-go V1.0.7 1. 进一步完善账户间转换功能，可以从一个 WARP+ 换到另一个; 2. 优化代码
>
>2022.10.6 menu V2.45 1. 进一步完善账户间转换功能; 2. 重构账户注册模块
>
>2022.8.29 warp-go V1.0.6 1.解决了非全局模式重启后，路由规则失效的bug; 2.解决了更换不了IP的bug
>
>2022.8.27 menu V2.44 重构卸载逻辑，依赖卸载需要确认
>
>2022.8.23 menu V2.43 warp-go V1.0.5 支持 NAT 服务器，例如 Woiden
>
>2022.8.21 menu V2.42 1.在菜单中增加快捷方式的提示; 2.移除快捷方式 s，单双栈相互切换可以直接 [warp 4/6/d]
>
>2022.8.20 warp-go V1.0.4 中英双语支持
>
>2022.8.20 warp-go V1.0.3 菜单 + 快捷方式，适合各种使用场景
>
>2022.8.17 warp-go v1.0.2 1.新增 WARP IPv4 非全局方案; 2.输出 wgcf 配置文件
>
>2022.8.13 warp-go v1.0.1 1.新增 WARP+ 升级功能; 2.新增 Teams 升级功能; 3.新增刷解锁奈飞IP功能; 4.支持 GOAMD64v4 等指令集
>
>2022.8.13 全网首发 @CoiaPrant 的 warp-go 一键脚本
>
>2022.8.5 2.41 通过 API 获取 WARP+ 剩余流量
>
>2022.6.27 香港 IPv6 only 安装 Client 的方式
>
>2022.6.11 2.40 支持 VPS-free LXC VPS
>
>2022.5.25 2.39 1.每天自动同步官方最新版本; 2.更换 CloudFlare client 的安装方式
>
>2022.5.18 2.38 1. 全面支持 Ubuntu 22.04 和 CentOS Streams 9 LTS; 2. 优化 Debian 以提升安装速度
>
>2022.4.21 macOS 一键脚本发布
>
>2022.4.8 2.37 全网首发: WARP-Cli 的 WARP 模式方案
>
>2022.3.27 2.36 1. 全网首发: 通过 wireproxy 建立 socks5 代理; 2. WARP+ 和 Teams 可用于 WireProxy; 3. WireProxy systemd 进程守护
>
>2022.3.23 2.35 支持 Debian 9 上安装 WARP
>
>2022.3.19 2.34: 新增 Arch Linux 的支持
>
>2022.3.11 2.33: 1. 全网首发， WARP Client 支持 Ubuntu 18.04 and CentOS 7; 2. 为 OVZ VPS 在线打开 TUN
>
>2022.2.25 2.32: 1.更换 WARP 的 endpoint; 2. 同步 Netflix 检测 title
>
>2022.2.15 docker 解锁方案发布
>
>2022.2.11 2.31: iptables + dnsmasq + ipset 最小化解锁流媒体
>
>2022.1.25 流媒体解锁守护进程,定时5分钟检查一次
>
>2022.1.21 2.30: 1.全面支持WARP单栈与双栈方案; 2.刷解锁 Netflix WARP IP 时可带期望的地区; 3.修正刷 Netflix IP 时可能发生的卡死不动的bug
>
>2022.1.11 2.26: 1.在刷解锁 Netflix WARP IP 之前让用户输入想要的区域; 2.单栈与双栈快速切换
>
>2022.1.6 Docker 方案重大技术突破
>
>2022.1.1 元旦更新：刷奈飞IP时加入时间戳和运行时长
>
>2021.12.29 其他 WARP 脚本推荐
>
>2021.12.28 2.25: 1. 全网首发，支持 IBM Linux One 的 s390x 架构 CPU; 2.支持 Alpine Linux 系统; 3.支持 Debian bookworm系统
>
>2021.12.24 2.24: 1.默认语言设置为安装时候选择的; 2.支持 HAX LXC VPS
>
>2021.12.17 2.23: 1.支持 WARP Interface 和 Socks5 Client 自动更换支持奈飞的IP; 2.支持在线升级为 TEAM 账户
>
>2021.12.14 2.22: Teams 账户实验（已回退）
>
>2021.12.11 2.21: 1.BoringTUN 因不稳定而移除; 2.域名解析服务器首先谷歌; 3.统计运行次数
>
>2021.12.04 2.20: 1.全网首创，安装时间缩短一半以上; 2.中英双语关联数组重构
>
>2021.11.30 2.11: 更换支持 Netflix IP 改编自成熟作品
>
>2021.11.11 2.10: 1.自定义 IPv4 / IPv6 优先组别; 2.自定义 Client Socks5 代理端口
>
>2021.11.06 2.09: 1.支持 WARP Linux Client; 2.Client 支持 WARP+ 账户升级; 3.自定义 WARP+ 设备名
>
>2021.11.01 2.08: 1.自动设置最优 MTU; 2.显示asn组织(线路提供商)
>
>2021.10.29 2.07: 1.支持中英文; 2.大幅优化速度; 3.修复重启后启动WARP的bug
>
>2021.10.23 2.06: 1.添加自动检查是否开启 Tun 模块； 2.提高脚本适配性; 3.新增平台支持
>
>2021.10.15 2.05: 1.WGCF 2.2.9 更新； 2.升级重启后运行处理; 3.修复 KVM WARP+ 升级bug
>
>2021.10.14 2.04: 1.LXC 用户选择 BoringTun 或 Wireguard-go; 2.原生双栈VPS限制; 3.自动关闭通道处理
>
>2021.10.12 2.03: 网络刷新的优化，限制次数为10次
>
>2021.10.10 2.02: 用 curl 替换 wget 进行 IP 检测
</details>

## 脚本特点

* 支持 WARP+ 账户，附带第三方刷 WARP+ 流量和升级内核 BBR 脚本
* 普通用户友好的菜单，进阶者通过后缀选项快速搭建
* 智能判断vps操作系统：Ubuntu 16.04、18.04、20.04; Debian 9、10、11，CentOS 7、8; Alpine 和 Arch Linux，请务必选择 LTS 系统
  智能判断硬件结构类型：AMD、ARM 和 s390x
* 结合 Linux 版本和虚拟化方式，自动优选三个 WireGuard 方案。
  网络性能方面：内核集成 WireGuard＞安装内核模块＞BoringTun＞wireguard-go
* 智能判断 WGCF 作者 github库的最新版本 （Latest release）
* 智能分析内网和公网IP生成 WGCF 配置文件
* 输出结果，提示是否使用 WARP IP ，IP 归属地

## WARP好处

* 支持 chatGPT，解锁奈飞流媒体
* 避免 Google 验证码或是使用 Google 学术搜索
* 可调用 IPv4 接口，使青龙和V2P等项目能正常运行
* 由于可以双向转输数据，能做对方VPS的跳板和探针，替代 HE tunnelbroker
* 能让 IPv6 only VPS 上做的节点支持 Telegram
* IPv6 建的节点能在只支持 IPv4 的 PassWall、ShadowSocksR Plus+ 上使用

<img src="https://user-images.githubusercontent.com/62703343/144635014-4c027645-0e09-4b84-8b78-88b41f950627.png" width="80%" />

## warp 运行脚本

首次运行
```
wget -N https://raw.githubusercontent.com/vruru/warp-selfheal/main/menu.sh && bash menu.sh [option] [lisence/url/token]
```
再次运行
```
warp [option] [lisence]
```
  | [option] 变量1 变量2 | 具体动作说明 |
  | ----------------- | --------------- |
  | h | 帮助 |
  | 4 | 原无论任何状态 -> WARP IPv4 |
  | 4 lisence name | 把 WARP+ Lisence 和设备名添加进去，如 ```bash menu.sh 4 N5670ljg-sS9jD334-6o6g4M9F Goodluck``` |
  | 6 | 原无论任何状态 -> WARP IPv6 |
  | d | 原无论任何状态 -> WARP 双栈 |
  | o | WARP 开关，脚本主动判断当前状态，自动开或关 |
  | u | 卸载 WARP |
  | n | 断网时，用于刷WARP网络 (WARP bug) |
  | b | 升级内核、开启BBR及DD |
  | p | 刷 Warp+ 流量 |
  | c | 安装 WARP Linux Client，开启 Socks5 代理模式 |
  | l | 安装 WARP Linux Client，开启 WARP 模式 |
  | c lisence | 在上面基础上把 WARP+ Lisence 添加进去，如 ```bash menu.sh c N5670ljg-sS9jD334-6o6g4M9F``` |
  | r | WARP Linux Client 开关 |
  | v | 同步脚本至最新版本 |
  | i | 更换 WARP IP |
  | e | 安装 iptables + dnsmasq + ipset 分流流媒体方案 |
  | w | 安装 WireProxy 解决方案 |
  | y | WireProxy 开关 |
  | k | 切换 wireguard 内核 / wireguard-go-reserved |
  | g | 切换 warp 全局 / 非全局 或首次以 非全局 模式安装 |
  | s | s 4/6/d，切换优先级 warp IPv4 / IPv6 / 默认  |
  | 其他或空值| 菜单界面 |

举例：想为 IPv4 的甲骨文添加 Warp 双栈，首次运行
```
wget -N https://raw.githubusercontent.com/vruru/warp-selfheal/main/menu.sh && bash menu.sh d
```
刷日本 Netflix  运行
```
warp i jp
```


## warp-go 运行脚本
首次运行
```
wget -N https://raw.githubusercontent.com/vruru/warp-selfheal/main/warp-go.sh && bash warp-go.sh [option] [lisence]
```
再次运行
```bash
warp-go [option] [lisence]
```
  | [option] 变量1 变量2 | 具体动作说明 |
  | ----------------- | --------------- |
  | h | 帮助 |
  | 4 | 原无论任何状态 -> WARP IPv4 |
  | 4 lisence name | 把 WARP+ Lisence 和设备名添加进去，如 ```bash wire-go 4 N5670ljg-sS9jD334-6o6g4M9F Goodluck``` |
  | 6 | 原无论任何状态 -> WARP IPv6 |
  | d | 原无论任何状态 -> WARP 双栈 |
  | o | warp-go 开关，脚本主动判断当前状态，自动开或关 |
  | u | 卸载 warp-go |
  | v | 同步脚本至最新版本 |
  | 其他或空值| 菜单界面 |


## Cloudflare api

### Cli-API 使用指南，浏览器带参数访问，或者使用 `curl` 命令可以执行 Warp API 请求，

| run 参数 | 作用描述 | 参数 | 示例 |
|---|---|---|---|
|  | 使用指南 | | `https://warp.cloudflare.now.cc/` |
| `register` | 注册新设备 | `team_token（可选）`, `format（可选）` | `https://warp.cloudflare.now.cc/?run=register&team_token=<Your-Team-Token>&format=<json\|yaml\|client\|wireguard\|warp-go\|\|clash\|xray\|sing-box\|qrencode>` |
| `device` | 获取特定设备的详细信息 | `device_id`, `token` | `https://warp.cloudflare.now.cc/?run=device&device_id=<Your-Device-ID>&token=<Your-Token>` |
| `app` | 获取客户端配置 | `token` | `https://warp.cloudflare.now.cc/?run=app&token=<Your-Token>` |
| `bind` | 将设备绑定到帐户 | `device_id`, `token` | `https://warp.cloudflare.now.cc/?run=bind&device_id=<Your-Device-ID>&token=<Your-Token>` |
| `name` | 设置设备名称 | `device_id`, `token`, `device_name` | `https://warp.cloudflare.now.cc/?run=name&device_id=<Your-Device-ID>&token=<Your-Token>&device_name=<Your-Device-Name>` |
| `license` | 设置设备许可证 | `device_id`, `token`, `license` | `https://warp.cloudflare.now.cc/?run=license&device_id=<Your-Device-ID>&token=<Your-Token>&license=<Your-License>` |
| `unbind` | 从帐户中取消绑定设备 | `device_id`, `token` | `https://warp.cloudflare.now.cc/?run=unbind&device_id=<Your-Device-ID>&token=<Your-Token>` |
| `cancel` | 取消设备注册 | `device_id`, `token` | `https://warp.cloudflare.now.cc/?run=cancel&device_id=<Your-Device-ID>&token=<Your-Token>` |
| `id` | Client ID 与 Reserved 转换 | `convert` | `https://warp.cloudflare.now.cc/?run=id&convert=<4-char-string\|Numbers1,Numbers2,Numbers3>` |
| `token` | 获取 Zero Trust token | `organization`, `email`, `code` | step1: `https://warp.cloudflare.now.cc/?organization=<Your-Organization>&email=<Your-Email>` </br> step2: `https://warp.cloudflare.now.cc/?organization=<Your-Organization>&cf_appsession=<App-Session-Value>&cf_session=<Session-Value>&nonce=<Nonce-Value>&code=<Your-Code>` |
| `key` | 生成一对 WireGuard 公私钥 | `format（可选）` | `https://warp.cloudflare.now.cc/?run=key&format=<json\|yaml>` |

### Shell-API 运行脚本
```
wget -N https://raw.githubusercontent.com/vruru/warp-selfheal/main/api.sh && bash api.sh [option]
```
  | [option] 变量  | 具体动作说明 |
  | ------------- | ------------- |
  | -h/--help     | 帮助 |
  | -f/--file     | 保存账户注册信息的文件，支持官方api，client，wgcf 和 warp-go ，不填则手动输入 device id 和 api token |
  | -r/--register | 注册账户 |
  | -t/--token    | -r 注册时，使用 team token 注册，快速获取: https://web--public--warp-team-api--coia-mfs4.code.run |
  | -d/--device   | 获取账户注册信息，包括 plus 流量等 |
  | -a/--app      | 获取 app 信息 |
  | -b/--bind     | 获取绑定设备信息，包括子设备 |
  | -n/--name     | 修改设备名称 |
  | -l/--license  | 修改 license |
  | -u/--unbind   | 解绑设备 |
  | -c/--cancle   | 注销账户 |
  | -i/--id       | 显示 cliend id 与 reserved |
  | -m/--masque-register | 注册 MASQUE 账户 |
  | -s/--masque-enroll  | 续期 MASQUE 账户 |
  | -g/--config          | MASQUE 配置文件 (默认: config.json) |
  | -p/--device-name     | 注册或续期时设置设备名称 |
  | -k/--regen-key       | 续期或更新时强制重新生成密钥对 |
  | -o/--organization string | Team 组织名，通过邮箱验证码自动获取 Team Token 并注册 (需输入参数) |
  | -e/--email string        | Team 邮箱 (需输入参数) |


## 刷 Netflix 解锁 WARP IP 的方法

* 可以用另一个通过 WARP 解锁流媒体的一键脚本: [【刷 WARP IP】 - 为 WARP 解锁流媒体而生](https://github.com/fscarmen/unlock_warp)

* 以刷 香港 hk 为例， 运行 `warp i`。建议在 screen， nohup 下后台运行

* 如果长时间仍然未刷出解锁IP，可以查查 CloudFlare 当地是否在维护调路由：https://www.cloudflarestatus.com/


## WARP socks5 或 interface 分流模板及解锁 chatGPT 的方法

<details>
    <summary> 指定网站分流到 socks5 的 xray 配置模板 (适用于 WARP Client Proxy 和 WireProxy)（点击即可展开或收起）</summary>
<br>

本地 socks5://127.0.0.1:40000
并安装 [mack-a 八合一脚本](https://github.com/mack-a/v2ray-agent) 为例。编辑  ```/etc/v2ray-agent/xray/conf/10_ipv4_outbounds.json```

```
{
    "outbounds":[
        {
            "protocol":"freedom"
        },
        {
            "tag":"warp",
            "protocol":"socks",
            "settings":{
                "servers":[
                    {
                        "address":"127.0.0.1",
                        "port":40000 // 填写你的 socks5 端口
                    }
                ]
            }
        },
        {
            "tag":"WARP-socks5-v4",
            "protocol":"freedom",
            "settings":{
                "domainStrategy":"UseIPv4"
            },
            "proxySettings":{
                "tag":"warp"
            }
        },
        {
            "tag":"WARP-socks5-v6",
            "protocol":"freedom",
            "settings":{
                "domainStrategy":"UseIPv6"
            },
            "proxySettings":{
                "tag":"warp"
            }
        }
    ],
    "routing":{
        "rules":[
            {
                "type":"field",
                "domain":[
                    "geosite:openai",
                    "ip.gs"
                ],
                "outboundTag":"WARP-socks5-v4"
            },
            {
                "type":"field",
                "domain":[
                    "geosite:google",
                    "geosite:netflix",
                    "p3terx.com"
                ],
                "outboundTag":"WARP-socks5-v6"
            }
        ]
    }
}
```
</details>

<details>
    <summary> 指定网站分流到 "interface" 的 xray 配置模板（适用于 WARP Client Warp 和 warp / warp-go 非全局）（点击即可展开或收起）</summary>
<br>

```
{
    "outbounds":[
        {
            "protocol":"freedom"
        },
        {
            "tag":"WARP-interface-v4",
            "protocol":"freedom",
            "settings":{
                "domainStrategy":"UseIPv4"
            },
            "streamSettings":{
                "sockopt":{
                    "interface":"CloudflareWARP", // warp 非全局模式填 warp; Client 的 Proxy 模式填 CloudflareWARP; warp-go 填 WARP
                    "tcpFastOpen":true
                }
            }
        },
        {
            "tag":"WARP-interface-v6",
            "protocol":"freedom",
            "settings":{
                "domainStrategy":"UseIPv6"
            },
            "streamSettings":{
                "sockopt":{
                    "interface":"CloudflareWARP",
                    "tcpFastOpen":true
                }
            }
        }
    ],
    "routing":{
        "domainStrategy":"AsIs",
        "rules":[
            {
                "type":"field",
                "domain":[
                    "geosite:google",
                    "geosite:openai",
                    "ip.gs"
                ],
                "outboundTag":"WARP-interface-v4"
            },
            {
                "type":"field",
                "domain":[
                    "geosite:netflix",
                    "p3terx.com"
                ],
                "outboundTag":"WARP-interface-v6"
            }
        ]
    }
}
```
</details>

<details>
    <summary> 通过 WARP 解锁 chatGPT 的方法（点击即可展开或收起）</summary>
<br>

思路是使用已经注册的 warp 做链式代理的设置，此解决方法是最轻便的，用户只要有 xray 即可。具体做法是修改 xray 配置文件的 outbound 和 routing，模板如下
```
{
    "outbounds":[
        {
            "protocol":"freedom",
            "tag": "direct"
        },
        {
            "protocol":"wireguard",
            "settings":{
                "secretKey":"YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=", // 粘贴你的 "private_key" 值
                "address":[
                    "172.16.0.2/32",
                    "2606:4700:110:8a36:df92:102a:9602:fa18/128"
                ],
                "peers":[
                    {
                        "publicKey":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                        "allowedIPs":[
                            "0.0.0.0/0",
                            "::/0"
                        ],
                        "endpoint":"engage.cloudflareclient.com:2408" // 或填写 162.159.192.1:2408 或 [2606:4700:d0::a29f:c001]:2408
                    }
                ],
                "reserved":[78, 135, 76], // 粘贴你的 "reserved" 值
                "mtu":1280
            },
            "tag":"wireguard"
        },
        {
            "protocol":"freedom",
            "settings":{
                "domainStrategy":"UseIPv4"
            },
            "proxySettings":{
                "tag":"wireguard"
            },
            "tag":"warp-IPv4"
        },
        {
            "protocol":"freedom",
            "settings":{
                "domainStrategy":"UseIPv6"
            },
            "proxySettings":{
                "tag":"wireguard"
            },
            "tag":"warp-IPv6"
        }
    ],
    "routing":{
        "domainStrategy":"AsIs",
        "rules":[
            {
                "type":"field",
                "domain":[
                    "geosite:openai",
                    "ip.gs"
                ],
                "outboundTag":"warp-IPv4"
            },
            {
                "type":"field",
                "domain":[
                    "geosite:netflix",
                    "p3terx.com"
                ],
                "outboundTag":"warp-IPv6"
            }
        ]
    }
}
```
</details>


## WARP+ License 及 ID 获取

以下是使用WARP和Team后 Argo 2.0 的官方介绍:[Argo 2.0: Smart Routing Learns New Tricks](https://blog.cloudflare.com/argo-v2/)

引用Luminous大神原话：实际测试WARP+在访问非CF的网站速度上和免费版没有差异，只有在访问CloudFlare的站点时付费版会通过Argo类似的技术通过与目标较近的数据中心前往源站，而免费版是仅限于连接地前往源站，仅此而已。

<img src="https://user-images.githubusercontent.com/62703343/136070323-47f2600a-13e4-4eb0-a64d-d7eb805c28e2.png" width="70%" />


## WARP Teams 获取并用于 Linux 的方法

* https://warp-token.cloudflare.now.cc/ , 通过 fscarmen 的网站

* https://web--public--warp-team-api--coia-mfs4.code.run/, 通过 Coia 的网站

## WARP原理

WARP是CloudFlare提供的一项基于WireGuard的网络流量安全及加速服务，能够让你通过连接到CloudFlare的边缘节点实现隐私保护及链路优化。

其连接入口为双栈（IPv4/IPv6均可），且连接后能够获取到由CF提供基于NAT的IPv4和IPv6地址，因此我们的单栈服务器可以尝试连接到WARP来获取额外的网络连通性支持。这样我们就可以让仅具有IPv6的服务器访问IPv4，也能让仅具有IPv4的服务器获得IPv6的访问能力。

* 为仅IPv6服务器添加IPv4

原理如图，IPv4的流量均被WARP网卡接管，实现了让IPv4的流量通过WARP访问外部网络。

<img src="https://user-images.githubusercontent.com/62703343/135735404-1389d022-e5c5-4eb8-9655-f9f065e3c92e.png" width="70%" />

* 为仅IPv4服务器添加IPv6

原理如图，IPv6的流量均被WARP网卡接管，实现了让IPv6的流量通过WARP访问外部网络。

<img src="https://user-images.githubusercontent.com/62703343/135735414-01321b0b-887e-43d6-ad68-a74db20cfe84.png" width="70%" />

* 双栈服务器置换网络

有时我们的服务器本身就是双栈的，但是由于种种原因我们可能并不想使用其中的某一种网络，这时也可以通过WARP接管其中的一部分网络连接隐藏自己的IP地址。至于这样做的目的，最大的意义是减少一些滥用严重机房出现验证码的概率；同时部分内容提供商将WARP的落地IP视为真实用户的原生IP对待，能够解除一些基于IP识别的封锁。
<img src="https://user-images.githubusercontent.com/62703343/135735419-50805ed6-20ea-4440-93b4-5bcc6f2aca9b.png" width="70%" />

* 网络性能方面：内核集成＞内核模块＞wireguard-go


## 鸣谢下列作者的文章和项目

互联网永远不会忘记，但人们会。

技术文章或相关项目（排名不分先后）:
* P3terx: https://p3terx.com/archives/use-cloudflare-warp-to-add-extra-ipv4-or-ipv6-network-support-to-vps-servers-for-free.html
* P3terx: https://github.com/P3TERX/warp.sh/blob/main/warp.sh
* 猫大: https://github.com/Oreomeow
* Luminous: https://luotianyi.vc/5252.html
* Hiram: https://hiram.wang/cloudflare-wrap-vps
* Cloudflare: https://pkg.cloudflareclient.com/   
https://blog.cloudflare.com/announcing-warp-for-linux-and-proxy-mode/   
https://blog.cloudflare.com/argo-v2/
* WireGuard: https://lists.zx2c4.com/pipermail/wireguard/2017-December/002201.html
* Parker C. Stephens: https://parkercs.tech/cloudflare-for-teams-wireguard-config/
* Anemone: https://cutenico.best/posts/blogs/cloudflare-warp-fixed-youtube-location/    
https://github.com/acacia233/Project-WARP-Unlock
* wangying202: https://blog.csdn.net/wangying202/article/details/113178159
* LUBAN: https://github.com/HXHGTS/Cloudflare_WARP_Connect
* valetzx: https://gitlab.com/valetzx/pubfile
* badafans cf api: https://github.com/badafans/warp-reg
* chika0801: https://github.com/chika0801/Xray-examples/
* xXcmd1152Xx: https://github.com/cmd1152/WarpPlusKeyGenerator-NG-lib
* 所有的热心网友们

服务提供（排名不分先后）:
* fscarmen 的 Warp API: https://warp.cloudflare.now.cc/
* fscarmen 的 Zero Trust Token API: https://warp-token.cloudflare.now.cc/
* CloudFlare Warp(+): https://1.1.1.1/
* WGCF 项目原作者: https://github.com/ViRb3/wgcf/
* Coia 和 warp-go 团队: https://gitlab.com/ProjectWARP/warp-go
* warp-go api wiki: https://docs.zeroteam.top/apis/warp
* WireGuard-GO 官方: https://git.zx2c4.com/wireguard-go/
* ylx2016 的成熟作品: https://github.com/ylx2016/Linux-NetSpeed
* ALIILAPRO 的成熟作品: https://github.com/ALIILAPRO/warp-plus-cloudflare
* mixool 的成熟作品: https://github.com/azples/across/tree/main/wireguard
* luoxue-bot 的成熟作品:https://github.com/luoxue-bot/warp_auto_change_ip
* lmc999 的成熟作品: https://github.com/lmc999/RegionRestrictionCheck
* WireProxy 作者: https://github.com/pufferffish/wireproxy
* 获取公网 IP 及归属地查询: https://ifconfig.co/ , https://ip.gs/ , https://ip.sb/ , https://ip-api.com
* 统计PV网: https://hits.seeyoufarm.com/
* Coia 的网页版提取 Teams Token: https://web--public--warp-team-api--coia-mfs4.code.run

CloudFlare WARP 全球站点和服务状态:
* Operational = 正常。Re-routed = 检修状态: https://www.cloudflarestatus.com/
