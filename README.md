# 🛡️ NoAnyLoc-Host (宿主机全局防送中系统)

<p align="center">
  <img src="https://img.shields.io/badge/Language-Bash%20Shell-4EAA25.svg" alt="Bash">
  <img src="https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu%20%7C%20PVE-E95420.svg" alt="Platform">
  <img src="https://img.shields.io/badge/Kernel-IPSet%20%7C%20Netfilter-0078D7.svg" alt="Netfilter">
  <img src="https://img.shields.io/badge/Status-Production%20Ready-brightgreen.svg" alt="Status">
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License">
</p>

> **专为 PVE / Proxmox / LXD / Incus / KVM 虚拟化宿主机打造的母机级出网流量总闸门。**  
> 在宿主机出网最底层，强力阻断流经系统及所有容器小鸡的 Wi-Fi 与基站定位 API 请求，从根源上彻底解决海外优质原生 IP 被国内翻墙买家手机“送中”的行业顽疾！

---

## 📌 痛点背景：为什么刚广播的优质 IP 几天就“送中”？

很多 IDC 商家、合租站长常常遇到令人抓狂的问题：
> *“明明买的是干净的美西/欧洲/新加坡原生双 ISP IP，开成 LXC 小鸡卖给买家搭建 Xray / Sing-box 翻墙。才过了三四天，Google 搜索直接跳转香港，底栏显示‘中国xx省xx市’，YouTube Premium 画中画直接失效，买家开始集体轰炸工单要求退款换 IP……”*

### 罪魁祸首：客户端 Wi-Fi BSSID 与蜂窝基站众包逆向定位
国内用户的手机（Android / iOS / Windows）通常默认开启了系统定位权限并授权给 Google Play 服务（GMS）。在手机连接节点翻墙的同时，后台系统会静默扫描**周围邻居的 Wi-Fi MAC 地址（BSSID）和周边基站 ID（Cell Towers）**，并打包发往海外定位 API（如 `geolocation.googleapis.com`）。  
Google 和各大厂的大数据中枢收到请求后，会发现：**“这个请求来自海外 VPS 的公网 IP，但附带的 Wi-Fi 全是中国大陆某小区的 MAC 地址！”**，随后自动将该 VPS 的公网 IP 与大陆经纬度强行绑定，完成“送中污染”。

传统在小鸡内装脚本的方式极易被买家重装系统绕过，且单次 DNS 解析无法应对 CDN IP 漂移，甚至因误杀 `www.googleapis.com` 导致用户连 Google 账号都登不上。**NoAnyLoc-Host 专为宿主机母机设计，在流量出母机物理网卡前执行一票否决！**

---

## ✨ 核心特性

- 🏰 **母机总闸门防护（无法绕过）**：
  规则前置注入宿主机的 `FORWARD` 链（保护该母机下所有现有及未来新建的 LXC 容器与 KVM 虚拟机）和 `OUTPUT` 链（保护母机自身）。小鸡买家即使拥有 root 权限并不慎清空防火墙，也绝不可能突破母机内核的拦截！
- ⚡ **$O(1)$ 高性能内核哈希（不卡网速）**：
  基于 Linux 内核原生 `IPSet (hash:ip)`，查询复杂度为常数级 $O(1)$。哪怕宿主机切出上百个实例批量跑满 10Gbps 带宽，CPU 软中断损耗微乎其微，**吞吐量零损耗**。
- 🎯 **高精定位资产库（绝对零误杀）**：
  彻底剔除了传统方案中危险的广谱域名（如 `www.googleapis.com`）。实测买家看 YouTube 4K、Google 搜索、Google Drive、账号登录毫秒级正常通行，**100% 仅狙击纯定位 API 流量**。
- 🔄 **原子化动态保鲜（告别 Anycast IP 漂移）**：
  内置多路权威海外公共 DNS 并发深挖，采用 `ipset swap` 实现**毫秒级零丢包原子热替换**。配合独立的 Systemd Timer（默认每 2 小时静默保鲜一次），永不失效。
- 🛡️ **双重保险：TLS SNI 字符串熔断**：
  利用内核 `xt_string` 模块限制搜索区间（`--from 40 --to 180`），在 443 端口的 TLS Client Hello 握手阶段精准识别定位域名并直接回送 **TCP RST 瞬间切断**，双保险兜底。
- 📦 **安全沙盒隔离（绝不污染宿主机）**：
  独立自定义链与专属集合，**绝对不触碰宿主机原有的 PVEFW 防火墙、Docker 规则、NAT 端口映射或 SSH 白名单**。卸载时支持物理级自毁与 100% 零残留。
- 🩺 **全景送中健康体检仪**：
  内置开箱即用的一键全景体检引擎，深度穿透测试 Google 重定向与底栏坐标、YouTube 归属国家、Cloudflare 边缘定位，秒级评估 IP 真实健康度。

---

## 🏗️ 架构与数据包拦截拓扑

```text
[LXC 小鸡 101]   [LXC 小鸡 102]   ...   [LXC 小鸡 N]   [宿主机本机]
      │                │                      │            │
      └────────────────┴──────────┬───────────┘            │
                                  ▼                        ▼
                        虚拟网桥 (vmbr0 / lxcbr0)          │
                                  │                        │
                                  ▼                        ▼
                          [FORWARD 链顶层]           [OUTPUT 链顶层]
                                  │                        │
                                  └───────────┬────────────┘
                                              ▼
                                 +-------------------------+
                                 |  自定义链: NOANYLOC     |
                                 +-------------------------+
                                              │
                      +-----------------------+-----------------------+
                      ▼                                               ▼
         【第一道：IPSet 高速哈希比对】                   【第二道：xt_string SNI 熔断】
       发往定位 API 目标 IP 的 TCP 数据包               TLS Client Hello 带有定位域名
       ──> 物理丢弃 + 回送 TCP RST 拒连                 ──> 物理丢弃 + 回送 TCP RST 拒连
                      │                                               │
                      +-----------------------+-----------------------+
                                              │ (正常放行所有合法业务流量)
                                              ▼
                                 宿主机物理网卡出口 (eth0 / eno1)
                                              │
                                              ▼
                                    公网 Internet (100% 纯净)
```

---

## 🚀 快速开始

### 系统要求
* **操作系统**：Debian 11 / 12、Ubuntu 20.04 / 22.04 / 24.04、Proxmox VE (PVE 7 / 8) 等 Debian / Ubuntu 系列宿主机。
* **权限要求**：`root` 权限。

### ⚡ 极速一键安装命令

在宿主机母机终端中复制并执行以下任一命令即可：

#### 方案 A：一键极速运行控制台（推荐）
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0xdabiaoge/NoAnyLoc/main/noanyloc.sh)
```
*(加速镜像备用：`bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/0xdabiaoge/NoAnyLoc/main/noanyloc.sh)`)*

#### 方案 B：一键静默安装并立即开启全局防护（适合批量脚本编排）
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0xdabiaoge/NoAnyLoc/main/noanyloc.sh) start
```

#### 方案 C：安装为系统全局命令 `noanyloc`
```bash
curl -fsSL https://raw.githubusercontent.com/0xdabiaoge/NoAnyLoc/main/noanyloc.sh -o /usr/local/bin/noanyloc && chmod +x /usr/local/bin/noanyloc
```
安装后，随时在终端直接输入 `noanyloc` 即可调出管理控制台！

---

## 🖥️ 交互控制台预览

启动后将显示精美的彩色状态面板与网卡监控：

```text
======================================================================
        NoAnyLoc-Host 宿主机全局防送中系统 (Debian/Ubuntu 专属)       
      专为 Debian / Ubuntu (含 Proxmox VE) 宿主机打造 | 纯 Shell 打造 
======================================================================
 【宿主机网络信息】
  * 公网 IPv4 地址 : 78.31.249.125
  * 公网 IPv6 状态 : 未启用或无路由
  * 出网物理网卡   : eth0
  * 容器网桥设备   : vmbr0, lxcbr0
 --------------------------------------------------------------------
 【防护状态监控】
  * 拦截总闸门状态 : [ 运行中 / ACTIVE - 保护全部小鸡出网 ]
  * 当前规则条目数 : IPv4: 33 条 | IPv6: 20 条
  * 动态保鲜守护   : 已启用 (Systemd Timer 自动保鲜)
  * 拦截受控链条   : FORWARD (全体容器小鸡) + OUTPUT (宿主机本机)
======================================================================
  1. 开启 / 重载 宿主机全局防送中 (一键构建双栈拦截规则链)
  2. 暂停 / 解除 全局防护 (安全清退，不残留任何内核规则)
  3. 立即强制刷新 IP 资产池 (多路 DNS 并发解析并原子替换)
  4. 运行【全景送中健康体检】(深度探测 Google/YouTube/Cloudflare)
  5. 配置自动保鲜守护参数 (修改刷新周期 / 调整 SNI 阻断)
  6. 查看实时拦截命中与数据包统计
  7. 彻底卸载此脚本与所有自启服务
  0. 退出控制台
======================================================================
```

---

## ⚙️ 命令行快捷指令（适合自动化批量运维）

无需进入交互菜单，直接带参调用，适合结合 Ansible、PVE Hook 或 Kickstart 批量初始化：

| 命令 | 功能说明 |
| :--- | :--- |
| `noanyloc start` | **一键开启全局防送中**：自动补齐依赖、并发解析、注入规则并启动 Systemd 定时保鲜 |
| `noanyloc stop` | **一键暂停防护**：从 FORWARD/OUTPUT 拔除跳转并注销规则，恢复宿主机原始网络状态 |
| `noanyloc restart` | 重载并重新生成所有规则链 |
| `noanyloc update` | **立即强制原子刷新**：重新向多路 DNS 请求并以 `ipset swap` 无缝替换 IP 池 |
| `noanyloc test` | **一键全景体检**：发起对 Google/YouTube/Cloudflare 的穿透诊断并输出报告 |
| `noanyloc status` | 查看当前防火墙各条规则的实时拦截包数（Packet Drop Count）与统计 |
| `noanyloc uninstall` | **彻底卸载自毁**：清除所有防火墙规则、Systemd 服务、配置目录与脚本自身，100% 零残留 |

---

## 🎯 默认高精拦截资产库

位于 `/etc/noanyloc/domains.conf`，您可以随时添加自定义域名：

- **Google 定位与逆地理编码**：
  - `geolocation.googleapis.com` *(Wi-Fi/基站定位核心接口)*
  - `geocode.googleapis.com`
- **Apple 位置服务**：
  - `gspe1-ssl.ls.apple.com`
  - `gs-loc.apple.com`
  - `maps-api.apple.com`
  - `ls.apple.com`
- **Mozilla MLS 定位**：
  - `location.services.mozilla.com`
- **Microsoft Windows 定位**：
  - `location.microsoft.com`
  - `inference.location.live.net`

> ⚠️ **重要保证**：本系统**绝不包含** `www.googleapis.com`、`google.com`、`googlevideo.com` 等基础业务域名，杜绝任何误杀！

---

## 🩺 全景体检报告样例

执行 `noanyloc test` 时输出的实机诊断样例：

```text
================================================================
           宿主机 IP 全景“送中”健康体检报告                     
================================================================
【1. IP 基础档案与机房属性】
  * 当前公网 IP : 78.31.249.125
  * 注册归属地  : DE - Frankfurt am Main
  * 运营商/ASN  : AS205548 ZOUTER LIMITED

【2. Google 搜索服务与位置标签检测】
  * 首页跳转检测: [正常] 正常停留在 google.com 国际站
  * 底栏地理位置: [正常/无大陆标记] 当前标注为海外正常区域

【3. YouTube 流媒体区域与高级权限检测】
  * 归属国家代码: [正常: DE] (支持后台播放与 YouTube Premium 完整功能)

【4. Cloudflare 边缘定位检测】
  * Cloudflare 判定: [海外正常: DE] (WARP状态: off)

【5. 本机当前防护拦截实战测试】
  * 定位 API 阻断: [拦截成功 - 流量已被拒绝或切断 (TCP RST)]
================================================================
```

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源发布。
欢迎提交 Issue 与 Pull Request 共同改进！
