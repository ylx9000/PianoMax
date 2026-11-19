# PianoMax v1.0.0-beta.6

**刷入前**：从 `v1.0.0-beta`（最早的公开版）升级，请先在 KernelSU 管理器里移除旧版再装本版；`v1.0.0-beta.4` / `v1.0.0-beta.5` 及之后的 beta 可直接覆盖刷入。

本版没有调参行为变化。改动集中在三处：beta.4 移除桌面保护时留下的还原路径尾巴、配置导出在无 busybox 设备上必然失败的自检、以及一批与代码实际行为对不上的注释与文档。

## 修复

- **`restore.sh` 残余的 `oom_score_adj` 覆盖**：桌面与 SystemUI 的 `-1000` 写入在 beta.4 已移除，但还原路径仍把它们写回 `0`。守卫不再写，这一步就成了第二个与 AMS 抢写的写入者。连同「守护进程把桌面锁到 -1000」这句过期注释一起删除
- **导出 zip 的自检在无 busybox 设备上必然失败**：旧循环把 `unzip` 也当成「前缀 + applet 名」的载体，命中独立二进制时实际执行 `unzip unzip -t`，于是完好的包被判成损坏并删除。改为先遍历 busybox 路径执行 `"$u" unzip -t`，全部失败后再用 `command -v unzip` 单独执行 `unzip -t`
- **crc32 探测写死安装路径**：`pm_crc32_available()` 探的是 `/data/adb/modules/pianomax/module.prop`，模块 id 或路径一变就失败，导出静默降级成纯 kv 文本。改用 `$PM_DIR/module.prop`，并删掉循环外那次重复的 `busybox` 探测
- **导出容器注释与实际不符**：顶部把它说成 module-flashable zip，实际只打包 `module.prop` / `presets.txt` / `config.txt`，刷不进去。改为 configuration snapshot zip (not flashable)

## 变更

- **`guard.sh` 移除死代码**：`PM_LAUNCHER_PIN` 被声明为空之后，每 5 秒那个块仍然遍历全部 `/proc/[0-9]*`、每个进程 fork 一次 `timeout 1 tr` 读 cmdline，只为走到一个恒假的分支。整块删除
- **`[MONITOR-GPU]` 差异补进说明**：`thermal/extreme/README.txt` 原先只提 `[SS-CPU0]` / `[SS-CPU6]`，现补齐第三处——原厂 `trig 25000` / `clr 23000` / `target 1` 那一档被移除，只剩 `trig 45000` / `clr 42000` / `target 5`
- **README 中英两版一致性**：温度伪装的差值温区由 `21` 改为 `20`（48 - 28）；WebUI 设计选择小标题的「四个」/「Four」与实际 7 条不符，改为「七个」/「Seven」；升级指引与本节口径统一；英文版温区小节改指向 `DISCLAIMER.en.md`；结构树补上 `banner.png`
- **「两层机制」表格不再写「完全不受影响」**：这句话只覆盖框架层，而内核层写的是同一批温区，mi_thermald 的聚合输入里就有可伪装的计算温区。表格改为按层描述并指向下文
- **截图标注**：现有 WebUI 截图实际拍摄于 `v1.0.0-beta.2`，图注标明为版式示意
- **CHANGELOG**：`v1.0.0-beta.5` 条目日期由 `2026-10-24` 更正为 `2026-10-25`（该条目引用了 10-25 才发生的热压频取证，日期倒错）

## 校验

- `PianoMax-v1.0.0-beta.6.zip` 134,248 字节
- SHA-256: `BC2DD077D8D5330D3C08B4700C2BF849E4B8E9A48E5997D1F8EBB0FBEC7330BC`
- tag `v1.0.0-beta.6`

核验：`curl -sL https://github.com/ylx9000/PianoMax/releases/download/v1.0.0-beta.6/PianoMax-v1.0.0-beta.6.zip | sha256sum`

## 版本号起点

`v1.0.0-beta`（2026-10-21，tag `e81dc0e`）是首个公开版本，`v1.0.0-beta.2` 起才有现在的四档温度伪装与参数说明链路。两者之间的状态文件名与档位名都换过，没有做迁移测试，所以从 `v1.0.0-beta` 直接覆盖到本版不做保证——先卸载再装。从 `v1.0.0-beta.4`（tag `b52df53`）起，各 beta 之间可直接覆盖刷入。
