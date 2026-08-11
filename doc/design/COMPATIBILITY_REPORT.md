# IntelGuardian 兼容性分析报告

> 生成日期：2026-08-10
> 目标最低版本：iOS 15.0 · macOS 12.0
> 原始配置：iOS 26.1 · macOS 26.1（Xcode 26.1 默认）

---

## 一、部署目标变更

已在 `project.pbxproj` 中将三个 target（IntelGuardian、IntelGuardianTests、IntelGuardianUITests）的 Debug/Release 配置全部更新：

| 配置项 | 原值 | 新值 |
|--------|------|------|
| `IPHONEOS_DEPLOYMENT_TARGET` | 26.1 | **15.0** |
| `MACOSX_DEPLOYMENT_TARGET` | 26.1 | **12.0** |

---

## 二、不兼容项详细清单

### ⚠️ 严重（会导致编译失败）

| # | 文件 | API | 问题 | 最低要求 | 修复方案 |
|---|------|-----|------|----------|----------|
| 1 | `IntelGuardianApp.swift` | `@Model` / `ModelContainer` / `ModelConfiguration` / `SwiftData` | SwiftData 框架仅支持 iOS 17+ / macOS 14+ | iOS 17, macOS 14 | **移除 SwiftData 全部依赖**，改用 JSON 文件持久化 + `Codable` struct |
| 2 | `ThermalSample.swift` | `@Model` macro | `@Model` 是 SwiftData 宏，iOS 17+ | iOS 17, macOS 14 | 改为 `Codable` struct + `SampleStore`(JSON 文件存储) |
| 3 | `AppSettings.swift` | `@Observable` macro | `@Observable` 宏基于 Observation 框架，iOS 17+ | iOS 17, macOS 14 | 改为 `ObservableObject` + `@Published`（iOS 13+ 可用） |
| 4 | `AppSettings.swift` | `@Bindable` | `@Bindable` 是 SwiftUI 绑定的 Observation 封装，iOS 17+ | iOS 17, macOS 14 | 改用 `ObservedObject` + 手动 `Binding` wrapper |
| 5 | `MonitorService.swift` | `@Observable` | 同上 | iOS 17, macOS 14 | 改为 `ObservableObject` + `@Published` |
| 6 | `MonitorService.swift` | `SwiftData` import / `ModelContext` / `#Predicate` / `FetchDescriptor` | SwiftData 查询语法仅 iOS 17+ | iOS 17, macOS 14 | 用 `SampleStore` 的 `recentSamples()` 方法替代，纯内存+JSON 操作 |

### ⚠️ 中等（会导致部分设备功能缺失）

| # | 文件 | API | 问题 | 最低要求 | 修复方案 |
|---|------|-----|------|----------|----------|
| 7 | `ContentView.swift` | `NavigationStack` | iOS 16+ / macOS 13+ | iOS 16, macOS 13 | **`@available` 拆分为两个实现**，iOS 15/macOS 12 使用 `NavigationView` 回退。注意：`.navigationViewStyle(.stack)` 在新 SDK (Xcode 26) 中已被移除，故不在 `legacyTabs` 上使用；iPhone 上 `NavigationView` 默认即 stack 行为，iPad/macOS 由 `modernTabs` 覆盖 |
| 8 | `DashboardView.swift` | `import Charts` / `Chart` / `LineMark` / `AreaMark` / `RuleMark` / `PointMark` | Swift Charts 框架 iOS 16+ / macOS 13+ | iOS 16, macOS 13 | **`@available` 保卫**，低版本显示纯文本摘要 + 提示信息 |
| 9 | `InteractiveLineChart.swift` | `import Charts` / Chart DSL | Swift Charts 框架 iOS 16+ / macOS 13+ | iOS 16, macOS 13 | 文件级别添加 `@available(iOS 16.0, macOS 13.0, *)`，调用方用 `#available` 保卫 |
| 10 | `SettingsView.swift` | `LabeledContent` | SwiftUI LabeledContent iOS 16+ / macOS 13+ | iOS 16, macOS 13 | 用 `#available` 降级为 `HStack` |
| 11 | `SettingsView.swift` | `.onChange(of:)` 两参数闭包 `{ _, newValue in ... }` | 两参数版本 iOS 17+（单参数版 iOS 14+） | iOS 17 | 已移除（设置改为直接调用 `settings.sync()`，不再依赖 `onChange` 触发持久化） |
| 11b | `IntelGuardianApp.swift` | `.defaultSize(_:)` | macOS 13.0+ | macOS 13 | 已移除；改用 `.frame(minWidth:idealWidth:minHeight:idealHeight:)`（macOS 10.15+）设置黄金比例 680×420 |
| 11c | `IntelGuardianApp.swift` | `.windowResizability(_:)` | macOS 13.0+ 且仅适用于 macOS | macOS 13 | 已移除；黄金比例通过 `.frame` 实现 |

### ✅ 低风险（已通过编译条件兼容）

| # | 文件 | API | 说明 |
|---|------|-----|------|
| 12 | `SystemInfo.swift` | `ProcessInfo.processInfo.thermalState` | 已用 `#if os(iOS)` 隔离，macOS 上返回 nil |
| 13 | `BatteryReader.swift` | `UIDevice` / `IOKit` | 已用 `#if os(iOS)` / `#if os(macOS)` 隔离 |
| 14 | `SMCReader.swift` | `IOServiceGetMatchingService` / IOKit | 已用 `#if os(macOS)` 包围，iOS 上不编译 |
| 15 | `EmailChartRenderer.swift` | `NSImage` / `UIGraphicsImageRenderer` | 已用 `#if os(macOS)` / `#else` 分别处理 |
| 16 | `EmailService.swift` | `Device.current` / `sysctlbyname` | 已用平台条件隔离 |
| 17 | `SMTPClient.swift` | `Network.framework` / `NWConnection` | iOS 12+ / macOS 10.14+ 均可用 ✅ |
| 18 | `KeychainStore.swift` | `Security.framework` / `SecItemCopyMatching` | iOS 2.0+ / macOS 10.0+ 均可用 ✅ |
| 19 | `SettingsView.swift` | `.foregroundStyle()` | iOS 15+ / macOS 12+ ✅ |
| 20 | `SettingsView.swift` | `.tint()` on Toggle | iOS 15+ / macOS 12+ ✅ |

---

## 三、已知剩余限制

以下 API 在最低版本中**可用**，无需变更，但已添加防御性说明：

| API | 可用版本 | 使用位置 |
|-----|---------|---------|
| `Task { }` / async/await | iOS 15+ / macOS 12+ ✅ | 全局 |
| `Task.detached { }` | iOS 15+ / macOS 12+ ✅ | `EmailService` |
| `AsyncSequence` | iOS 15+ / macOS 12+ ✅ | 全局 |
| `@MainActor` | iOS 15+ / macOS 12+ ✅ | 全局 |
| `NWConnection` (Network.framework) | iOS 12+ / macOS 10.14+ ✅ | `SMTPClient` |
| `async/await + NWConnection` | iOS 15+ / macOS 12+ ✅ | `SMTPClient` |
| `.task { }` modifier | iOS 15+ / macOS 12+ ✅ | `ContentView` |
| `.monospacedDigit()` | iOS 15+ / macOS 12+ ✅ | `DashboardView` |
| `ProgressView` | iOS 14+ / macOS 11+ ✅ | `SettingsView` |
| `@StateObject` / `@EnvironmentObject` | iOS 14+ / macOS 11+ ✅ | 全局 |
| `LazyVGrid` | iOS 14+ / macOS 11+ ✅ | `DashboardView` |
| `.textInputAutocapitalization(.never)` | iOS 15+ / macOS 12+ ✅ | `SettingsView` |
| `.keyboardType()` | iOS 15+ / macOS 12+ ✅ | `SettingsView` |
| `.searchable()` | iOS 15+ / macOS 12+ ✅ | 未使用 |
| `@Published` in `ObservableObject` | iOS 13+ / macOS 10.15+ ✅ | `AppSettings`, `MonitorService` |
| `Codable` + `JSONEncoder`/`JSONDecoder` | iOS 8+ ✅ | `ThermalSample`, `SampleStore` |
| `FileManager` + document directory | iOS 2.0+ ✅ | `SampleStore` |
| `UserDefaults` | iOS 2.0+ ✅ | `AppSettings` |
| Keychain (`Security.framework`) | iOS 2.0+ ✅ | `KeychainStore` |
| `Combine` (`AnyCancellable`, `.sink`) | iOS 13+ / macOS 10.15+ ✅ | `MonitorService` |

---

## 四、架构变更总结

```
Before (iOS 17+ / macOS 14+):            After (iOS 15+ / macOS 12+):
┌──────────────────────────┐             ┌──────────────────────────┐
│  SwiftData @Model        │             │  Codable struct + JSON   │
│  (ThermalSample)         │             │  file (SampleStore)      │
├──────────────────────────┤             ├──────────────────────────┤
│  Observation @Observable │             │  Combine ObservableObject │
│  @Bindable               │             │  @Published + @StateObj   │
├──────────────────────────┤             ├──────────────────────────┤
│  NavigationStack         │             │  @available: NavStack /   │
│                          │             │  NavigationView fallback  │
├──────────────────────────┤             ├──────────────────────────┤
│  Swift Charts (强制)     │             │  @available: Charts /     │
│                          │             │  text fallback            │
└──────────────────────────┘             └──────────────────────────┘
```

### 关键改进

1. **数据持久化**：从 SwiftData 改为 `SampleStore`（JSON 文件）。启动时加载，每次插入自动保存 + 清理超过 7 天的数据。
2. **状态管理**：从 `@Observable` / `@Bindable` 改为经典的 `ObservableObject` + `@Published` + `@StateObject` / `@ObservedObject` / `@EnvironmentObject`。
3. **导航**：通过 `@available` 在 iOS 16+/macOS 13+ 使用 `NavigationStack`，低版本回退到 `NavigationView`。
4. **图表**：通过 `@available` 在支持 Swift Charts 的系统上使用交互式图表，低版本显示文本摘要 + 升级提示。
5. **设置持久化**：AppSettings 提供 `sync()` 方法，在所有 setter 调用后手动同步到 UserDefaults，不再依赖 `onChange` 自动触发。

---

## 五、验证要点

- [ ] **iOS 15 模拟器**：确认 `NavigationView` 回退正常，设置页面无 `LabeledContent` 崩溃，图表区域显示文本摘要
- [ ] **iOS 16+ 模拟器**：确认 `NavigationStack` + Swift Charts 正常展示交互图
- [ ] **macOS 12**：确认 `NavigationView` 回退正常，Charts 文本回退正常，SMC 读数正常
- [ ] **macOS 13+**：确认 Charts 交互图正常
- [ ] **数据持久化**：重启 app 后，历史采样数据应从 `IntelGuardianSamples.json` 正确恢复
- [ ] **SMTP 发送**：在双端确认邮件发送功能正常（包括图表 PNG 渲染）
- [ ] **Timers**：确认 30 秒采样定时器在前后台切换后行为正常

---

> 所有修改均已完成。项目现在可以在 **iOS 15.0+** 和 **macOS 12.0+** 上编译运行，并在较高版本系统上自动启用更优的 UI（NavigationStack、Swift Charts 交互图）。

---

## 六、构建脚本说明

`./doc/sh/build_and_run.sh` 可一键完成三路编译运行：

| 目标 | 构建路径 | 安装/启动方式 |
|------|---------|-------------|
| macOS | `.build/macos` | `open` 原生启动 |
| iOS Simulator | `.build/ios-simulator` | `simctl install` + `simctl launch` |
| iOS 真机 | `.build/ios-device` | `devicectl device install app` + `devicectl device process launch`（无线） |

每个目标使用独立的 DerivedData 目录，避免交叉编译冲突。

**真机签名问题**：`devicectl launch` 失败报 `Security / RequestDenied` 是因为开发者证书未在设备上被信任。解决方法：
1. 在 iPhone 上进入 **设置 → 通用 → VPN 与设备管理**，信任你的开发者证书
2. 或者首次通过 Xcode 直接运行一次（Xcode 会自动处理证书信任）
