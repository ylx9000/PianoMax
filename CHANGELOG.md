# Changelog

## v1.0.0-beta - 2026-10-21

第一版。写给小米平板 8 Pro（piano / SM8750P）。

### 档位

- 四个预设：省电 / 均衡 / 性能 / 极限，命令行 key 为 powersave / balanced / performance / extreme
- 省电（1.56/1.96 GHz、GPU 389 MHz、交还内核温控）、均衡（2.40/2.84、660 MHz）、性能（3.07/3.51、832 MHz）、极限（3.53/4.32、1100 MHz）
- 档位与滑块写同一批文件（.target / .gpu / .bus / .zones / .trip），不存在第二套状态
- 所有频率在写之前对齐到内核真实频点阶梯；不对齐会被内核静默取整，界面显示的数就和模块要的不一样了
- 热降档按档位基准值算百分比，不按当前值，避免逐级衰减；省电档不会被降档逻辑反而抬回 3.07 GHz
- 切档后有 15 秒宽限，避免上一个档位的余热立刻触发新档位更低的绊线

### 频率

- CPU 3532800 / 4320000 kHz，走 `thermal_message/cpu_limits` 命令通道
- GPU 先解 `type=gpu` 冷却设备的锁存，再写 `devfreq/max_freq`，拿到 1100 MHz 档位
- DDR 4761000 / LLCC 1211000，memlat 与 bwmon 全部投票一起写
- 上限写下去之前先把 `max_pwrlevel` / `min_pwrlevel` 的钳制关系理清：kgsl 会把 max 钳到 min 之下并仍然返回成功

### 守护

- `guard.sh` 每秒读一次实际上限，被压下就重写 cpu_limits（mi_thermald 约每 2 秒写一次，同频会半程失守）
- 两条独立绊线：芯片按档位 90-105 °C（结温，关机点约 110）、机身按档位 50-75 °C（外壳与电池）
- 分三级降档而非一次性还原：先降一档继续顶，仍热再降一档，三级用尽才整体还原并暂停；温度回落两分钟后逐级升回
- 降档值是档位上限的 88% / 78%，对齐真实频点阶梯；恢复方向同样按档位基准回算，不用硬编码值
- 守护进程每 30 次循环写一行心跳（温度与当前档位），卡住时日志可见
- `boot-completed.sh` 每 5 分钟检查一次守护进程，未运行即重新启动
- 检测到 KernelSU 的 `disable` 文件时先还原再退出
- 卸载脚本不含任何等待循环：KernelSU 以 ScriptWait::Forever 执行它

### 温度

- 计算温区设为 `disabled`，停止内核 governor 的降频动作；省电档则将其交还内核
- 电池、充电、BCL 电流限制、PMIC 结温全部保留
- 不写 `emul_temp`，不停 `mi_thermald`

### 内存与调度

- min_free_kbytes 40960 / extfrag 300 / compaction 30 / MGLRU 500 ms
- 桌面与 SystemUI 的 `oom_score_adj` 锁 -1000
- watchdog 超时提到 180 秒

### WebUI

- 五个页签、二十多项可调参数、深浅双主题
- 性能页顶部四个档位按钮，点一下整套参数跟着变
- 每几秒一次 `control.sh snapshot`，一个进程取回全部状态
- 每次写入回读确认，界面显示「已生效 / 被钳制 / 未写入」
- `ksu.exec` 回调参数一律按字符串处理后再转数值，避免类型比较失效
- 顶部状态条归因：正常运行 / 接近绊线 / 已过温还原 / 守护未运行 / 上限未生效

### 发布说明

- Release 资产提供稳定名 `PianoMax.zip`，README 的下载链接永远指向最新版

