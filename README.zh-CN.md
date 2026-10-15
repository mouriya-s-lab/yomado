<img src="docs/images/yomado-logo.png?v=night-window-20261013" alt="yomado 夜窗图标" width="64" align="right" />

# yomado · 夜窗

为视觉 Agent 留一块工作屏，让实体屏可以休息。

[官方网站](https://yomado.app/) · [English](README.md) · [MIT 许可证](LICENSE)

## 60 秒看懂 yomado

给 Codex 一块虚拟屏，通过视觉操作 Blender、Marvelous Designer 等桌面软件，无需应用专用的 MCP 接口。

[![点击观看中文演示：Blender 和 Marvelous Designer 位于 Codex 虚拟屏，两块实体屏保留自己的应用。](docs/media/yomado-zh-cn-poster.jpg)](https://chekusu.github.io/yomado/?lang=zh-CN)

**[▶ 观看字幕版 · 支持 16 种语言](https://chekusu.github.io/yomado/?lang=zh-CN)** · [中文字幕 MP4](https://yomado.app/media/captioned/yomado-film-zh-CN-wide-c1.mp4) · [English captioned MP4](https://yomado.app/media/captioned/yomado-film-en-wide-c1.mp4) · [在官网观看](https://yomado.app/zh-cn/watch/)

*60 秒产品功能模拟演示，支持 16 种字幕及横竖版带字幕下载。简繁字幕配 River 中文旁白，其余字幕配 River 英文旁白。*

## 为什么需要 yomado

yomado 主要是为了支持 **Codex 或其他 Agent 通过视觉操作电脑**：看截图、理解界面，再用鼠标和键盘直接操作桌面软件，不必依赖应用专用的 MCP 接口。Marvelous Designer、Blender 等软件就有这样的使用场景，尤其是缺少合适 MCP 接口，或需要直接操作三维视图、菜单、对话框的工作流程。

这类操作仍然需要图形桌面，以及供应用绘制界面、供 Agent 截图观察的显示表面。yomado 用纯软件为 Agent 所需窗口提供虚拟屏，目标是在 Mac 持续运行、实体显示器关闭之后，仍然保留可供 Agent 观察和操作的界面。截图、判断和键鼠输入由现有 Agent 工具完成，yomado 负责提供显示桌面，无需硬件显示器欺骗器或付费显示器软件。

## 把准备工作也交给 Agent

你不需要专门替 Agent 手动创建虚拟屏、安排应用。仓库附带的 [yomado skill](skills/yomado/SKILL.md)，指导具备电脑操作能力的 Agent 自行建屏、命名、移入本次任务的窗口、验证截图与操作，并在完成后把窗口恢复。

> 用 $yomado 为这次 Blender 任务准备一块叫「Codex · Blender」的虚拟屏。只移入本任务的窗口，确认你能看到并操作它们，完成后恢复原位置。

在 Codex 中，将仓库的 `skills/yomado` 文件夹安装到 `$CODEX_HOME/skills`（默认为 `~/.codex/skills`），下一轮对话即可使用；其他 Agent 可以通过自己的 skill 机制读取同一份 `SKILL.md`。需要先安装 yomado，并为 Agent 配备电脑操作工具；首次 macOS 系统授权由你完成。skill 用 [`screen` 命令](#命令行控制虚拟屏)启动、命名和关闭虚拟屏，通过应用界面移动窗口，仍与当前桌面共用焦点和输入。

![yomado 使用示意：两台熄屏的实体显示器、保持运行的 Mac，以及右侧显示三维和服装设计窗口的虚拟桌面。](docs/images/yomado-usage-night-window.png)

*AI 生成的使用示意：Agent 工作窗口位于虚拟屏；实体屏关闭后的实际操作仍待验证。*

**这是使用 macOS 私有 API 的实验原型。** 系统更新可能影响兼容性。目标是让实体显示器关闭后仍能进行图形工作；实体屏实际待机、节电效果、关闭实体输出后的 Agent 操作，以及长期无人值守运行，**目前都没有完成验证**。

## 功能和边界

- 创建多块独立命名的虚拟显示器，例如「虚拟屏 1 · Codex」「虚拟屏 2 · GrokBot」，每块可选 1920 × 1080 或 2560 × 1440，以及 HiDPI。
- 菜单栏按虚拟屏分组，悬停查看各屏应用和可见窗口数量，可单独关闭某块屏幕。
- 按桌面顺序显示每块实体屏和 yomado 虚拟屏，屏幕按逻辑桌面尺寸的比例显示，应用图标直接显示在屏幕内部（名称与窗口数见悬停提示）。有效拖入时，目标屏幕高亮、图标轻轻晃动；开启“减弱动态效果”时只显示静态高亮。拖动图标即可移入虚拟屏、在虚拟屏之间转移，或返回某块实体屏；手动移动的窗口也会被识别。
- 支持从 Finder 拖入已运行 App 的 `.app`，明确选择移动该 App 的普通窗口。
- 屏幕命名与设置收在每块虚拟屏的「…」菜单中；右上角「＋」用于创建新屏或启动已保存的屏幕。
- 在虚拟屏存在期间，请求系统和图形桌面保持唤醒。

虚拟屏属于**当前登录会话**，不是独立的操作系统、用户会话或键鼠隔离环境。Agent 和你共用焦点与输入，需要协调桌面使用。Yomado 不提供远程桌面服务，也不是 Agent；查看、截图和输入仍由你原有的工具完成。

## 控制面板

![yomado control panel](docs/images/yomado-control.png)

*原生控制面板预览，使用示例显示器数据；这张图不代表目标应用操作或实体显示器待机已验证。*

简洁的面板保留「yomado · 夜窗」、一句用途说明和屏幕排列，应用图标显示在各自屏幕内部。应用名与窗口数通过悬停查看，操作入口使用图标和菜单。点击虚拟屏上的「…」即可重命名或关闭。该菜单也显示分辨率与 HiDPI；需要调整时先关闭该屏，再从「＋」菜单找到已保存的屏幕，修改设置后重新启动。

一次本地实测通过应用选择菜单，把计算器从实体屏移入 Codex，再转移到 GrokBot 虚拟屏。在 GrokBot 上重新截图可以看到计算器窗口，键盘输入 `2 + 3` 并回车后显示 `5`；执行返回操作后，窗口位置和大小恢复到原来的状态。这验证了该应用的菜单移屏、跨虚拟屏转移、截图、键盘输入与主动返回。另一项单虚拟屏测试确认：关闭该屏后，计算器先恢复原位置和大小，随后虚拟屏被移除。直接拖动图标、关闭一块虚拟屏同时保留另一块，以及实体屏关闭后的工作仍未完成验证。

## 下载

[下载 Apple Silicon 应用](https://github.com/chekusu/yomado/releases/download/v0.3.5/Yomado-v0.3.5.zip) · [版本说明](https://github.com/chekusu/yomado/releases/tag/v0.3.5)

官方 v0.3.5 下载包已由 CHEKUSU INC. 使用 Developer ID 签名，并通过 Apple 公证、附带公证票据。它仍是使用私有 API 的实验版本；Apple 公证不等同于 Mac App Store 上架。

## 编译

需要 macOS，以及 Xcode 或 Command Line Tools。只依赖系统框架，没有第三方运行依赖。

```sh
bash ./build.sh
```

生成：

```text
dist/Yomado.app
dist/Yomado.zip
```

构建脚本通过 `xcrun` 使用当前 Xcode 或 Command Line Tools，也可以设置 `YOMADO_DEVELOPER_DIR` 选择其他开发工具目录。

目前验证过 Apple Silicon 原生构建。macOS 14 部署目标只是编译设置，不代表所有 macOS 14 及以上系统、或 Intel Mac 均已兼容。[GitHub Releases](https://github.com/chekusu/yomado/releases/tag/v0.3.5) 提供实验性的 Apple Silicon 应用和 SHA-256 校验值，暂不提供 Intel 版本。

本地构建默认使用 **ad hoc 签名**。显式设置 `YOMADO_SIGNING_IDENTITY` 后，脚本会为应用和恢复进程使用 Developer ID Application 签名、强化运行时及安全时间戳；此步骤不会自动提交 Apple 公证。[官网分发流程](docs/distribution.md) 说明签名、公证、附加公证票据及发布验证。只有 Apple 接受该构建、最终下载包也通过验证后，才会将该版本标记为已公证。是否运行本地构建，请遵循自己 Mac 的正常安全策略。

## 使用虚拟屏

1. 打开本地编译的 `Yomado.app`，面板会显示现有实体屏及其可见应用。
2. 点击「＋」，启动已保存的屏幕（例如 Codex），或新增一块屏。用屏幕上的「…」为它取 Agent 的名字。新虚拟屏追加在现有排列最右侧，实体显示器继续保持输出。
3. **只把 Agent 所需的应用图标**拖到目标虚拟屏内部。图标代表该 App 在来源屏上的普通窗口，不会顺带搬走同一 App 位于其他屏幕上的窗口。也可以手动移动真实窗口；从 Finder 拖入已运行的 `.app`，则明确选择该 App 分布在各屏幕上的普通窗口。尚未打开的 App 请先打开。
4. 将应用图标拖回某块实体屏内部，或使用图标的返回操作。实体屏之间暂不通过图标移屏，需要直接拖动真实窗口。应用数量按检测到的可见窗口统计，不代表 GPU 渲染量或 Agent 工作进度。部分 App 不支持辅助功能窗口定位，软件会说明失败。
5. 如果现有查看或 Agent 工具支持选择显示器，选中虚拟屏。开始工作前，验证目标应用的新截图，以及一次实际、可逆的输入操作。

保留实体显示器作为主屏，需要调整真实排列时使用 macOS 的显示器设置。分辨率和 HiDPI 在启动已关闭的屏幕时生效；HiDPI 将两个方向的像素数量各翻倍，例如 1920 × 1080 逻辑桌面对应 3840 × 2160 像素。

切换显示器、移动窗口或调整缩放后，旧坐标可能失效，需要重新获取截图和窗口状态。能截图不等于键盘、鼠标操作也已正常。

使用期间必须保持 yomado 运行。应用同时显示在 Dock 和菜单栏，让控制面板可以独立参与台前调度。关闭控制面板后，应用和菜单栏控件继续运行。菜单中的每块屏幕都有独立的应用子菜单和关闭入口；「退出 yomado」关闭所有屏幕。关闭前会尝试把该屏窗口送回实体屏；无法确认恢复时保留该屏。其他虚拟屏继续运行。

通过 yomado 移入的普通 App 会保留本次运行中的原窗口位置；在虚拟屏之间转移时沿用最初的位置。拖回原实体屏会恢复原位；拖到另一块实体屏则在该屏居中。自行手动移入、没有原位置记录的窗口，也会在你选中的实体屏居中。图标的通用返回操作优先使用原位置；没有记录时返回当前实体主屏。普通 App 的窗口记录保存在内存中；名称与分辨率偏好会保存到本机。软件不会在登录或重启后自动创建虚拟屏。多个虚拟屏仍共用同一套键鼠和焦点，不意味着多个 Agent 可以同时独占输入。

Yomado 不修改密码、锁屏策略、屏保或登录设置；保持唤醒的请求不能解锁 Mac。截图和输入权限由执行这些操作的工具自行管理。

## 命令行控制虚拟屏

本 fork 给应用二进制增加了 `screen` 命令，脚本和 Agent 无需打开面板或点击菜单即可管理虚拟屏：

```sh
Y=/Applications/Yomado.app/Contents/MacOS/Yomado
$Y screen list
$Y screen create --name Agent --size 1920x1080   # 可选：--hidpi
$Y screen start Agent
$Y screen close Agent
$Y screen rename Agent "Agent · Blender"
$Y screen configure Agent --size 2560x1440 --hidpi
$Y screen delete Agent
```

`SCREEN` 可以是屏幕编号、名称，或完整标题（如 `虚拟屏 1 · Agent`）。到达 yomado 的命令在 stdout 输出一个 JSON 对象：成功时为 `"ok": true` 及相关屏幕，失败时为 `"ok": false` 及原因。用法错误和无法连接 yomado 时，改为在 stderr 输出一行 `error:` 文本。退出码：0 成功，1 被 yomado 拒绝或操作失败，2 用法错误，3 无法连接 yomado。

命令通过仅当前用户可读写的套接字 `~/Library/Application Support/dev.chekusu.yomado/control.sock` 与运行中的应用通信。yomado 未运行时，命令会在后台启动它，不激活应用，也不显示控制面板。`create`、`start`、`close` 会等显示配置核对完成后才返回，与面板使用相同的检查。被拒绝的情况（例如屏上仍有窗口且未开启辅助功能权限时 `close`）写在回复里，不弹出提示框。`configure` 和 `delete` 只适用于已关闭的屏幕；对运行中的屏幕 `rename`，系统显示器名称在下次启动时更新。

## Agent 会话：不占用你的鼠标键盘操作应用

本 fork 还让 Agent 在虚拟屏上操作应用时不移动你的光标、不抢键盘焦点、不改变你的前台应用。辅助进程 `Contents/Helpers/YomadoAgent.app` 把点击、拖动、滚动和按键直接发给目标窗口所在的进程，让该应用在不被切到前台的情况下认为自己处于活跃状态（因此文本框、菜单和快捷键可用），并通过 ScreenCaptureKit 与辅助功能读取窗口。Agent 的应用若自己跳到前台，辅助进程会把你的应用切回来，并告知 Agent。

Agent 在代码里使用它，会话在多步之间保持：

```js
// omp eval（Bun）
const { connect } = await import("/Applications/Yomado.app/Contents/Resources/agent/yomado.ts");
globalThis.ym = await connect({ screen: "Agent" });
const [calc] = (await ym.launch("Calculator")).windows;
await ym.type(calc.id, "12*3"); await ym.key(calc.id, ["return"]);
const { path } = await ym.capture({ window: calc.id });
```

Python 客户端（`Contents/Resources/agent/yomado.py`）提供相同调用；`Yomado agent --screen Agent` 是逐行 REPL（`launch Calculator`、`click 7057 34 211` 等）。辅助进程按需启动，沿用 Agent 所用工具已有的辅助功能与屏幕录制授权，yomado 本身不需要额外授权。Agent 的窗口仍与你共用同一登录会话：macOS 只有一个 key window，所以这是让 Agent 不妨碍你，而不是给它第二套键盘。设计与协议见 [fork-features/agent/README.md](fork-features/agent/README.md)。

## 版本与检查更新

面板底部显示当前版本，并提供 [yomado.app](https://yomado.app/)、GitHub 源码和 MIT 协议入口。点击版本旁的刷新图标，或菜单栏菜单中的「检查更新…」。菜单栏只保留夜窗 logo 的窗子轮廓，背景透明、颜色跟随系统外观；应用图标仍保留完整深色底图。

关闭或最小化控制面板后，重新打开 yomado 会唤回面板。明确打开面板时，如果有可用实体屏，会把落在虚拟屏或屏幕范围外的面板恢复到实体屏，只调整控制面板本身，不移动其他应用或修改屏幕排列。

检查由你手动发起：yomado 读取官方 GitHub Releases，包含当前的实验预发布版本，发现新版后提供版本页面入口。网络失败会明确提示并支持重试，不会误报为已是最新。无需账号，不发送设备标识或遥测数据。检查不会自动下载、安装、退出或调整显示器。安装下载的新版本前，请先保存工作、把应用从虚拟屏返回，再退出旧版并打开新版；重启应用不会保留运行中的虚拟屏。

## 微信窗口恢复（实验功能）

微信与其他 App 一样，以图标形式出现在所在屏幕内部。通过 yomado 移入微信时，软件额外保存主窗口在实体屏上的位置和大小；需要登录或处理安全提示时，可使用图标的返回操作，或拖回实体屏。存在待恢复的微信安全检查点时，会优先回到记录中的原显示器，即使拖放目标是另一块实体屏。微信需要先返回实体屏，才能移入另一块虚拟屏。

未开启辅助功能权限时，标题区域会出现**锁形图标**，应用图标拖放暂不可用。点击锁形图标可直接进入「隐私与安全」下的对应页面，再由你开启 yomado 开关。旧系统称为「辅助功能」，macOS 27 称为「设备控制和数据访问」。列表中没有该应用时，点「＋」选择应用。授权后，面板会自动识别并收起锁形图标。只有点击该图标才会请求权限，打开设置页面本身不会完成授权。

本地构建默认使用 ad hoc 签名。重新编译后，系统可能仍保留绑定旧签名的权限记录，开关显示开启也未必对新构建生效。重新打开应用后仍显示锁形图标时，请在系统设置中移除旧 yomado 记录，再用「＋」添加当前应用并开启。yomado 不会自行重置或修改系统权限记录。

移屏后，软件会有限度检查受支持的登录或安全对话框，识别成功就把微信送回实体屏，不会点击提示。普通聊天窗口的内容不会被扫描。部分微信版本没有提供可识别的对话框标记，因此不能保证自动返回，仍需保留手动恢复入口。自动恢复失败后会暂停后续尝试；如果还有待恢复的微信窗口且恢复失败，停止或退出 yomado 会被阻止。

检查点保存在 `~/Library/Application Support/dev.chekusu.yomado/`，只包含应用标识、显示器 UUID、窗口位置/大小和恢复标记，不保存聊天、联系人、截图、密码或登录凭证。恢复窗口无法恢复已经失效的登录，登录或验证仍由你完成。原显示器不可用时，会退回可用的实体屏，并把窗口约束在屏幕范围内。

此前的单屏测试验证过一次微信移入和返回原位置。当前电脑操作工具的微信窗口截图在实体屏、虚拟屏上都返回白图，因此视觉输入验证已停止；不能据此宣称微信视觉自动化已通过。真实退出登录后的自动恢复仍未完成验证。

## 实体显示器

当前控制面板保持实体显示输出，不再提供之前的关闭实体输出试验入口。创建或关闭虚拟屏，不会请求关闭实体显示器。

后续需要现场关屏验证时，先在实体屏开启的情况下，确认目标应用能真实截图并响应可逆输入。之后可通过显示器自身的控制关闭实体屏，同时保持 Mac 唤醒、桌面会话可用；再观察实体显示器，并重新测试目标应用。这个阶段尚未完成验证，只有虚拟屏存在，不能证明 Agent 在实体屏关闭后仍能正常工作。

截图变黑、或者软件显示输出已关闭，都不能证明显示器进入待机或耗电降低。yomado 无法切断显示器电源，也不测量功耗。源码保留早期恢复进程与命令行显示器自检供开发使用，它们不是当前面板中的实体显示器电源开关。

## 诊断与测试

只读接口和显示器清单检查：

```sh
./dist/Yomado.app/Contents/MacOS/Yomado --diagnose
```

默认隐藏实体显示器序列号。需要本地诊断时，可加 `--include-device-identifiers` 参数将其包含在输出中。清单仍会描述你的显示配置，分享前应检查并清理。

构建脚本编译、签名并严格验证临时构建中的应用包，**不会**启动应用或运行显示器测试。默认使用 ad hoc 签名；Developer ID 签名需要显式设置 `YOMADO_SIGNING_IDENTITY`。

以下纯策略测试不会创建显示器或打开应用：

```sh
bash ./test.sh
```

它们检查显示放置、窗口归属与恢复几何、微信检查点、诊断脱敏及更新策略。更新测试使用模拟网络覆盖版本比较、实验版、分页、重复请求和失败情况，不访问 GitHub。这些测试不调用私有显示 API，也不能证明真实显示配置或跨应用输入能够成功。

独立的隐藏 AppKit 布局回归检查屏幕比例、顶部对齐、应用列表变化、滚动和窗口缩放。它需要 macOS WindowServer 会话，不读取或移动真实应用窗口，也不创建显示器：

```sh
bash ./scripts/test-layout.sh
```

以下命令使用示例数据生成界面预览，不读取或更改显示排列、不读取微信，也不激活应用窗口：

```sh
./dist/Yomado.app/Contents/MacOS/Yomado --preview-ui ./test-output/control.png multi light
```

请先创建输出目录。预览状态支持 `empty`、`running`、`multi`，以及保留的 `trial` 示例；外观支持 `light`、`dark`。旧 `trial` 示例不会让当前控制面板出现关闭实体输出按钮。渲染依赖 macOS AppKit/WindowServer，只绘制自有隐藏视图，不能代替真实显示器或目标应用测试。

以下测试需要交互式 macOS 登录会话。**不要自动执行、不要放入构建型 CI，也不要在别人正在使用桌面时执行。** 测试会创建、移除临时显示器，并应用排列恢复，可能导致窗口移动。先保存工作，并关闭其他 Yomado 实例。

```sh
./dist/Yomado.app/Contents/MacOS/Yomado --self-test ./test-output/standard
./dist/Yomado.app/Contents/MacOS/Yomado --self-test ./test-output/hidpi hidpi
./dist/Yomado.app/Contents/MacOS/Yomado --watchdog-test ./test-output/watchdog \
  ./dist/Yomado.app/Contents/MacOS/YomadoWatchdog
```

生命周期自检验证临时虚拟屏、尺寸、应用自有 AppKit 视图、虚拟输出关闭与重新启用、移除，以及排列恢复尝试。恢复进程测试使用可丢弃的子进程和临时虚拟恢复目标。两类测试都不会主动关闭实体输出。

生成的视图图片**不是** Blender、Marvelous Designer 或其他目标应用的屏幕截图。自检通过不等于 Agent 输入、实体屏待机、节电或无人值守运行已通过。测试记录可能包含显示器元数据，分享前请检查。

## 实现

`app/ControlUI.*` 和 `app/AppWorkspaceView.*` 绘制原生屏幕排列、应用图标及拖放目标；`app/AppWorkspace.*` 管理通用 App 的窗口归属与位置恢复；`app/WindowRecovery.*` 及纯策略头文件处理主动启用的微信窗口检查点。`app/Yomado.m` 包含 AppKit 应用和测试入口；`app/Watchdog.m` 是恢复进程源码；`bridge/VDVirtualDisplay.*` 封装虚拟显示器接口。应用命名空间为 `dev.chekusu.yomado`。

`fork-features/control/YMControl.*` 实现 `screen` 命令：请求校验、应用内的控制套接字服务端和命令行客户端。`app/Yomado.m` 把每个请求映射到菜单和面板所用的同一套屏幕操作。

实现使用私有 `CGVirtualDisplay` 类，并动态发现 `CGSConfigureDisplayEnabled` / `SLSConfigureDisplayEnabled`，运行时检查相关功能是否可用。Apple 不保证这些接口长期兼容。

贡献代码时，应区分创建虚拟屏、修改显示拓扑，以及验证真实目标应用操作。诊断记录不要包含密钥或私人工作流信息；自动化中不要运行会修改显示配置的测试。

## 许可证

[标志与使用示意图](docs/images/PROMPTS.md) 由 image generation 生成，仓库附有对应提示词。

[MIT](LICENSE)。

### 多屏配置保护

创建工作屏时，会核对扩展模式、原主屏、显示模式与缩放、旋转、位置和镜像关系，通过后才允许移入应用。创建失败时只撤销新屏并校验恢复结果；未通过检查的目标不能接收窗口。已有屏幕之间的镜像设置会保留，关闭工作屏后也会验证剩余排列。

如果检测到其他设备连接或不属于本次操作的配置变更，会停止自动恢复，避免覆盖用户设置。DisplayLink 的具体扩展坞、驱动与 macOS 组合仍需实机验证。
