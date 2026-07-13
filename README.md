# Mac Power Monitor

macOS 电源充电监测工具（SwiftUI 原生，Apple Silicon）。直接读取 IOKit 注册表（AppleSmartBattery），零子进程、零轮询开销。

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
open "Mac Power Monitor.app"
```

app 包骨架（Info.plist、图标）在仓库内，构建后把二进制复制进去即可运行。

## 数据来源

全部来自 `IORegistryEntryCreateCFProperties(AppleSmartBattery)`：`PowerTelemetryData`（SystemPowerIn/SystemLoad）、`AdapterDetails`（含 UsbHvcMenu PD 档位）、电池电压/电流/温度/循环次数等。
