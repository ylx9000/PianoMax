# PianoMax v1.0.0-beta.6

**刷入前**：从 `v1.0.0-beta`（最早的公开版）升级，请先在 KernelSU 管理器里移除旧版再装本版；`v1.0.0-beta.4` 及之后的版本可直接覆盖刷入。

本版无调参行为变化，改动集中在还原路径、配置导出与注释文档三处。

## 修复

- **`restore.sh` 残留的 `oom_score_adj` 覆盖**：桌面与 SystemUI 的 `-1000` 写入在 beta.4 已移除，还原路径仍把它们写回 `0`。守卫不再写之后，这一步成了第二个与 AMS 抢写的写入者。写入与对应的过期注释一并删除
- **导出 zip 的自检在无 busybox 设备上必然失败**：旧循环把 `unzip` 也当作「前缀 + applet 名」的载体，命中独立二进制时实际执行 `unzip unzip -t`，完好的包被判为损坏并删除。改为先遍历 busybox 路径执行 `"$u" unzip -t`，全部失败后再用 `command -v unzip` 执行 `unzip -t`
- **crc32 探测写死安装路径**：`pm_crc32_available()` 探测 `/data/adb/modules/pianomax/module.prop`，模块 id 或安装路径变化后即失效，导出静默降级为纯 kv 文本。改用 `$PM_DIR/module.prop`，并移除循环外重复的 `busybox` 探测
- **导出容器注释与实际不符**：顶部描述为 module-flashable zip，实际只打包 `module.prop` / `presets.txt` / `config.txt`，无法刷入。改为 configuration snapshot zip (not flashable)

## 变更

- **`guard.sh` 移除无效果代码块**：`PM_LAUNCHER_PIN` 置空后，该块每 5 秒遍历全部 `/proc/[0-9]*`、对每个进程 fork 一次 `timeout 1 tr` 读取 cmdline，最终只进入一个恒假分支。整块删除
- **`[MONITOR-GPU]` 差异补进说明**：`thermal/extreme/README.txt` 原先只提到 `[SS-CPU0]` / `[SS-CPU6]`，现补齐第三处：原厂 `trig 25000` / `clr 23000` / `target 1` 那一档被移除，只保留 `trig 45000` / `clr 42000` / `target 5`
- **README 中英两版对齐**：温度伪装的差值温区由 `21` 改为 `20`（48 - 28）；WebUI 设计选择小标题的「四个」/「Four」与实际 7 条不符，改为「七个」/「Seven」；升级指引统一；英文版温区小节改指向 `DISCLAIMER.en.md`；结构树补上 `banner.png`
- **「两层机制」表格改写**：原表述「完全不受影响」只覆盖框架层，而内核层处理的是同一批温区，mi_thermald 的聚合输入中包含可伪装的计算温区。表格改为按层描述并指向下文
- **截图标注**：现有 WebUI 截图拍摄于 `v1.0.0-beta.2`，图注标明为版式示意
- **CHANGELOG**：`v1.0.0-beta.5` 条目日期更正为 `2026-10-25`

## 校验

- `PianoMax-v1.0.0-beta.6.zip` 134,248 字节
- SHA-256: `BC2DD077D8D5330D3C08B4700C2BF849E4B8E9A48E5997D1F8EBB0FBEC7330BC`
- tag `v1.0.0-beta.6`

核验：`curl -sL https://github.com/ylx9000/PianoMax/releases/download/v1.0.0-beta.6/PianoMax-v1.0.0-beta.6.zip | sha256sum`

## 升级说明

`v1.0.0-beta`（tag `e81dc0e`）是首个公开版本，状态文件名与档位名在其后有过更名，未做迁移测试，从它直接覆盖到本版不受支持，请先卸载再安装。`v1.0.0-beta.4`（tag `b52df53`）及之后的版本之间可直接覆盖刷入。
