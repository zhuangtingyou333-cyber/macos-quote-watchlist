# macOS Quote Watchlist · 行情浮窗

Swift/AppKit 原生 macOS 行情工具的个人项目源码展示，使用 Codex 辅助开发。
公开行情通过 OKX WebSocket 与 REST 获取，程序不需要交易账户 API 密钥，也不下单。

## 能展示的工程内容

- 自选品种解析、编辑、排序与本地设置持久化。
- WebSocket 更新、断线恢复与 REST 回退。
- 过期行情标记和数据代次控制，避免旧响应覆盖新数据。
- AppKit 浮动窗口、菜单与自选列表编辑器。

**数据口径：** `MU-USDT-SWAP`、`INTC-USDT-SWAP` 等是 OKX 的永续合约标识，
不是证券交易所股票现货报价；`BTC-USDT` 等为对应现货交易对。可用性与新鲜度以
上游实际响应为准，工具会显示缺失/过期状态。

## 构建

需要 macOS 和 Swift 编译器 / Xcode Command Line Tools：

```sh
swiftc -typecheck -parse-as-library -swift-version 5 -framework Cocoa \
  Main.swift InstrumentSelection.swift WatchlistSettingsController.swift
./build.sh
open '.build/MU 行情.app'
```

构建脚本只生成本仓库的 `.build` 目录，不安装到系统应用目录。
首次启动后可在设置中调整自选品种；UserDefaults 保存在使用者自己的电脑上。
网络功能依赖 OKX 的公开服务，本仓库没有附带个人持仓、账户或本机配置。

## 源码导航

| 文件 | 内容 |
|---|---|
| `Main.swift` | AppKit 界面、行情与连接生命周期 |
| `InstrumentSelection.swift` | 品种输入与选择校验 |
| `WatchlistSettingsController.swift` | 原生自选列表设置 |

验证边界见 [VALIDATION.md](VALIDATION.md)，权利说明见 [NOTICE.md](NOTICE.md)。
