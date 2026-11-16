# 上海温度

原生 macOS 应用，固定上海市、摄氏度、Asia/Shanghai 时区。包含 7 天、15 天、30 天三个标准中号桌面小组件；高温为珊瑚橙线，低温为冰蓝线，透明背景，无地区、单位或样式配置。

## GitHub 在线构建

本工程不要求使用者本机安装 Xcode。GitHub Actions 的 `macos-26` 运行器负责：

1. 检查工程文件引用和扩展嵌入关系。
2. 执行 Swift 数据解码、集合平均、缓存、跨天、失败回退和请求合并测试。
3. 用完整 Xcode 编译 arm64 + x86_64 应用及 WidgetKit 扩展。
4. 先对扩展、再对应用进行 ad-hoc 签名，并检查签名、双架构与扩展信息。
5. 生成 ZIP、DMG、SHA256 校验文件，作为 Actions 构建产物保存。
6. 版本标签（例如 `v0.2.0`）构建成功后发布预览版 GitHub Release。

初次上传运行：

```bash
bash scripts/publish-github.sh --public --release
```

这个命令会在当前登录的 GitHub 账户下创建 **公开仓库 `ShanghaiTemperature`**，上传此目录的源码，并推送 `v0.2.0` 标签。若未登录，会进入 GitHub 官方登录流程。脚本会使用 GitHub noreply 邮箱提交；不包含私人证书、API Key、个人文件或其他项目源码。已存在的同名仓库不会被覆盖。GitHub CLI 需提前安装（本机已检测到 `gh`）。

日常推送 main 运行构建并保留产物；发布新版本则推送新的 `vX.Y.Z` 标签。Release 默认为预览版，不宣称完成了实机验收。不要重复覆盖旧标签。

公开仓库使用 GitHub 标准托管运行器，不需要自行填写 Apple 密钥或搬用 Sticky 的 secrets。正式 Developer ID 签名和 Apple 公证可后续单独配置；当前预览版未公证，macOS 可能提示运行限制。不得以“签名检查通过”冒充 Gatekeeper、公证或桌面组件注册通过。

## 已实现的运行逻辑

- 7 天、15 天共用一次 15 天常规预报请求；同一组件进程内并发请求合并。
- 30 天使用 ECMWF EC46 51 成员，逐日最高温、最低温分别取集合平均，注明“长期趋势，仅供参考”。
- 正常数据缓存 3 小时；上海午夜会请求刷新。失败后 30 分钟重试，不密集轮询。
- 缓存原子写入本地 Application Support。应用和扩展分别使用自己的沙箱缓存；三个组件共享扩展缓存。无需 App Group 权限。
- 缓存最多保留为可用数据 48 小时。跨天剔除已过日期；缺少未来日期时显示剩余天数，不补造温度。
- 无有效缓存时显示“暂无有效预报”；样例仅用于组件库预览和占位，真实运行失败不会退回样例。
- 后续时间线预先安排了整点、缓存过期和跨日状态，避免系统延迟网络刷新时仍把过期数据当新数据。
- 请求超时、HTTP 错误、空值、摄氏度单位、时区、日期连续性、成员完整性、高低温大小关系均有检查。

WidgetKit 最终决定实际刷新时机，3 小时是请求策略，不保证定时精确唤醒。应用无需常驻；主窗口只有添加说明、数据源获取状态和来源链接。

## 数据源

- 固定坐标：31.2304, 121.4737。
- 常规接口：https://api.open-meteo.com/v1/forecast
- 延伸期接口：https://seasonal-api.open-meteo.com/v1/seasonal
- 参数：`temperature_unit=celsius`、`timezone=Asia/Shanghai`，延伸期使用 `models=ecmwf_ec46`。
- 来源：https://open-meteo.com/ ，数据许可 CC BY 4.0。
- 个人非商业用途适用 Open-Meteo 免费接口要求；商业发布前需重新核对服务授权。EC46 未做当地偏差订正，不应理解成与短期预报同等精度。

接口已在 2026-11-16 返回上海完整 15 天和 30 天数据，温度单位、日期与 51 成员数据完整性已核对。接口可用性不代表应用已经完成编译和桌面验收。

## 验证状态

| 项目 | 状态 |
|---|---|
| 工程引用、targets、扩展嵌入、plist、沙箱网络权限 | 本地检查通过 |
| Shell 脚本语法与工程生成可重复性 | 本地检查通过 |
| Swift 单元测试 | 已编写，等待 GitHub macOS 执行 |
| 原生应用、扩展编译 | 等待 GitHub macOS 执行 |
| 安装后显示、透明效果、休眠恢复、组件注册 | 等待下载产物后在本机验证 |
| Developer ID 签名、Apple 公证 | 未配置；初版采用 ad-hoc 签名 |

本机尚无完整 Xcode；当前自动化环境的命令行也未能连接 GitHub API，所以不能宣称已推送、构建或发布成功。在线结果应以 Actions 任务及 Release 下载文件为准。

## 本地开发（可选）

有 Xcode 的机器可打开 `ShanghaiTemperature.xcodeproj`，选择 `ShanghaiTemperature` 方案及 `My Mac`。无外部 Swift 包依赖。数据核心可用 `swift test` 单独验证。

```bash
python3 scripts/validate_project.py
swift test
bash scripts/build-release.sh
```

## 工程结构

- `App/`：极简主窗口。
- `Shared/WeatherModel.swift`：上海日期、固定周期、快照状态、组件库样例。
- `Shared/WeatherService.swift`：固定接口、51 成员解码、请求合并、缓存与刷新策略。
- `Shared/TemperatureChartView.swift`：共用高低温曲线与无数据状态。
- `Widgets/`：三个无可编辑参数的 StaticConfiguration，仅支持 systemMedium。
- `Tests/`：由 Swift Package 驱动的真实 Swift 测试。
- `.github/workflows/build.yml`：在线测试、构建、产物保存与预览发布。
- `scripts/`：工程生成、结构检查、构建打包、公开仓库上传脚本。
