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

默认冻结**启动时鼠标所在显示器**，在该显示器上显示无边框覆盖窗口。按 `Esc` 或 `Q` 退出。不会改动系统显示分辨率，也不需要辅助功能权限。Cmd-Tab 可切换到其他应用。

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
| 滚轮、`=` / `+` / `-`、触控板捏合 | 以光标为中心平滑缩放 |
| 鼠标左键拖动 | 平移；松开后惯性衰减 |
| `0` | 重置位置、缩放、惯性、镜像、聚光灯 |
| `M` | 水平镜像 |
| `F` | 开关聚光灯 |
| `Ctrl` + 滚轮 | 调整聚光灯半径；半径随图像缩放 |
| `P` | 切换最近邻 / 线性采样 |
| `L` | 实时捕获 / 冻结当前帧（屏幕模式） |
| 空格 | 重新截屏并冻结（屏幕模式） |
| `R` | 重载配置，失败时保留已有配置 |
| `Ctrl-R` | 重载 `--shader` 指定的 Metal 源码 |
| `H` / `?` | 显示或隐藏帮助 |
| `Q` / `Esc` / `Cmd-Q` | 退出 |

默认最近邻采样保留放大后的像素格。触控板双指滚动与滚轮一样用于缩放，捏合也可缩放。实时模式排除 Boomer 自身以避免画面递归；它显示桌面变化，但鼠标事件仍由 Boomer 接收。静态画面、相机和聚光灯不再变化时停止 Metal 绘制。

## 多显示器

```sh
./build/boomer --list-displays
./build/boomer --display 1
```

显示器编号从 0 开始。每次只捕获一个显示器，使用其原生 Retina 比例；不拼接整个虚拟桌面。拔掉被捕获的显示器时应用退出。

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
linear_filter = 0
```

`min_scale` 为 0.001–1，`max_scale` 为 1–1024；`scroll_speed` 为 (0, 100]；两个 friction 为 (0, 1000]；`flashlight_radius` 为 1–10000 逻辑点，`flashlight_dim` 为 0–1，`linear_filter` 为 0 或 1。原版四个配置键均可使用。缩放改为指数平滑，手感不与原版数值逐项一致。

## 开发与验证

```sh
make test       # C 相机/配置测试（ASan + UBSan）及 CLI 测试
make test-gpu   # 实际 GPU 离屏渲染：方向、颜色、镜像、聚光灯、缩放
make test-window # 各已连接显示器的实际启动窗口位置；无需录屏权限
./build/boomer --demo --windowed --quit-after 3
./build/boomer --shader src/Shaders.metal --demo --windowed
```

`--quit-after` 在首帧图像加载后计时，用于 GUI 冒烟测试。错误 shader 不会替换正在使用的管线。`make check` 运行全部自动化测试，GPU 和窗口测试需要可访问 Metal 的本地用户会话。窗口测试检查每个显示器的覆盖模式和窗口模式；连接第二个显示器可验证非零原点，单屏时会提示该覆盖范围缺失。

已在 Apple M1 / macOS 15.7.3 上通过严格编译、Clang 静态分析、ASan / UBSan、CLI 和 Metal 离屏测试；已实际检查演示画面、拖拽、缩放、镜像、聚光灯、真实桌面截图、实时捕获、冻结、刷新和退出。双屏启动位置已通过实际 AppKit 窗口回归测试，覆盖主屏、副屏及两种窗口模式。Intel Mac、显示器热插拔及触控板捏合尚未做硬件实测。

| 文件 | 职责 |
| --- | --- |
| `src/Camera.c` | 光标锚定缩放、与帧率无关的阻尼、配置解析 |
| `src/main.m` | AppKit 生命周期、输入、CLI、演示卡 |
| `src/Capture.m` | ScreenCaptureKit 截图 / 实时流，异步取消 |
| `src/Renderer.m` | Metal 资源、图像转换、CVMetalTextureCache、GPU 测试 |
| `src/Shaders.metal` | 全屏三角形、相机变换、采样、聚光灯 |

实时帧通过 CVMetalTextureCache 使用 IOSurface，保留像素缓冲直到 GPU 完成。最多三个绘制命令在途。静态图片统一转换到 sRGB BGRA，绘制视图使用逻辑点，drawable 使用实际像素。

原版可选的 X11 单窗口点选追踪和 MIT-SHM 编译开关未移植；实时捕获由 ScreenCaptureKit 提供。本地开发证书用于保持本机应用身份，不能代替对外分发所需的 Developer ID 签名或公证。不包含全局启动热键，可通过系统快捷指令或启动器打开应用。

## 来源与许可

功能和操作参考 [Tsoding 的 Boomer](https://github.com/tsoding/boomer)，原版使用 Nim / X11 / OpenGL，本项目重新实现 macOS 平台层与渲染。保留原作者 MIT 许可声明，详见 [LICENSE](LICENSE)。截屏使用 Apple 的 [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)。
