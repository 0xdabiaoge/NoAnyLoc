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
- 🎯 **分级防御架构（彻底解决 Google Anycast 共享 VIP 难题）**：
  谷歌定位与 Google Play 商店共享同一组 Anycast 前端 IP。NoAnyLoc-Host 独创**四层与七层协同防御体系**：对 Google 定位采用 **七层 TLS SNI 深度包检测** 精准狙击，放行 Google Play 商店与安卓系统核心，**绝对零误杀**；对苹果、微软等独立 IP 定位采用 **四层 IPSet + 七层 SNI 双保险**，兼具极致性能与 100% 阻断率。
- 🔄 **原子化动态保鲜（告别 Anycast IP 漂移）**：
  内置多路权威海外公共 DNS 并发深挖，采用 `ipset swap` 实现**毫秒级零丢包原子热替换**。配合独立的 Systemd Timer（默认每 2 小时静默保鲜一次），永不失效。
- 🛡️ **双重保险：TLS SNI 字符串熔断**：
  利用内核 `xt_string` 模块，在 443/80 端口的 TLS Client Hello 握手阶段精准识别定位域名并直接回送 **TCP RST 瞬间切断**，包含 Wi-Fi 与基站特征的数据包哪怕 1 个字节都无法离开母机。
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
     【第一梯队：七层 TLS SNI 精准熔断】             【第二梯队：四层 IPSet 高速哈希】
     针对 Google 定位 / Apple / 微软 / 开源          针对具有独立物理 IP 的高精度定位池
     TLS Client Hello 命中定位域名特征串              发往独立定位目标 IP 的 TCP/UDP 报文
     ──> 立即回送 TCP RST 掐死 (保护 Play 商店)       ──> 硬件级秒杀 + 回送 TCP RST 拒连
                      │                                               │
                      +-----------------------+-----------------------+
                                              │ (放行 Google Play / YouTube / 正常流量)
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
  * 公网 IPv4 地址 : 198.51.100.88
  * 公网 IPv6 状态 : 2001:db8::1 [已启用]
  * 出网物理网卡   : eth0
  * 容器网桥设备   : vmbr0, lxcbr0
 --------------------------------------------------------------------
 【防护状态监控】
  * 拦截总闸门状态 : [ 运行中 / ACTIVE - 保护全部小鸡出网 ]
  * 当前规则条目数 : IPv4: 40 条 | IPv6: 32 条
  * 动态保鲜守护   : 已启用 (Systemd Timer 自动保鲜)
  * 拦截受控链条   : FORWARD (全体容器小鸡) + OUTPUT (宿主机本机)
======================================================================
  1. 开启 / 重载 宿主机全局防送中 (一键构建双栈拦截规则链)
  2. 暂停 / 解除 全局防护 (安全清退，不残留任何内核规则)
  3. 立即强制刷新 IP 资产池 (多路 DNS 并发解析并原子替换)
  4. 运行【全景送中健康体检】(深度探测 Google/YouTube/Cloudflare)
  5. 配置自动保鲜守护参数 (修改刷新周期 / 调整 SNI 阻断)
  6. 查看【实时拦截战报与命中统计】(详细阻断次数与可视化仪表盘)
  7. 检查并在线更新脚本 (从 GitHub 官方源拉取最新版)
  8. 彻底卸载此脚本与所有自启服务
  0. 退出控制台
======================================================================
```

---

## 📊 实时拦截战报与命中统计面板 (Dashboard)

执行 `noanyloc stats` 或在菜单选择 `6`，即可查看按防护维度精准汇总的**可视化拦截战报**：

```text
================================================================================
           NoAnyLoc-Host 防火墙实时拦截战报与命中统计面板 (Dashboard)           
================================================================================
 【核心拦截战报总览】
  * 累计成功阻断定位次数 : 842 次 (已为宿主机及全部容器小鸡击落 842 次潜在定位上报)
  * 累计物理阻断定位流量 : 48.62 KB
  * 防护总闸门实时状态   : [ 运行中 / ACTIVE - 保护中 ]
  * 内存拦截规则池规模   : IPv4: 40 个节点 | IPv6: 32 个节点
 --------------------------------------------------------------------------------
 【IPv4 细分规则拦截战报 (详细命中)】
  * [SNI-Google-Geo] Google 定位 API (七层 SNI 精准熔断 · 保护Play) : 成功拦截 12 次 (阻断数据: 6.84 KB)
  * [SNI-Google-Code] Google 地理编码 (七层 SNI 精准熔断) : 成功拦截 0 次 (阻断数据: 0 B)
  * [SNI-Apple-Global] Apple 全球定位服务 (七层 SNI 握手熔断) : 成功拦截 25 次 (阻断数据: 14.22 KB)
  * [SNI-Apple-CN] Apple 中国专属定位 (七层 SNI 握手熔断) : 成功拦截 8 次 (阻断数据: 4.55 KB)
  * [SNI-Apple-LS] Apple 位置子域全通配 (七层 SNI 握手熔断) : 成功拦截 19 次 (阻断数据: 10.81 KB)
  * [SNI-AppleMap] Apple 地图定位服务 (七层 SNI 握手熔断) : 成功拦截 0 次 (阻断数据: 0 B)
  * [SNI-Mozilla] Mozilla MLS 定位 (七层 SNI 握手熔断) : 成功拦截 0 次 (阻断数据: 0 B)
  * [SNI-MS-Location] Windows 位置服务 (七层 SNI 握手熔断) : 成功拦截 0 次 (阻断数据: 0 B)
  * [SNI-MS-Inference] Windows 位置推断 (七层 SNI 握手熔断) : 成功拦截 0 次 (阻断数据: 0 B)
  * [SNI-BeaconDB] 开源 BeaconDB 定位 (七层 SNI 握手熔断) : 成功拦截 0 次 (阻断数据: 0 B)
  * [SNI-Skyhook] 高通/Skyhook 定位 (七层 SNI 握手熔断) : 成功拦截 0 次 (阻断数据: 0 B)
  * [IPSet-TCP] 独立定位目标池 (四层 TCP 握手秒级熔断) : 成功拦截 778 次 (阻断数据: 46.68 KB)
  * [IPSet-UDP] 独立定位目标池 (四层 UDP/ICMP 阻断) : 成功拦截 0 次 (阻断数据: 0 B)

  * IPv4 统计小计: 累计拦截 842 次 | 累计丢弃定位流量 48.62 KB
 --------------------------------------------------------------------------------
================================================================================
  [C] 清零统计计数器 (重置数据包统计)   [R] 实时刷新   [回车键] 返回主菜单
================================================================================
```

---

## ⚙️ 命令行快捷指令（适合自动化批量运维）

| 快捷命令 | 功能说明 |
| :--- | :--- |
| `noanyloc` | **呼出交互主菜单**：可视化查看宿主机网络参数、启停防护与诊断 |
| `noanyloc start` | **启动/加载防护**：注入 `FORWARD` 与 `OUTPUT` 拦截链条并自启定时保鲜 |
| `noanyloc stop` | **暂停/撤销防护**：清空并卸载自定义规则链，宿主机恢复直连无残留 |
| `noanyloc restart` | **平滑重载系统**：重新构建 IPSet 内存集合与 Netfilter 流水线 |
| `noanyloc update` | **强制刷新 IP 资产池**：多路并发解析定位端点并毫秒级热替换 |
| `noanyloc upgrade` | **在线热升级脚本**：从 GitHub 官方仓库拉取最新版本并平滑覆盖升级 |
| `noanyloc stats` | **查看可视化拦截战报**：直观展示拦截次数、阻断数据量及各维度命中明细 |
| `noanyloc test` | **一键全景体检**：发起对 Google/YouTube/Cloudflare 的穿透诊断并输出报告 |
| `noanyloc uninstall` | **彻底卸载自毁**：清除所有防火墙规则、Systemd 服务、配置目录与脚本自身，100% 零残留 |

---

## 🎯 全生态高精拦截靶点矩阵

通过 **七层 TLS SNI 深度包检测** 与 **四层 IPSet 硬件加速** 分级协作，兼顾极致拦截率与业务零误杀：

| 生态厂商 | 拦截域名 / 靶点 | 靶点功能与送中威胁 | 防御层级 | 业务安全性 |
| :--- | :--- | :--- | :---: | :---: |
| **Google** | `geolocation.googleapis.com` | 谷歌核心 Wi-Fi / 基站众包定位 API（送中头号元凶） | 七层 SNI 熔断 | **100% 保护 Google Play / 安卓系统** |
| | `geocode.googleapis.com` | 谷歌地理编码与逆地址推断 API | 七层 SNI 熔断 | **100% 保护 Google 业务** |
| | `locationhistory-pa.googleapis.com` | **谷歌安卓系统级时间轴与位置轨迹上报接口** | 七层 SNI 熔断 | **100% 保护 Google 业务** |
| | `userlocation.googleapis.com` | **谷歌安卓底层用户实时基站/Wi-Fi网络定位** | 七层 SNI 熔断 | **100% 保护 Google 业务** |
| | `semanticlocation-pa.googleapis.com` | **谷歌语义化位置与停留地点识别服务** | 七层 SNI 熔断 | **100% 保护 Google 业务** |
| **Apple** | `gs-loc.apple.com` | 苹果全球全局定位守护进程（locationd） | 四层 IPSet + 七层 SNI | 独立物理 IP，绝对零误杀 |
| | `gs-loc-cn.apple.com` | **苹果中国大陆专属定位网关（国内苹果用户核心死角）** | 四层 IPSet + 七层 SNI | 独立物理 IP，绝对零误杀 |
| | `*.ls.apple.com` *(通配)* | **全通配苹果 gspe1~99 动态定位与国家代码 (GCC) 探针** | 七层 SNI 匹配 `.ls.apple.com` | 苹果业务顶级域名隔离，零误杀 |
| | `maps-api.apple.com` | 苹果地图定位校验与逆地理请求 | 四层 IPSet + 七层 SNI | 独立物理 IP，绝对零误杀 |
| **Microsoft** | `location.microsoft.com` | Windows 10/11 系统位置服务接口 | 四层 IPSet + 七层 SNI | 独立物理 IP，零误杀 |
| | `inference.location.live.net` | 微软全球 Wi-Fi / 蜂窝网络位置推断平台 | 四层 IPSet + 七层 SNI | 独立物理 IP，零误杀 |
| **Mozilla / 开源** | `location.services.mozilla.com` | Mozilla MLS 定位网络（经典 Linux / Firefox） | 四层 IPSet + 七层 SNI | 独立物理 IP，零误杀 |
| | `api.beacondb.net` | **新一代开源定位数据库（microG、类原生安卓、Fedora）** | 四层 IPSet + 七层 SNI | 独立物理 IP，零误杀 |
| **高通 / 芯片级** | `api.skyhookwireless.com` | 高通骁龙基带 / Skyhook 陆基 Wi-Fi 定位网关 | 四层 IPSet + 七层 SNI | 独立物理 IP，零误杀 |

> 🛡️ **绝对安全保证**：本系统**绝不包含** `www.googleapis.com`、`google.com`、`googlevideo.com`、`captive.apple.com`、`connectivitycheck.android.com` 等基础业务与连通性探测域名，群友刷 YouTube、下载 Google Play 游戏、使用 Google Drive、苹果 iCloud 同步毫秒级畅通无阻！

---

## 🩺 全景体检报告样例

执行 `noanyloc test` 时输出的实机诊断样例：

```text
================================================================
           宿主机 IP 全景“送中”健康体检报告                     
================================================================
【1. IP 基础档案与机房属性】
  * 当前公网 IP : 198.51.100.88
  * 注册归属地  : US - Los Angeles
  * 运营商/ASN  : AS64512 Example Datacenter

【2. Google 搜索服务与位置标签检测】
  * 首页跳转检测: [正常] 正常停留在 google.com 国际站
  * 底栏地理位置: [正常/无大陆标记] 当前标注为海外正常区域

【3. YouTube 流媒体区域与高级权限检测】
  * 归属国家代码: [正常: US] (支持后台播放与 YouTube Premium 完整功能)

【4. Cloudflare 边缘定位检测】
  * Cloudflare 判定: [海外正常: US] (WARP状态: off)

【5. 本机当前防护拦截实战测试】
  * 定位 API 阻断: [拦截成功 - 流量已被拒绝或切断 (TCP RST)]
================================================================
```

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源发布。
欢迎提交 Issue 与 Pull Request 共同改进！
