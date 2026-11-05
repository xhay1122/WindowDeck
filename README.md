# WindowDeck

替代 macOS 三指上滑（调度中心）/ 三指下滑（App Exposé）的菜单栏应用。

- **三指上滑 → 牌堆**：按应用把窗口叠成一摞，后层卡片露出"标题 + 一截窗口内容"，悬停展开。
- **三指下滑 → 当前应用窗口**：平铺当前应用的窗口，已收起的窗口放在底部条带，⇥ 切换应用。
- 卡片上有红绿灯：关闭 / 收起（恢复）/ 全屏或缩放。
- 标题字号、字重、行数、截断方式可调；自动去掉标题末尾的应用名，并弱化同一应用窗口标题的相同部分。
- 可关闭缩略图，使用"仅标题"模式（不需要屏幕录制权限）。
- 可配置全局快捷键（默认不配置）。
- 支持简体中文 / English（默认跟随系统，可在 设置 → 通用 → 语言 中切换，重启后生效）；支持浅色 / 深色主题（设置 → 外观 → 主题，默认跟随系统，同时作用于设置窗口和覆盖层）。

设计细节见 [docs/technical-design.md](docs/technical-design.md)。

## 环境

- macOS 14+（开发环境 macOS 27.0.1）
- Swift 6（CommandLineTools 即可，不需要完整 Xcode）

## 构建与运行

```sh
./scripts/build-app.sh          # 生成 build/WindowDeck.app（默认 release、"WindowDeck Signing" 证书签名）
open build/WindowDeck.app
```

- `CONFIG=debug ./scripts/build-app.sh` 构建 debug 版本。
- 默认使用钥匙串中的自签名代码签名证书 `WindowDeck Signing`（私钥只在钥匙串中；`certs/` 下的 `.cer` 仅为本地备份，已被 git 忽略）。固定证书签名可避免每次构建后重新授权辅助功能 / 屏幕录制。
- `SIGN_IDENTITY="<证书名>" ./scripts/build-app.sh` 指定其他证书；`SIGN_IDENTITY=- ./scripts/build-app.sh` 使用 ad-hoc 签名（每次构建签名都会变，需要重新授权）。

## 首次使用

1. **辅助功能**（必需）：系统设置 → 隐私与安全性 → 辅助功能，打开 WindowDeck。
2. **屏幕录制**（显示缩略图时需要）：授权后需要重新启动 WindowDeck。
3. **关闭系统手势**：系统设置 → 触控板 → 更多手势，关闭"调度中心"和"App Exposé"（或改为四指）。WindowDeck 只检测并提示，不会修改系统设置。关闭后仍可用 ⌃↑ / ⌃↓ 打开系统自带的调度中心。

## 操作

| 输入 | 作用 |
|---|---|
| 三指上滑 / 下滑 | 打开牌堆 / 当前应用窗口；反向滑动收起 |
| 单击卡片、Return | 聚焦窗口 |
| 方向键 | 移动选中 |
| ⌘W / ⌘M | 关闭 / 收起选中的窗口 |
| ⇥ / ⇧⇥ | （当前应用视图）切换应用 |
| Esc、点击空白 | 收起 |

## 测试与调试

```sh
./scripts/test-core.sh                                  # WindowDeckCore 单元测试
swift build --build-system native                      # 编译 App（debug）
.build/debug/WindowDeck --self-test                     # 打印私有能力、权限、窗口目录统计
.build/debug/WindowDeck --render-preview /tmp/preview   # 用合成数据离屏渲染覆盖层到 PNG
```

本地化：源码中的文案即简体中文（作为 key），英文翻译在 `Support/Resources/en.lproj/Localizable.strings`，构建脚本会把 `Support/Resources/` 复制进 App。新增或修改界面文案时需同步更新英文翻译；直接运行 `.build/debug/WindowDeck`（不在 .app 中）时始终显示中文。`--render-preview` 会同时输出深色与浅色（`-light` 后缀）两套预览。

> 使用 CommandLineTools 工具链时，SwiftPM 默认的新构建后端无法初始化，所以命令里都带 `--build-system native`。

设置 → 权限与诊断 页面可以查看权限、私有能力、触控板实时数据（手指数 / 原始坐标）和手势冲突状态，也可以导出诊断信息（不包含窗口标题）。

## 已知限制

- 依赖私有 API（MultitouchSupport、SkyLight、远程 AX 令牌），系统升级后可能失效；失效时自动降级（手势不可用时请改用快捷键）。
- 不能上架 Mac App Store。
- 已最小化的窗口无法截取实时画面，使用最小化前的缓存或应用图标。
