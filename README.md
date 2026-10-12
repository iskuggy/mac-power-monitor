# Mac Power Monitor

macOS 电源充电监测工具（SwiftUI 原生，Apple Silicon）。直接读取 IOKit 注册表（AppleSmartBattery），实时采样不启动外部命令。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6-orange)

## 功能

- 实时电源输入功率环（量程按适配器上限自适应）
- 功率趋势图：电源输入 + 电池充放电双曲线，5分钟/30分钟/2小时窗口，悬停查看数值
- USB-C PD 档位列表，高亮当前协商档位
- 电池健康：健康度（标称容量/设计容量）+ 循环次数
- 充电异常诊断：接电未充电（含 NotChargingReason 原因码）、充电限速、温度限充、低入电等
- 系统通知：开始充电、充满、低电量、接电未充电
- 菜单栏常驻：实时瓦数/电量，关窗口不退出

## 构建

```bash
swift build -c release
cp .build/release/MacPowerMonitor "Mac Power Monitor.app/Contents/MacOS/MacPowerMonitor"
codesign --force --deep --sign - "Mac Power Monitor.app"
open "Mac Power Monitor.app"
```

app 包骨架（Info.plist、图标）在仓库内，构建后把二进制复制进去即可运行。

也可用 `./script/build_and_run.sh --verify` 构建并重启已有的 app；默认 Debug，
日常使用的 Release 版本运行 `MAC_POWER_BUILD_CONFIGURATION=release ./script/build_and_run.sh --verify`。

## 刷新与后台行为

- 周期采样间隔保持两秒，插拔事件仍立即采样；历史记录和通知在后台持续工作。菜单栏显示整数功率，显示值变化才更新标签。
- 主窗口只在应用处于前台且窗口可见时刷新；切换应用、隐藏、最小化或关闭窗口后暂停主界面发布。
- 回到前台立即同步最近的采样和后台积累的历史。实时功率、指标、PD 档位和诊断分别观察各自的数据。
- 横向/纵向布局由窗口宽度直接选择，避免对同一内容反复试算多套布局。

## 数据来源

- **实时功率**：SMC 浮点键 `PDTR`（DC 输入）/ `PSTR`（系统总功耗），亚秒级刷新；电池充放 = 输入 − 负载 恒等推导
- **慢数据**：`IORegistryEntryCreateCFProperties(AppleSmartBattery)` —— 电量、健康度/循环次数、`AdapterDetails`（含 UsbHvcMenu PD 档位）、NotChargingReason 等原因码
- **事件**：`IOPSNotificationCreateRunLoopSource` 订阅插拔/电量变化，事件到达立即刷新
