# IntelGuardian（英特尔守护）

**IntelGuardian** 是一个轻量、跨平台的系统健康监测工具，支持 **macOS** 与 **iOS**。它实时监测设备的发热与电池状态，一旦某项指标异常就通过 **邮件提醒** 通知你 —— 让你在设备过热、电量告急之前及时处理。

![平台](https://img.shields.io/badge/平台-iOS%2015%2B%20%7C%20macOS%2012%2B-blue)

---

## 目录

- [为什么需要 IntelGuardian](#为什么需要-intelguardian)
- [业务价值](#业务价值)
- [独特价值](#独特价值)
- [技术架构](#技术架构)
- [项目结构](#项目结构)
- [如何运行](#如何运行)
  - [环境要求](#环境要求)
  - [三端一键构建脚本](#三端一键构建脚本)
  - [Xcode 手动构建](#xcode-手动构建)
- [邮件告警配置](#邮件告警配置)
- [平台功能对比](#平台功能对比)
- [兼容性说明](#兼容性说明)

---

## 为什么需要 IntelGuardian

手机和电脑越来越快，也越来越烫。持续的高温会加速硬件老化、缩短电池寿命，而大多数人往往要等到设备降频、关机甚至电池鼓包才发现问题。

IntelGuardian 填补了这个盲区：

- **持续监测** —— 每 30 秒采样一次，保留 7 天历史数据。
- **主动告警** —— 一旦超过阈值立即发邮件，并附带趋势图。
- **双端一致** —— 一套代码，在 macOS 与 iOS 上都以原生方式运行。

## 业务价值

- **硬件保护** —— 过热提前预警，降低保修返修与设备更换成本。
- **设备可视化** —— 邮件标题自带设备类型、系统版本与用户名，一眼就能看出是**哪台机器**、**哪个指标**出了问题。
- **零运维成本** —— 无需后端服务器。SMTP 凭据存入钥匙串，邮件通过 Network.framework 直连发送，不依赖任何云端基础设施。

## 独特价值

- **macOS 上真实的 CPU / 电池温度** —— 通过 IOKit 读取系统管理控制器（SMC）与 AppleSmartBattery 注册表节点，聚合多路传感器（Apple 芯片 `Tp*/Te*/Th*` 与 Intel `TC*` 键）。
- **带图表的告警邮件** —— 每封告警邮件内嵌 PNG + 交互式 SVG 趋势图，收件人无需下载附件即可看到完整趋势。
- **电池友好提醒** —— 充电到 80% 提醒拔电、电量低于 20% 提醒充电，保护电池长期健康。
- **完全离线** —— 除 SMTP 发送外完全离线运行，无埋点、无云服务、无需注册账号。

## 技术架构

```
┌─────────────────────────────────────────────────────────────┐
│                        SwiftUI（视图层）                     │
│   DashboardView · SettingsView · DualLineChart/TripleChart  │
└───────────────────────────┬─────────────────────────────────┘
                            │ @ObservedObject / @EnvironmentObject
┌───────────────────────────▼─────────────────────────────────┐
│                    MonitorService（视图模型）                 │
│   • 30s 采样定时器        • 告警评估 + 冷却时间               │
│   • 5s 电量快速轮询       • Swift Charts + JSON 存储          │
└──────┬──────────────────────────────┬────────────────────────┘
       │ SystemInfo.current()         │ store.insert(sample)
┌──────▼──────────┐          ┌────────▼──────────┐
│ SystemInfo      │          │ SampleStore       │
│ （读数聚合器）   │          │ • Codable 结构体  │
└──────┬──────────┘          │ • JSON 文件持久化 │
       │                      └────────┬──────────┘
┌──────▼──────────────────────────────▼──────────┐
│                 平台能力层                     │
│   SMCReader (macOS)  BatteryReader  Keychain  │
└──────┬─────────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────────┐
│               EmailService / SMTPClient          │
│   MIME 拼装 + 内联 SVG/PNG 图表 → SMTP 发送      │
└──────────────────────────────────────────────────┘
```

**关键技术选型**

| 关注点 | 方案 | 原因 |
|--------|------|------|
| 数据模型 | `Codable` 结构体 + JSON 文件 | SwiftData 仅支持 iOS 17+/macOS 14+；需满足 iOS 15 / macOS 12 的最低版本 |
| 状态管理 | Combine `ObservableObject` + `@Published` | `@Observable` 宏需 iOS 17+；Combine 在 iOS 13+ 可用 |
| 应用内图表 | Swift Charts | 声明式、可交互；用 `@available(iOS 16/macOS 13)` 守卫并提供文字回退 |
| 邮件图表 | CoreGraphics 生成 PNG + 手写 SVG | Gmail 会剥离 SVG，所以每封邮件同时携带确定性 PNG |
| 网络 | Network.framework（`NWConnection`） | 同一套代码双端可用；465 端口隐式 TLS |
| 凭据安全 | 钥匙串（Keychain） | SMTP 密码不落 UserDefaults，也不以明文落盘 |
| 导航 | `NavigationStack` + `NavigationView` 回退 | 覆盖 iOS 15 / macOS 12（该版本无 stack API） |

## 项目结构

```
IntelGuardian/
├── IntelGuardian/
│   ├── IntelGuardianApp.swift      # 应用入口，注入 settings 与 monitor
│   ├── Models/
│   │   ├── SystemInfo.swift        # 聚合当前读数（Sendable）
│   │   └── ThermalSample.swift     # Codable 采样 + SampleStore（JSON 持久化）
│   ├── Services/
│   │   ├── AppSettings.swift       # ObservableObject，didSet 自动持久化
│   │   ├── BatteryReader.swift     # 电量 / 温度 / 充电状态（iOS+macOS）
│   │   ├── SMCReader.swift         # macOS SMC 温度读取（IOKit）
│   │   ├── EmailService.swift      # MIME 拼装 + SVG/PNG 图表
│   │   ├── EmailChartRenderer.swift# CoreGraphics PNG 渲染器
│   │   ├── KeychainStore.swift     # SMTP 密码钥匙串封装
│   │   └── SMTPClient.swift        # 基于 Network.framework 的轻量 SMTP 客户端
│   ├── ViewModels/
│   │   └── MonitorService.swift    # 采样定时器、告警、电量轮询
│   └── Views/
│       ├── ContentView.swift       # Tab 容器（现代/传统导航）
│       ├── DashboardView.swift     # 指标网格 + 趋势图
│       ├── SettingsView.swift      # SMTP 与阈值配置
│       └── InteractiveLineChart.swift  # DualLineChart / TripleLineChart
├── IntelGuardianTests/             # 单元测试
├── IntelGuardianUITests/           # UI 测试
├── doc/sh/build_and_run.sh         # 三端一键构建运行脚本
└── COMPATIBILITY_REPORT.md         # iOS 15 / macOS 12 兼容性审计报告
```

## 如何运行

### 环境要求

- **macOS 12+**（构建机）
- **Xcode 15+**（推荐 Xcode 26）
- 一个 **免费或付费的 Apple Developer 团队**（真机安装需签名）

### 三端一键构建脚本

最快的方式：把最新代码同时构建并运行到**三个目标**：

```bash
./doc/sh/build_and_run.sh          # Debug，三个目标全部构建运行
./doc/sh/build_and_run.sh --release
```

脚本行为：

| 目标 | 构建目录 | 启动方式 |
|------|---------|---------|
| macOS | `.build/macos` | `open` 打开 App |
| iOS 模拟器 | `.build/ios-simulator` | `simctl install` + `launch` |
| iOS 真机 | `.build/ios-device` | `devicectl install` + `launch`（支持无线） |

> **真机签名提示**：首次安装若报 `Security / RequestDenied`，请在设备上信任开发者证书：
> **设置 → 通用 → VPN 与设备管理**，或先用 Xcode 运行一次。

### Xcode 手动构建

1. 打开 `IntelGuardian.xcodeproj`。
2. 选择 `IntelGuardian` scheme。
3. 选择运行目标（我的 Mac / iPhone 模拟器 / 你的真机）。
4. 按 **⌘R** 运行。

## 邮件告警配置

1. 打开 **设置** 页签。
2. 填写 SMTP 信息（服务器、端口 465、账号、授权码、收件邮箱）。
3. 点击 **发送测试邮件** 验证配置。
4. 调整告警阈值（温度 / 热状态 / 80% / 20%）。

支持 Gmail、QQ 邮箱、163、Outlook 等任何支持 465 端口隐式 TLS 的 SMTP 服务。

## 平台功能对比

| 功能 | macOS | iOS |
|------|-------|-----|
| CPU 温度 | ✅（SMC） | —（无公开 API） |
| 电池温度 | ✅（IORegistry/SMC） | —（无公开 API） |
| 电量 | ✅ | ✅ |
| 充电状态 | ✅ | ✅ |
| 热状态 | — | ✅（`ProcessInfo`） |
| 趋势图 | 合并：CPU 温度 + 电池温度 + 电量 | 合并：热状态 + 电量 |
| 邮件告警 | ✅ | ✅ |

## 兼容性说明

最低部署版本为 **iOS 15.0** 与 **macOS 12.0**。代码刻意避免强依赖 SwiftData / `@Observable` / `NavigationStack`，在旧系统上会优雅降级（文字图表摘要、`NavigationView`）。完整审计见 [COMPATIBILITY_REPORT.md](COMPATIBILITY_REPORT.md)。

---

基于 SwiftUI、Swift Charts、Combine 与 Network.framework 构建。
