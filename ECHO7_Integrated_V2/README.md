# MTRX3700 ECHO-7 — Member B + C Integration / 视觉与底盘集成

## 1. Scope and current status / 范围与当前状态

This project integrates the latest Member B FPGA perception pipeline with the validated Member C chassis controller on DE1-SoC. The production top is `echo7IntegratedTop`. POWER starts a visual target task; all wheel requests pass through the safety arbiter before reaching the UGV02 UART driver.

本工程将最新版 Member B 视觉系统与已验证的 Member C 底盘控制系统集成。保留数字标牌识别、薄锚点补查、主色连通域检查、正常模式透视校色、Bounding Box Bypass 和 VGA RGB/HSV 诊断。POWER 只启动视觉任务，不绕过 FSM 直接驱动车轮。

| Evidence layer / 证据层 | Current checkpoint / 当前结果 | Boundary / 边界 |
|---|---|---|
| RTL_SIM | 11 integration/regression test groups PASS / 11 组集成与回归测试通过 | Includes simulated pixels, IR, sonar and UART; not physical robot acceptance / 不代替实机验收 |
| QUARTUS_FIT_TIMING | Full Compilation successful, 2026-11-04 / 完整编译成功 | Quartus Prime Lite 18.1; resource and timing figures below / 资源与时序见下文 |
| PROGRAMMED / ROBOT_HW | Not performed for this integrated checkpoint / 本集成版本尚未执行 | No FPGA download or motor activation by this workflow / 未自动下载或启动电机 |

Original Member B, Member C and the previous successful integration remain separate. Source provenance is recorded in `integration_sources_v2.json`. Original staff/IP notices and Member B attribution in [OWNERS.md](OWNERS.md) remain applicable; that inherited document is not a new sign-off for Member C or this integration.

原始视觉工程、原始底盘工程及旧版成功集成工程保持独立。来源清单记录于 `integration_sources_v2.json`；保留原课程/IP 声明及已有作者归属。原 Member B 的历史实拍、下载和测试记录不自动视为本集成版本的验收结果。

## 2. Repository and inputs / 仓库与输入

| Path / 路径 | Purpose / 用途 |
|---|---|
| `rtl/common/`, `rtl/capture/`, `rtl/vision/` | Public types, camera capture and latest pixel algorithms / 公共类型、相机采集及新版像素算法 |
| `rtl/interaction/`, `rtl/tracking/`, `rtl/debug/` | Calibration, target tracking, JTAG and VGA diagnostics / 校色、目标跟踪及诊断 |
| `rtl/top/echo7IntegratedTop.sv` | Production integration top / 正式集成顶层 |
| `rtl/member_c/` | Adapter, motion FSM, safety arbiter, NEC, sonar, UART and HEX / 底盘控制与安全模块 |
| `quartus/PartBDebug.qpf` | Production Quartus project / 正式 Quartus 工程入口 |
| `quartus/*.sdc` | Existing clock and CDC constraints / 时钟及跨域约束 |
| `tests/member_c/`, `tests/integration/` | Self-checking testbenches and simulation-only models / 自检测试与仿真模型 |
| `tests/vectors/` | Pixel replay inputs required by tests / 必要像素回放输入 |
| `tests/run_integration.ps1`, `tests/run_v2_extra.ps1` | ModelSim regression runners / 仿真入口 |
| `integration_sources_v2.json`, `tests/check_v2.py` | Local source-provenance audit / 本地来源与原工程未改动审计 |

The source audit refers to the original local source directories; it is not a portable prerequisite for a fresh Git clone. Test vectors and required IP descriptions must be retained. Generated databases and simulation work libraries are not source files.

来源审计依赖开发电脑上的原工程路径，不能作为其他电脑克隆仓库后的必备条件。保留 RTL、QPF/QSF/SDC、IP 描述、Testbench 和必要测试向量；编译数据库与仿真工作库不属于源码。

## 3. Tools, build and real hardware / 工具、构建与真实硬件

- Board / 开发板：DE1-SoC, Cyclone V `5CSEMA5F31C6`.
- Tool / 工具：Quartus Prime Lite 18.1.0 Build 625; ModelSim Intel FPGA Starter Edition 18.1.
- Project/revision / 工程及修订名：`PartBDebug`.
- Top-level / 顶层：`echo7IntegratedTop`.
- Local integration directory / 本地集成目录：`C:\Quartus_Projects\ECHO7_Integrated_V2`.

Open `quartus/PartBDebug.qpf` in Quartus. Confirm the device and top above before compiling. From the repository root, a manual build can also be run as follows (adjust the installation path if needed):

在 Quartus 打开上述 QPF，核对器件与顶层后编译。也可在仓库根目录执行以下 PowerShell 命令：

```powershell
Push-Location .\quartus
& 'C:\intelFPGA_lite\18.1\quartus\bin64\quartus_sh.exe' --flow compile PartBDebug -c PartBDebug
Pop-Location
```

Output / 输出：`quartus/output_files/PartBDebug.sof`. Compilation does not program the board. `tests/compile_once.ps1` is the original one-shot local audit wrapper; its marker intentionally prevents automatic repeated full builds.

### Verified fit / 已核对的拟合结果

The retained SOF and current source have not undergone strict hash-based build correspondence verification. Matching build timestamps alone do not establish reproducibility.

保留的 SOF 与当前源码尚未完成严格哈希对应验证；构建时间一致不能证明源码与二进制可复现对应。

Figures below come from this project's `PartBDebug.fit.summary`, `.flow.rpt` and `.sta.summary`, not from the standalone visual project.

以下数据来自本集成工程实际报告，非独立视觉工程的历史结果。Flow Status 为 **Successful**，SOF 生成时间为 **2026-11-04 08:20:45**（开发电脑本地时间）。

| Metric / 指标 | Latest B+C / 新版集成 | Previous B+C / 旧版集成 |
|---|---:|---:|
| ALM | 29,476 / 32,070 (92%) | 28,302 (88%) |
| Registers / 寄存器 | 40,847 | 37,536 |
| M10K | 356 / 397 | 349 |
| DSP | 57 / 87 | 47 |
| PLL | 2 / 6 | 2 |
| Physical / virtual pins / 实际及虚拟管脚 | 133 / 0 | 133 / 0 |
| Minimum setup slack / 最小建立裕量 | +1.157 ns | +2.659 ns |
| Minimum hold slack / 最小保持裕量 | +0.117 ns | +0.108 ns |

The new integration adds 1,174 ALMs, 7 M10Ks and 10 DSPs relative to the old integration. Positive setup/hold summaries do not mean every compiler warning has disappeared; preserve and review the complete reports when releasing a build.

相比旧版集成增加 1,174 ALM、7 M10K、10 DSP。Setup/Hold 汇总裕量均为正；这不表示编译器所有警告已消失，发布构建时应保留完整报告供复核。

## 4. Architecture, clocks and ownership / 架构、时钟与控制归属

```text
OV7670 -> capture / latest Member B perception -> targetTracker
                         ^                         |
                         | targetRequest (24)      | targetReport (141)
                         |                         v
IR POWER/A -> Member C perception_adapter -> motion_fsm
                    J3 sonar -> safety_arbiter -> chassis_command -> UART -> UGV02
```

Member B and C share `CLOCK_50`, the synchronized reset and one `timeUs` source. Camera, video and sonar clock-domain crossings retain their existing constraints. The sonar path uses a stable payload request/acknowledge transfer into the 50 MHz domain; its multibit distance is not sampled directly across asynchronous domains.

B/C 共用 50 MHz 时钟、同步释放的复位与唯一 `timeUs`。超声波保持原测距时钟设计及 `count >> 8` 换算，通过稳定数据握手跨入控制域。未通过放宽 SDC 或改变视觉流水线换取资源。

`memberCSimulator` is absent from the production control path. Member C is the sole target-command owner. The integration disables conflicting JTAG target commands while retaining visual diagnostics and calibration; it does not add a second request driver.

## 5. Perception and public contract / 视觉算法与公共接口

The authoritative public v3 definitions are in [perception_pkg.sv](rtl/common/perception_pkg.sv). Use its packed types rather than manually reconstructing bit order.

| Signal / 信号 | Width / 位宽 | Meaning / 含义 |
|---|---:|---|
| `targetRequest` | 24 | C to B, `targetRequest_t`, Valid/Ready / 目标请求 |
| `targetReport` | 141 | B to C, `targetReport_t`, Valid/Ready / 目标报告 |
| `perceptionStatus` | 76 | B to C, `perceptionStatus_t` / 感知状态 |
| `timeUs` | 32 | Shared microsecond time / 共享微秒时基 |

On POWER, C captures SW[4:2], requests `TARGET_SELECT` with `MARKER_BAY + digit`, and holds the request until accepted. Only blue bay 1–6 is selectable; 000/111 cannot start a task. The adapter verifies requestTag, identity, configuration version, frameGood, observed, locked, targetSelected, ambiguity, readiness and fault state. Reports older than 150 ms from `captureStartUs` are unusable; an invalid or stale report revokes movement permission.

POWER 锁定拨码选择；请求通过握手接收后才完成传输。目标身份、配置、锁定和新鲜度均参与运动许可，不能沿用旧位置继续行驶。最新版视觉算法保持原样，包括薄锚点、主色连通域及透视校色；本工程只新增/复用集成连接与底盘控制。

## 6. Controls and display / 操作、开关与显示

| Control / 操作 | Function / 功能 |
|---|---|
| KEY0 | Reset B/C; remain stopped and require a new POWER / 复位后保持停止，需重新 POWER |
| POWER, NEC 0x12 | Start one selected task; repeats do not restart / 启动任务，重复帧不重启 |
| A, NEC 0x0F | Latched emergency stop; KEY0 required to clear / 锁存急停，仅复位解除 |
| SW[4:2] | Blue bay 1–6, captured at task start / 启动时锁定蓝色编号 |
| SW0 / SW1 | Retain original visual overlay/diagnostic selection / 保留视觉叠加与诊断功能 |
| SW8 | Retain Bounding Box Bypass / 保留包围框旁路模式 |
| SW9 | Raw camera mode; perception motion is unavailable / 原始相机模式，不提供感知运动许可 |
| KEY1 | Cycle distance / NEC high16 / NEC low16; also retains visual snapshot action / 切换 HEX 页，同时保留视觉快照动作 |

HEX5 identifies `d`, `H` or `L`; HEX4 is a separator; HEX3–HEX0 show decimal distance in mm or the corresponding four hexadecimal digits. Invalid distance is blank. NEC data remains visible after releasing the remote button.

LEDR0: motion permission; LEDR1: IR E-STOP; LEDR2: distance valid; LEDR3: DOCKED; LEDR4: sonar safety stop; LEDR5: UART busy; LEDR6/7: NEC full/repeat frame; LEDR8: validated visual target; LEDR9: unused task with valid distance, not a general visual-ready indicator.

## 7. Motion and safety / 运动与安全

| State / 状态 | Behaviour / 行为 |
|---|---|
| IDLE | Zero wheel requests, waiting for POWER / 等待启动 |
| SEARCH | Stationary, waiting for the selected target / 静止寻牌，不自动旋转 |
| ALIGN | Turn at logical wheel speeds ±0.04 m/s until centreU is 110–130 / 低速对准 |
| APPROACH | Logical forward 0.05 m/s above 500 mm; 0.03 m/s at 350–500 mm / 分段低速接近 |
| DOCKED | Normal stop at ≤350 mm with valid aligned target; stay stopped / 正常停靠并保持 |
| LOST | Zero requests after visual loss; fresh valid target may restore alignment / 丢失停车，重新识别后可对准 |

IR A has priority over sonar safety, which has priority over normal motion. Distance ≤250 mm, invalid measurements or stale sonar data prohibit movement. The sonar samples every 100 ms; valid range is 20–3999 mm, with a 30 ms measurement watchdog and 1 s freshness limit. No echo or the 4000 mm saturation value is not safe clearance. Sonar safety and IR emergency stops are latched; POWER cannot clear them. A 250 mm safety event is not reported as successful docking.

安全优先级为 A 急停、超声波安全、普通运动。正常 350 mm 停靠与 250 mm 保护独立处理；无回波不能视为空旷安全。当前版本没有早期独立测试的 3 秒自动停车计时器，运动由目标、FSM 与安全逻辑控制。

Wheel requests use integer cm/s and are bounded to absolute speed ≤0.15 m/s. Default motor polarity is `LEFT_POLARITY = -1`, `RIGHT_POLARITY = -1`; logical forward therefore becomes negative UART speeds. `TURN_SIGN = 1` is a convention requiring lifted-wheel verification, not a claim of physical direction calibration.

UART uses 115200 baud, 8N1 and UGV02 `T:1` closed-loop speed JSON. On a stop, nonzero permission is withdrawn immediately. Any JSON already in progress finishes intact, then zero speed takes priority without waiting for the 200 ms heartbeat. Stopped operation continues sending zero commands. KEY0 does not truncate an in-flight JSON.

```json
{"T":1,"L":0.00,"R":0.00}
```

## 8. Physical connections / 实际硬件连接

| Interface / 接口 | FPGA signal / 信号 | Pin / 管脚 |
|---|---|---|
| Remote / 红外 | IRDA_RXD | PIN_AA30 |
| J3 ultrasonic TRIG | GPIO_1[27] | PIN_AJ22 |
| J3 ultrasonic ECHO | GPIO_1[29] | PIN_AG22 |
| UGV02 UART TX | GPIO_1[31] | PIN_AF23 |
| UGV02 UART RX | GPIO_1[33] | PIN_AD21 |

Use one RCWL-1601 on J3 with 3.3 V supply and common ground. No J4 sensor is instantiated. Connect FPGA TX to chassis RX and FPGA RX to chassis TX. Camera/VGA assignments remain in the production QSF; there are no virtual B/C interfaces at the board boundary.

## 9. Tests and reproducibility / 测试与复现

Run from the repository root with ModelSim installed. Run the main suite first because the V2 extras reuse its compiled library:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run_integration.ps1
powershell -ExecutionPolicy Bypass -File .\tests\run_v2_extra.ps1
```

Both scripts accept `-ModelSimBin` to override the default installation directory. Simulation models, including `hcsr04_model.sv`, are testbench-only and are not Quartus synthesis sources.

| Test / 测试 | Verified result / 已核对结果 |
|---|---|
| tb_member_c | PASS, 136 checks |
| tb_motion_uart | PASS, stale/wrong target, sonar, A and docking zero priority |
| tb_wheel_uart | PASS, signed speeds/clamp and all 28 busy byte positions |
| tb_safety_arbiter | PASS, priority and lockouts |
| tb_uart_stop_priority | PASS, all 26 busy byte positions |
| memberBDebug_tb | PASS, command coherence, backpressure, frozen readback and reset |
| tb_jtag_ownership | PASS, 9 commands and sole C ownership |
| tb_integrated_link | PASS, 106 checks, 10 requests, 80 reports, 10 UART lines |
| tb_integrated_pins | PASS, 14 checks, 2 sensor measurements, 3 UART lines |
| perceptionCoreCollision_tb | PASS, 2 collisions and 11 reports |
| tb_v2_pixel_latency | PASS, 6 reports; normal max 40,917 µs, bypass max 22,540 µs |

The pixel test exercises the real perception pipeline on synthetic RGB565 input. Its measured latency is below the 150 ms limit for those cases, not a worst-case proof for every scene. Link tests inject observations at internal vision boundaries; pin tests exercise actual top-level IR/J3/UART signals with sensor models. The sonar model records one initial simulation-edge diagnostic, separated from runtime protocol checks by the testbench.

像素回放、接口注入及真实顶层管脚仿真分别提供不同证据，不能合并宣称为真实相机或实车测试。未在本集成工程中重新执行原视觉工程的所有历史测试。

## 10. Hardware acceptance and known limits / 实机验收与已知限制

1. Manually program the reviewed SOF; first keep the wheels lifted. / 人工确认 SOF 后下载，先架空车轮。
2. Check KEY0, stopped UART, HEX distance and A lockout. / 检查复位、零速度、测距显示和急停锁存。
3. Select a blue bay with SW[4:2], keep SW9 off, present a valid target and press POWER. / 选择编号，关闭纯相机模式，展示目标并启动。
4. Confirm turn polarity and forward direction before floor operation. / 落地前确认转向及前进方向。
5. Check visual loss/staleness, no echo, 250 mm safety, and separate 350 mm normal docking. / 分别验证视觉失效、无回波、安全停车与正常停靠。
6. Confirm A remains latched, POWER cannot release it, and KEY0 requires a new task. / 确认急停锁存及复位后重新启动流程。

Physical stopping distance includes measurement, processing, UART and chassis response delay. The distance threshold is a command threshold, not a guaranteed physical stopping position. This checkpoint has not established traction, braking distance, turn direction, live-camera robustness or end-to-end robot acceptance. No microphone/HPS/path planner is added.

## 11. Git handoff and provenance / Git 交付与来源

Track source, constraints, IP descriptions, scripts, small required test vectors and this documentation. Review ignore rules before staging; exclude generated `quartus/db/`, `quartus/incremental_db/`, `quartus/output_files/`, simulator work libraries, waveforms and local tool files from ordinary source commits. SOF and full reports may be distributed separately as reviewed release artifacts. No Git commit or push is performed by editing this README.

提交前检查忽略规则，避免把编译数据库、仿真缓存及大型生成文件一并上传。必要测试输入不能删掉。当前 README 记录的是集成版本，不能沿用原 Member B README 中“无电机控制”“已下载本版本”等不适用表述。

The integration reuses the existing C modules and previous integration top, preserves the latest B algorithm sources, and changes JTAG target ownership to prevent competing control. AI-assisted integration and documentation do not replace human source review or hardware acceptance. Preserve original authorship and do not assign unverified student identities or hardware sign-off.
