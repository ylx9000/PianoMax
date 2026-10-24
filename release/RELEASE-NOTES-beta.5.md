# PianoMax v1.0.0-beta.5

**刷入前**：从 beta.4 升级请直接刷。beta.4 存在两份内容不同的构建共用一个版本号（见下），装过它的设备必须升到本版才能确认自己装的是哪一份。

## 修复

- 换表失败时旧标记残留（`.thermal_mode` / `.thermal_ts`），守护进程会误判「表在管」而停手 —— 失败即清标记，回落到每 tick 主动顶频
- 卸载/还原的无条件 `chattr -R -i` 解锁：KSU 更新清目录后旧版整段跳过还原，锁在 vendor 的表从此无路可解
- 孤儿 `.thermal_ts` 时间戳：还原后指向已不存在的表，现在与 `.thermal_mode` 一起清
- perfd 假日志：先查 `init.svc.<name>` 再停，不存在的机型不再刷「perfd stopped」
- 三处 `grep -q "$md5"` 哈希比对形同虚设（拿摘要字符串去 grep 密文），改为两侧算摘要再比
- KernelSU 下 `service.sh` 与 `boot-completed.sh` 重复看门狗，只留后者

## 变更

- WebUI 五处频率单位换算修正（kHz 是原生单位，旧版把 3532800 kHz 标成「3532.80 GHz」）
- 档位按钮改双簇显示：极限 =「3.53/4.32G · 4761」，大核对不再隐形
- **热压频可见化**（实机定性：大核 3801 = 内核热限在模块上限内压频，非失锁）：阶梯缓存防热缩、滑块精确吸附、WebUI 新增「内核热限正在压大核」提示、诊断脚本新增钳制溯源
- **日志系统 v2**：`<时间> <级别> <组件> <事件码> <消息> [k=v …]`，RFC 5424 级别纪律 + logfmt 字段；心跳降 D 不再刷屏、内核写入失败升 E；窗口 32→128 KB；WebUI 按级别/组件过滤
- 诊断脚本第 3 节区分「表在管 / 表装了但在顶频 / 无表」三种状态 + 不可变位自检

## 校验

- `PianoMax-v1.0.0-beta.5.zip` 135,276 字节
- SHA-256: `ED1714397DD60D4B651B6C9EA9044AB9E7C99AF894A23A67994F4C0A154701E9`
- tag `v1.0.0-beta.5` → commit `7c46ad0`

核验：`curl -sL https://github.com/ylx9000/PianoMax/releases/download/v1.0.0-beta.5/PianoMax-v1.0.0-beta.5.zip | sha256sum`

## 关于 beta.4 的两份构建

- GitHub 上的 beta.4 资产（124,404 字节）是 `abae45f` 的完整构建，能用；本地后来又完成了一轮修复（`0beaade`，6 个文件 157 行）但没推送，那个包是 127,581 字节。
- 两者 `module.prop` 都写 `versionCode=5`，所以装过 beta.4 的设备既收不到更新提示，也看不出自己装的是哪一份 —— 这是本次把 versionCode 让到 6 的原因。
- 用 `grep -c PM_LAUNCHER_PIN /data/adb/modules/pianomax/guard.sh` 可以判断手上是哪一份：返回 0 是 `abae45f`，非 0 是 `0beaade`。