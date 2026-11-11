# boomer.m

[tsoding/boomer](https://github.com/tsoding/boomer) 的 macOS 原生重写：C 负责相机与配置，Objective-C / AppKit 负责窗口与事件，Metal 负责缩放、镜像和聚光灯，ScreenCaptureKit 负责屏幕捕获。无 Nim、X11、OpenGL 或第三方运行时依赖。

需要 **macOS 14 Sonoma 或更新版本**、支持 Metal 的 Mac，以及 Xcode Command Line Tools。Metal 源码嵌入可执行文件，在启动时编译，不需要完整 Xcode 或离线 Metal 编译器。

## 构建与启动

```sh
make setup-signing  # 本机开发建议只运行一次，创建固定签名身份
make
open build/Boomer.app
```

`make setup-signing` 创建 Boomer 专用的本地开发证书和独立钥匙串，并将该钥匙串追加到当前用户的搜索列表，供 codesign 查找私钥。它不设置系统证书信任，也不修改其他应用权限。证书、私钥钥匙串及其随机密码保存在权限受限且已被 Git 忽略的 `.local-signing/`；不要提交、分享或在日常清理构建时删除这个目录。`make clean` 保留它。有 Apple Development / Developer ID 证书时，也可以用 `make CODESIGN_IDENTITY="证书名称"`。

未设置固定身份时，构建退回临时签名并输出警告。临时签名以二进制哈希识别应用，重新编译会导致原录屏授权不再匹配；固定证书签名会保留应用身份。没有代码变化时，`make` 保留现有 `.app` 和签名。

也可直接运行命令行版本：

```sh
./build/boomer
./build/boomer --delay 2
./build/boomer --windowed
./build/boomer --live
```

默认以菜单栏应用常驻，首次打开会冻结**鼠标所在显示器**，显示无边框覆盖窗口。之后在任何应用中按 **Cmd+Shift+2** 抓取新画面，再按一次收起；`Esc`、`Q` 或关闭窗口也只收起，**Cmd-Q 或菜单栏的 Quit Boomer 才完全退出**。隐藏后停止实时捕获和 Metal 绘制，释放截图与 drawable，保留窗口、Metal 管线和可复用的截图过滤器。不会在后台持续录屏，也不改动显示分辨率；全局热键使用 Carbon 注册，不需要辅助功能或输入监控权限。

原来通过快捷指令绑定了 Cmd+Shift+2 的话，请移除旧绑定，避免两套入口冲突。Boomer 使用独占热键注册；注册失败时菜单栏会显示状态，仍可点击 Capture Screen 使用，并在释放旧绑定后点击 Retry Global Shortcut。按住热键不会反复开关窗口。

点击菜单栏 Boomer 图标 → **Shortcut Settings…**，点击录制框后直接按下想用的快捷键。至少包含 Command 或 Control，Cmd-Q 保留用于退出；Esc 取消本次录制。Save 后立即生效并保存，重启仍有效。冲突时提示重新录制，Cancel 恢复原绑定；Restore Default 选回 Cmd+Shift+2 后需点击 Save。设置窗口打开期间暂停全局绑定，让录制框也能收到原来的组合键。菜单栏和截图提示同步显示当前组合。

```sh
open build/Boomer.app --args --background  # 仅启动常驻，等热键后再截图
open build/Boomer.app --args --once        # 原来的单次模式，Esc/Q 退出，无全局热键
```

重新 `open` 已运行的应用时，隐藏状态会抓取新画面，显示状态只激活窗口。命令行参数只在启动新进程时生效，切换模式前需完全退出已有实例。应用没有自动添加登录项；要常驻使用，先打开一次应用即可。常驻模式不显示 Dock 图标；仍可用 Cmd-Tab 切换到其他应用，用全局热键或菜单栏回到 Boomer。

启动时先在隐藏窗口中完成首帧 Metal 绘制并提交给系统合成器，再显示窗口，避免截图就绪后仍短暂露出黑底。绘图缓冲暂时不可用时会保持隐藏并重试；后续交互仍使用异步 GPU 绘制。

首次截图在 AppKit 启动完成前发起，屏幕枚举和截图准备与应用初始化重叠执行。截图直接通过 IOSurface 映射为 Metal 纹理，省去 CGImage 转换和整屏像素拷贝。提前到达的截图会保留到窗口就绪；后续唤起复用排除 Boomer 自身的过滤器，每次仍请求新截图。缓存请求失败时会重新枚举并重试一次。`--delay` 在每次捕获会话开始、窗口准备好后计时，收起会取消尚未完成的请求。

排查快捷指令启动延迟时，可以临时使用下面的命令（把路径换成实际路径）：

```sh
open --stderr /tmp/boomer-startup.log /path/to/Boomer.app --args --trace-startup
```

先完全退出已有的 Boomer，再执行命令。`Startup` 日志记录从程序进入 `main` 起的分段累计耗时；每次唤起另有 `Session ready`，记录从开始处理捕获请求到可交互的耗时。均不包含事件送达前的系统调度。默认不输出这些计时日志。

首次捕获需要系统的屏幕录制权限。在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」允许 Boomer；直接从终端执行二进制时，系统也可能将权限归属到终端。建议通过 `open build/Boomer.app` 使用应用自身的授权。

如果设置中已经开启 Boomer，应用却仍被拒绝，尤其是在旧临时签名构建升级到固定签名之后：退出 Boomer，在该页面选中 Boomer 后按减号移除，再用加号添加**当前的 `build/Boomer.app`**，重新启动即可。这会刷新旧签名的授权记录。仅看开关是否开启不足以确认当前构建已获授权。应用现在直接尝试 ScreenCaptureKit，并在失败时显示真实错误域和错误码。

无需屏幕录制权限的演示及图片模式：

```sh
open build/Boomer.app --args --demo --windowed
./build/boomer --image /path/to/image.png --windowed
```

图片自动适配窗口、应用 EXIF 方向；超过 16384 像素的图片会缩小。演示画面由本地代码绘制。

## 操作

| 操作 | 功能 |
| --- | --- |
| `Cmd-Shift-2`（全局） | 隐藏时捕获并显示；显示或等待截图时收起 |
| 滚轮、`=` / `+` / `-`、触控板捏合 | 以光标为中心平滑缩放 |
| 鼠标左键拖动 | 平移；松开后惯性衰减 |
| `0` | 重置位置、缩放、惯性、镜像、聚光灯 |
| `M` | 水平镜像 |
| `F` | 开关聚光灯 |
| `Ctrl` + 滚轮 | 调整聚光灯半径；半径随图像缩放 |
| `P` | 循环切换最近邻 / 线性 / 双三次平滑采样 |
| `L` | 实时捕获 / 冻结当前帧（屏幕模式） |
| 空格 | 重新截屏并冻结（屏幕模式） |
| `R` | 重载配置，失败时保留已有配置 |
| `Ctrl-R` | 重载 `--shader` 指定的 Metal 源码 |
| `H` / `?` | 显示或隐藏帮助 |
| `Q` / `Esc` / 关闭窗口 | 收起并保持常驻；`--once` 模式下退出 |
| `Cmd-Q` / 菜单栏 Quit Boomer | 完全退出并释放全局热键 |

默认使用双三次平滑采样，改善文字和细线放大后的像素块感；按 `P` 可对比三种效果。最近邻保留像素格，线性更柔和，双三次使用 Catmull–Rom 插值并限制局部颜色范围，抑制笔画周围的亮边和暗边。双三次仅在源像素被放大时启用，按实际 drawable 像素判断（含 Retina），原尺寸与缩小时使用线性采样。这是全图插值，不是文字识别或 AI 超分，不能恢复截图中已经丢失的字形细节。

触控板双指滚动与滚轮一样用于缩放，捏合也可缩放。实时模式排除 Boomer 自身以避免画面递归；它显示桌面变化，但鼠标事件仍由 Boomer 接收。静态画面、相机和聚光灯不再变化时停止 Metal 绘制。

## 多显示器

```sh
./build/boomer --list-displays
./build/boomer --display 1
```

显示器编号从 0 开始。每次只捕获一个显示器，使用其原生 Retina 比例；不拼接整个虚拟桌面。默认在**每次唤起时**重新选择鼠标所在显示器，`--display` 则固定编号。切换显示器时会丢弃旧过滤器；显示器配置变化或系统休眠会收起常驻窗口并使缓存失效，下次唤起重新准备。`--once` 模式下拔掉被捕获的显示器仍会退出。

通过快捷指令或启动器打开时，默认仍选择鼠标所在显示器。窗口定位会将显示器的全局坐标转换为该屏幕的相对坐标，避免在副屏启动时窗口偏移到屏幕外、只留下后台进程。覆盖模式和 `--windowed` 均使用这一转换。

## 配置

沿用原版配置位置：`$XDG_CONFIG_HOME/boomer/config`，未设置该变量则为 `~/.config/boomer/config`。不自动写入用户目录。

```sh
./build/boomer --new-config
./build/boomer --config ./my-config
```

`--new-config [路径]` 拒绝覆盖已有文件。配置支持空行、`#` 注释和以下参数：

```ini
min_scale = 0.01
max_scale = 64
scroll_speed = 1.5
drag_friction = 6
scale_friction = 12
flashlight_radius = 200
flashlight_dim = 0.8
filter_mode = 2
```

`min_scale` 为 0.001–1，`max_scale` 为 1–1024；`scroll_speed` 为 (0, 100]；两个 friction 为 (0, 1000]；`flashlight_radius` 为 1–10000 逻辑点，`flashlight_dim` 为 0–1。`filter_mode` 为 0（最近邻）、1（线性）或 2（双三次，默认）。旧配置的 `linear_filter = 0/1` 仍有效；两个键同时存在时 `filter_mode` 优先，与顺序无关。已有配置若指定 `linear_filter = 0`，需改成 `filter_mode = 2` 或按 `P` 切换才能启用平滑。原版四个配置键均可使用。缩放改为指数平滑，手感不与原版数值逐项一致。

## 开发与验证

格式化和静态检查使用 **LLVM 20** 的 `clang-format` / `clang-tidy`，配置分别保存在仓库根目录的 `.clang-format` 和 `.clang-tidy`。Homebrew 安装方式：

```sh
brew install llvm@20
export PATH="$(brew --prefix llvm@20)/bin:$PATH"
make format       # 格式化 src/、tests/ 中的 C、Objective-C、头文件和 Metal 源码
make format-check # 只检查格式，不改文件
make lint         # 检查 C / Objective-C 源码及其头文件，警告视为错误
```

也可用 `CLANG_FORMAT=/path/to/clang-format`、`CLANG_TIDY=/path/to/clang-tidy` 指定工具路径。lint 自动使用当前 macOS SDK，检查应用源码和测试代码；Metal shader 由下面的 GPU 测试实际编译与验证。

```sh
make test       # C 相机/配置测试（ASan + UBSan）及 CLI 测试
make test-gpu   # 实际 GPU 离屏渲染：方向、颜色、镜像、聚光灯、缩放、插值与边缘
make test-window # 各已连接显示器的窗口位置、首帧与绘制重试；会短暂显示演示卡，无需录屏权限
make test-hotkey # 独立测试热键注册、重复按键、冲突和释放，不占用 Cmd+Shift+2
make test-capture # 模拟系统回调，测试缓存、缓冲生命周期、取消和失效重试，无需录屏权限
./build/boomer --once --demo --windowed --quit-after 3
./build/boomer --shader src/Shaders.metal --demo --windowed
```

`--quit-after` 在首帧就绪并显示窗口后计时，用于 GUI 冒烟测试；收起会取消这一会话的定时退出，不能与 `--background` 同用。错误 shader 不会替换正在使用的管线。`make check` 运行格式检查、lint 和全部自动化测试，GPU、窗口和热键测试需要本地用户会话。GPU 测试覆盖 CGImage 和 IOSurface 截图缓冲区的方向、颜色与生命周期。窗口测试覆盖各显示器和两种窗口模式、首帧隐藏与重试，以及常驻隐藏/重新打开、资源复用、状态重置、取消旧回调、延迟实时捕获和后台启动。连接第二个显示器可验证非零原点，单屏时会提示该覆盖范围缺失。

已在 Apple M1 / macOS 15.7.3 上通过严格编译、Clang 静态分析、ASan / UBSan、CLI 和 Metal 离屏测试；已实际检查演示画面、拖拽、缩放、镜像、聚光灯、真实桌面截图、实时捕获、冻结、刷新和退出。双屏启动位置已通过实际 AppKit 窗口回归测试，覆盖主屏、副屏及两种窗口模式。Intel Mac、显示器热插拔及触控板捏合尚未做硬件实测。

| 文件 | 职责 |
| --- | --- |
| `src/Camera.c` | 光标锚定缩放、与帧率无关的阻尼、配置解析 |
| `src/main.m` | AppKit 生命周期、输入、CLI、演示卡 |
| `src/Capture.m` | ScreenCaptureKit 截图 / 实时流，异步取消 |
| `src/HotKey.m` | Carbon 全局热键注册、冲突处理与释放 |
| `src/Timing.c` | 可选的启动分段计时 |
| `src/Renderer.m` | Metal 资源、图像转换、CVMetalTextureCache、GPU 测试 |
| `src/Shaders.metal` | 全屏三角形、相机变换、采样、聚光灯 |

屏幕截图和实时帧通过 CVMetalTextureCache 使用 IOSurface，保留像素缓冲直到 GPU 完成。最多三个绘制命令在途。屏幕捕获配置为 sRGB BGRA；演示卡和外部图片转换到相同格式，绘制视图使用逻辑点，drawable 使用实际像素。

原版可选的 X11 单窗口点选追踪和 MIT-SHM 编译开关未移植；实时捕获由 ScreenCaptureKit 提供。本地开发证书用于保持本机应用身份，不能代替对外分发所需的 Developer ID 签名或公证。

## 来源与许可

功能和操作参考 [Tsoding 的 Boomer](https://github.com/tsoding/boomer)，原版使用 Nim / X11 / OpenGL，本项目重新实现 macOS 平台层与渲染。保留原作者 MIT 许可声明，详见 [LICENSE](LICENSE)。截屏使用 Apple 的 [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)。
