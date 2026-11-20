# LeiKwan Relay

一个可独立运行的 Linux 部署脚本，把 **SS2022 / VLESS Encryption / Snell v5 入站**接到 **VLESS + REALITY / AnyTLS 落地**，每个入口可独立选择落地和源地址线路。支持多个入口、多个落地，以及 CN2 / 9929 对比和手动切换。

```text
客户端 ─ SS2022 / VLESS Encryption / Snell v5 ─ 中转机
                                                │
                                         选择源 IP / 网卡
                                                │
                                      REALITY / AnyTLS
                                                │
                                             落地机 ─ Internet
```

## 一键运行

在每台需要部署的机器上以 root 执行：

```bash
curl -fL --retry 3 -o /tmp/leikwan-relay.sh https://raw.githubusercontent.com/Gavin-LHX/leikwan-relay/main/deploy.sh && bash /tmp/leikwan-relay.sh
```

之后输入 `lkr` 可再次打开菜单；`lkr --help` 查看命令行用法。先部署落地，再配置中转机线路，最后添加中转入口。

`deploy.sh` 是自包含文件，不依赖克隆仓库。它内嵌 Python 管理器，按需安装内核。源代码位于 `src/manager.py`，运行 `python3 tools/build.py` 重建脚本。

## 当前协议支持

| 用途 | 协议 | 实现与客户端要求 |
| --- | --- | --- |
| 入口 | SS2022 | sing-box；`2022-blake3-aes-128-gcm`，自动生成 16 字节密钥 |
| 入口 | VLESS Encryption | Xray；`mlkem768x25519plus.native`，1-RTT，600 秒会话票据；客户端须实际支持该加密特性 |
| 入口 | Snell v5 | sing-box 原生入站；支持 TCP 和 UDP over TCP；**不支持 Snell v5 专用 QUIC Proxy 模式** |
| 中转至落地 | VLESS + REALITY | TCP、Vision、uTLS；可导入常规 `vless://` 链接 |
| 中转至落地 | AnyTLS | TLS 验证开启；新建落地生成自签证书并通过配对信息传递信任证书 |

Snell 入口输出 Surge 配置行，通常配合 `block-quic = all` 让 HTTP/3 回退至 TCP；其他 UDP 仍可通过 UDP over TCP。也会导出 sing-box 客户端 JSON，其 `version: 4` 是 sing-box 兼容 v5 TCP 的客户端格式。Snell 官方现已有 v6；本脚本按需求提供 v5，不会自动改协议。

VLESS Encryption 入口输出含 `encryption` 参数的 `vless://` 链接及完整 Xray 客户端 JSON。部分客户端的链接导入器可能丢弃这个参数，请检查导入后的配置。不能仅凭客户端旧教程中的版本号判断兼容性。

脚本固定 sing-box **1.14.4** 与 Xray **26.11.9**，从官方 GitHub Releases 下载，并校验仓库内固定的 SHA-256。支持 amd64、arm64。适用 Debian 12/13、Ubuntu 22.04/24.04 的 systemd 环境；实机验证环境为 Debian 13 amd64。

## 1. 配置落地

REALITY 示例：

```bash
lkr exit-add --name exit-reality --protocol reality \
  --host EXIT_PUBLIC_IP --port 18443 \
  --sni www.cloudflare.com
lkr show --name exit-reality
```

`--target` 默认等于 `--sni`，握手目标端口默认 443，可用 `--target-port` 修改。需要从落地访问该目标的 TLS 1.3 服务，目标应与 SNI 匹配。

AnyTLS 示例：

```bash
lkr exit-add --name exit-anytls --protocol anytls \
  --host EXIT_PUBLIC_IP --port 18444 --sni relay.example.com
lkr show --name exit-anytls
```

自签证书名称可以使用一个固定 DNS 名，不要求有域名指向这台服务器。`lkr://` 配对信息包含证书、密码和落地地址，可复制到中转端。它是本项目的配置交换格式，**不是通用客户端协议链接**。需要直接连接 AnyTLS 落地时使用导出的 `client-sing-box.json`。对于已有的有效公开证书，也可导入 `anytls://PASSWORD@HOST:PORT?sni=NAME`；不接受跳过证书验证的上游链接。

放行对应 TCP 端口；本脚本不更改主机防火墙或云端安全组。

## 2. 配置中转线路

先看本机真实地址和网关：

```bash
lkr routes
ip -4 route
ip -6 route
# 多网卡没有同时显示默认网关时，检查网管配置：
cat /run/systemd/network/*.network
```

给每条源地址线路指定本机 IP、网卡和对应网关，线路名称可自行命名。下面是**虚构示例**，必须替换成本机数据：

```bash
lkr route-add --name unicom9929 --interface eth0 \
  --source 10.7.0.10 --gateway 10.7.0.1
lkr route-add --name cn2 --interface eth1 \
  --source 10.8.0.10 --gateway 10.8.0.1
```

每条线路创建独立路由表和源地址规则，并通过 systemd 在开机时恢复。不会修改 main 表默认路由。仅使用 24000–24999 范围，碰到已有路由表或规则会停止，可以通过 `--table 24xxx` 指定其他空闲编号。

NAT IPv4 机器应填写本机私网源地址，不能填 NAT 公网地址。线路名只用于管理，不能代替实际探测；不要仅凭 eth0/eth1 命名断言线路。IPv6 源地址线路也支持，但落地地址必须与所选源地址使用同一个 IP 版本。域名落地按线路限制解析地址族。

## 3. 比较 CN2 / 9929

```bash
# 可选：安装诊断工具；不安装时仍能做 TCP 连接采样
apt-get update && apt-get install -y mtr-tiny traceroute

lkr probe --target EXIT_PUBLIC_IP --port 18443 --count 20 \
  --output /root/probe-exit.json
# 机器已有 nexttrace 时，可额外运行它
lkr probe --target EXIT_PUBLIC_IP --port 18443 --nexttrace
```

每条线路都绑定自己的源 IP 做采样。优先比较目标端口 TCP 连接失败率，再比较中位延迟和抖动。路由探测优先采用 MTR 和 TCP traceroute；`--nexttrace` 会调用已经安装的 NextTrace。部分中间节点不响应 TCP 探测，可补做 ICMP/UDP traceroute；报告中的 `unknown` 表示未观察到可识别的骨干跳点。

仅在实际跳点出现 `59.43.*` 时标注 CN2，出现 `210.13.*`、`218.105.*`、`210.14.*` 时推测 9929。这个标注是路径线索。中间跳点丢包不等于端到端丢包；TCP 采样也不代表可用带宽、长期稳定性或客户端回程质量。脚本输出本轮建议，**不会自动切换线路**。应针对每台落地分别测试，并在高峰期复测。

## 4. 添加入口

先把落地配对信息保存为仅 root 可读文件，避免命令历史记录密钥：

```bash
umask 077
cat > /root/upstream.txt
# 粘贴一整行 lkr:// 或 vless://，然后 Ctrl-D
```

三种入口任选，也可同时创建：

```bash
lkr relay-add --name us-ss --protocol ss2022 --host ENTRY_PUBLIC_IP \
  --port 21001 --upstream @/root/upstream.txt --egress unicom9929

lkr relay-add --name us-enc --protocol vlessenc --host ENTRY_PUBLIC_IP \
  --port 21002 --upstream @/root/upstream.txt --egress unicom9929

lkr relay-add --name hk-snell --protocol snell5 --host ENTRY_PUBLIC_IP \
  --port 21003 --upstream @/root/hk-upstream.txt --egress cn2
```

`--upstream` 也接受本项目导出的落地 JSON 文件。`--host` 是客户端实际连接的入口地址，用于生成连接信息；默认监听 `[::]`，在正常双栈 Linux 上兼容 IPv4。可用 `--listen 0.0.0.0` 或具体本机地址调整监听。

利群 NAT IPv4 没有映射入口端口时，可使用本机公网 IPv6。SSH 转发地址和 SSH 映射端口并不代表代理端口也有映射。IPv4-only 客户端需要另行配置前置或供应商端口映射。

```bash
lkr show --name us-ss
lkr list
lkr test --name us-ss
lkr test --name us-ss --udp
# 默认从 ::1 测入口，覆盖地址可测试其他监听形式/公网回接
lkr test --name us-ss --server 127.0.0.1
```

`test` 启动临时真实协议客户端，经入口、所选线路及落地请求 Cloudflare trace，完成后清理临时进程；输出 `ip=` 应为落地出口 IP。它能验证完整协议链，但本机测试不能替代从外网到入口的验证。导出的客户端 JSON 默认开本地 SOCKS5 `127.0.0.1:1080`。

SS2022、Snell 由 sing-box 处理；VLESS Encryption 使用独立 Xray 入站，经 `127.0.0.1` SOCKS 桥接至 sing-box 的所选上游。所有中转数据只配置所选上游，不配置故障直连回退。每个入口有一个仅监听本机的 SOCKS 桥接端口，自动分配，也可用 `--bridge-port` 明确指定。

如果外网到入口的原生 UDP 不通，SS2022 可以使用 **UoT v2**，经 TCP 承载 UDP。添加入口时加 `--ss-uot`，已有入口执行：

```bash
lkr relay-set --name us-ss --ss-uot on
lkr test --name us-ss --udp
```

然后使用重新导出的 `client-sing-box.json`，或在支持 UoT 的客户端中手动开启 UDP over TCP v2。标准 `ss://` URI 不携带这个扩展设置；仅复制 URI 仍然会使用原生 UDP。可以用 `--ss-uot off` 恢复原生 UDP。UoT 是 SagerNet 扩展，需要客户端支持；普通 TCP 流量不受影响。

## 5. 切换和维护

```bash
# 保留客户端凭据，切换运营商线路
lkr relay-set --name us-ss --egress cn2
# 保留入口，切换落地
lkr relay-set --name us-ss --upstream @/root/other-upstream.txt
# 同时切换
lkr relay-set --name us-ss --egress unicom9929 --upstream @/root/us-upstream.txt
# 使用系统默认出口
lkr relay-set --name us-ss --egress default

lkr test --name us-ss
journalctl -u lkr-us-ss-sing-box -n 50 --no-pager
journalctl -u lkr-us-enc-xray -n 50 --no-pager

# 网管重新配置后恢复工具维护的路由；重复执行不会添加重复规则
lkr routes-apply

lkr remove --name us-ss
lkr route-remove --name cn2
```

切换会重启该入口的独立服务并断开它的现有连接。应用前进行真实内核配置检查；文件更新和服务启动失败时恢复原配置及原服务。上游连通性需要再运行 `test`，配置语法通过并不保证上游在线。

同名节点不能重复创建，已占用端口会拒绝。脚本使用独立路径和 `lkr-*` 服务，不替换原有 `xray.service`、`sing-box.service`、SSH 或其他防火墙规则。

| 路径 | 内容 |
| --- | --- |
| `/opt/leikwan-relay/` | 管理器及固定版本内核 |
| `/usr/local/bin/lkr` | 命令入口 |
| `/etc/leikwan-relay/nodes/NAME/` | 节点、内核配置、客户端配置、连接信息与证书 |
| `/etc/leikwan-relay/routes.json` | 本工具维护的源地址路由 |
| `/etc/leikwan-relay/backups/` | 更新/删除前的备份，含旧凭据，需要妥善保管 |
| `lkr-NAME-sing-box.service` | 独立入口/落地服务 |
| `lkr-NAME-xray.service` | VLESS Encryption 入口服务 |
| `lkr-routes.service` | 开机恢复源地址路由 |

目录及凭据仅 root 可读。删除节点会保留备份，删除线路会拒绝仍被节点使用的线路。脚本不会在卸载时清理其他服务。

## 验证

```bash
python3 -m unittest discover -s tests -v
LKR_CORE_DIR=/opt/leikwan-relay/bin python3 -m unittest discover -s tests -v
bash -n deploy.sh
```

第二条命令还会用真实固定版本内核检查生成的服务端和客户端配置。CI 会重建单文件脚本、检查是否与源代码同步并运行这些检查。公网接入、吞吐量和 UDP 业务应在各自网络环境中验证。

## 参考与实现说明

原理和需求参考以下教程；管理器为独立实现，没有直接执行教程中的第三方安装脚本：

- [SS → AnyTLS 中转教程](https://square.leikwanhost.com/forum-post/247.html)
- [VLESS Encryption → REALITY 教程](https://square.leikwanhost.com/forum-post/283.html)
- [多节点 Xray 脚本思路](https://square.leikwanhost.com/forum-post/447.html)
- [IPv4 多路由组指定出口](https://square.leikwanhost.com/forum-post/43.html)
- [sing-box Snell 入站与 QUIC 限制](https://sing-box.sagernet.org/configuration/inbound/snell/)
- [sing-box AnyTLS](https://sing-box.sagernet.org/configuration/outbound/anytls/)
- [sing-box 出站绑定字段](https://sing-box.sagernet.org/configuration/shared/dial/)
- [Xray VLESS Encryption](https://xtls.github.io/en/config/inbounds/vless.html)
- [Surge Snell 发布说明](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell)

路由由本脚本维护，避免依赖 HTTP 下载并直接运行供应商脚本。只管理明确登记的源 IP/网卡/网关；如果 IP 或网关发生变化，请先调整节点，再删除旧线路并重新添加。
