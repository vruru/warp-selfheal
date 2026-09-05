# Soga 直连 WARP A/B（无 SOCKS 数据面或检测）

这是已在 Debian 12 / Soga 2.16.2 节点验证的可选部署组件。现有
`sockswg/` SOCKS 模式继续保留，其他节点不会因更新仓库自动迁移。
本目录目前提供组件和迁移流程，不提供面向任意网络布局的一键安装。

## 路径与检测

| 源 IP（Soga 所在网络空间） | 路径 |
| --- | --- |
| `172.16.0.2` | 表 51821 → `sockswg` → WARP A |
| `10.203.2.1` | 表 51823 → `swgb-host` → `sockswg-b` 网络空间 → 表 51822 → `warp-b` → WARP B |

B 在自己的网络空间内也使用 `172.16.0.2`。namespace 内对来自
`10.203.2.1` 的业务做 SNAT，所以该方案需要内核连接跟踪，不能同时禁用它。
保留源地址禁止回退规则，WARP 路由缺失时不会落到普通公网默认路由。
这是 IPv4 模式，不应直接套用到有可用原生 IPv6 的节点而不验证地址选择。

所有 Cloudflare、Google、YouTube 地区及 Gemini 生成端点请求均绑定对应
源 IP，且禁用环境 HTTP/SOCKS 代理。B 检测从主网络空间使用 `10.203.2.1`，
覆盖业务同样经过的 namespace 转发与 SNAT。每次健康检测另验证一次 UDP DNS。
Gemini `BardErrorInfo`/429/无效响应拒绝逻辑、分槽及公网 IP 缓存、防抖和候选
出口筛选规则沿用原版。

`sockswg` 仅保留为网卡/服务命名。A 的修复仅重建 WireGuard；B 的服务为
`Type=oneshot`，管理 namespace 和路由，不运行 Dante/MicroSocks。普通服务
重启保留已有 namespace；候选修复在流量排空后显式重建它。

## 文件与部署位置

| 本目录文件 | 安装位置 |
| --- | --- |
| `sockswg-bluegreen` | `/usr/local/sbin/sockswg-bluegreen` |
| `sockswg-watchdog` | `/usr/local/sbin/warp-sockswg-watchdog` |
| `soga-warp-direct` | `/usr/local/sbin/soga-warp-direct` |
| `sockswg-bluegreen-b.service` | `/etc/systemd/system/sockswg-bluegreen-b.service` |
| `soga-warp-direct.service` | `/etc/systemd/system/soga-warp-direct.service` |

脚本需 executable 权限，Python 需 3.11+。前提是已有本项目的 WARP A/B
配置、账户文件、检测用户和定时器，且表 51823、规则优先级 10019/10030/10031
没有其他用途。迁移之前检查网络、备份上述文件、所有 systemd drop-in、
`/etc/soga/soga.conf`、`/etc/soga/routes.toml` 和服务 enable 状态。
备份包含账号配置时应限制 root 访问，勿上传仓库。

迁移顺序：

1. 暂停 A/B 检测及 A watchdog 定时器，等待正在执行的检测结束。保存备份，
   创建 root-only `/etc/soga-warp-direct`；初始化 `selected_at` 为当前 Unix 时间。
2. 部署 helper 并运行 `soga-warp-direct ensure`。分别验证 A/B 的 HTTPS 和 UDP。
   将全局 `auto_out_ip` 关闭，让显式分流源地址生效。首次修改全局配置时应安排
   Soga 重启窗口，启动还可能等待面板用户加载。
3. 用 `soga-warp-direct select a`（或已验证健康的 b）转换本地
   `127.0.0.1:40000` WARP 出口。其他规则保留；确认真实 Soga socket 源地址。
4. 安装本目录的检测脚本和 B service，清除旧 drop-in 中启动 SOCKS 或清理
   namespace 的命令，然后 `systemctl daemon-reload`。此时旧 B 进程还可运行。
5. 使用一个新的 `STATE_DIR` 分别执行 `sockswg-bluegreen test-a` / `test-b`，
   强制完整的 Gemini 检测，避免仅靠旧 SOCKS 检测缓存判定成功。
6. 确认主网络空间及 B namespace 都无已建立的 SOCKS 业务连接，再停用
   `sockswg.service`，停止旧 B daemon 并启动新的 B oneshot 服务。必须先加载
   不含 `ExecStopPost=cleanup-b` 的新 unit，否则停旧 B 会销毁仍有直连流量的
   namespace。校验 namespace inode 和 Soga PID 没有变化。
7. 禁用并 mask 旧 `sockswg.service`。若 unit 本身位于 `/etc/systemd/system`，
   先把已确认备份的旧 unit 移出该位置再 mask，不能覆盖丢弃。保留
   `wg-quick@sockswg.service`，启用 direct/B 服务及原有两个检测定时器。
8. 验证没有 40000/40002 listener、Dante/MicroSocks 进程；检查 A/B 直连检测、
   新连接切换和旧连接保留，再进行有计划的启动/故障演练。

不要运行旧 SOCKS 安装器覆盖直出版。直出版的旧 `install`/`ipv4-only-a`
入口故意拒绝运行；它们需要另一套安装流程，不能重新创建 SOCKS。

## 热切换与回退

切换修改的是对应 `routes.Outs` 的 `listen_ipv4`，保留 `routes.toml` inode
进行写入，使 Soga 本地文件监视器触发重载。写前校验 TOML；不要改成原子 rename，
实测这种替换未触发 Soga 2.16.2 重载。没有匹配 WARP 出口时拒绝修改。
新连接切到健康路径，旧 TCP/UDP 会话继续排空；实际断掉的出口无法保证旧会话存活。

完整回退必须一起恢复原 SOCKS 服务、检测脚本和路由配置。只恢复 SOCKS 类型的
Soga 路由而继续 mask SOCKS 会造成中断，因此 helper 的旧 `rollback` 命令拒绝
这种不完整回退。直连会话排空前也不要删除其源路由和 SNAT。

## 验证范围

```sh
python3 sockswg/direct/test_direct.py
bash -n sockswg/direct/sockswg-bluegreen
bash -n sockswg/direct/sockswg-watchdog
```

试点实测了 A/B HTTPS、UDP DNS、独立且不使用旧缓存的 Gemini 检测、文件热加载、
Soga 真实源绑定连接，以及注入两次检测失败后的自动切换。停止 SOCKS 时保留了
Soga PID 与 B namespace。故障注入针对检测结果，未对生产隧道做物理断网；
尚未完成重启整机和大流量 QUIC 压测，不能把这些项目算作通过。
