#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
case "$mode" in
  run|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${MAC_POWER_BUILD_CONFIGURATION:-debug}"
app_bundle="$project_root/Mac Power Monitor.app"
app_binary="$app_bundle/Contents/MacOS/MacPowerMonitor"
cd "$project_root"

# 只重启这一个项目中的应用，继续使用已有 app 包与图标。
while IFS= read -r pid; do
  process_command="$(ps -p "$pid" -o command= || true)"
  case "$process_command" in
    "$app_binary"|"$app_binary "*) kill "$pid" ;;
  esac
done < <(pgrep -x MacPowerMonitor || true)

swift build -c "$configuration" --product MacPowerMonitor
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
cp "$binary_dir/MacPowerMonitor" "$app_binary.new"
mv "$app_binary.new" "$app_binary"
codesign --force --deep --sign - "$app_bundle"

if [[ "$mode" == --debug ]]; then
  exec lldb -- "$app_binary"
fi
/usr/bin/open -n "$app_bundle"
case "$mode" in
  --verify) sleep 1; pgrep -x MacPowerMonitor ;;
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "MacPowerMonitor"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.tongbo.mac-power-monitor"' ;;
esac
