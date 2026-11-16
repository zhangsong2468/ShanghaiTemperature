#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! developer_dir=$(xcode-select -p 2>/dev/null); then
  echo '无法编译：尚未配置 Xcode 开发目录。请先安装并完成完整 Xcode 的首次启动。' >&2
  exit 2
fi
if [[ "$developer_dir" != *.app/Contents/Developer ]]; then
  echo '无法编译：需要完整 Xcode，当前仅有独立开发工具。' >&2
  exit 2
fi
xcodebuild -project ShanghaiTemperature.xcodeproj \
  -scheme ShanghaiTemperature -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO build
