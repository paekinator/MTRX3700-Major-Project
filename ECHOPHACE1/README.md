# MTRX3700 ECHO-7

本工程集成 OV7670 实时视觉处理和 FPGA 底盘安全控制，用于 DE1-SoC。

## 1. 工程位置

```text
C:\Quartus_Projects\Majortut\ECHOPHACE1
```

Quartus 工程入口：

```text
quartus/Camera.qpf
```

编译生成的 FPGA 下载文件：

```text
quartus/output_files/Camera.sof
```

修改 RTL 或参数后，需要重新编译并下载新的 `.sof` 文件。

## 2. 已实现功能

### 2.1 摄像头与 VGA

- OV7670 RGB565 图像采集。
- 320×240 Frame Buffer。
- 640×480 VGA 输出。
- 图像逆时针旋转90°。
- 旋转后的图像等比例显示为360×480，左右各140像素黑边。
- 摄像头方向寄存器保持 `0x1E = 0x07`。

数据流：

```text
OV7670
  → Camera Capture
  → Frame Buffer
  → Display Rotation / Scaling
  → Colour Segmentation
  → Mask / ROI / Bounding Box / Diagnostics
  → VGA
```

### 2.2 三种颜色分割算法

支持红色和蓝色检测：

- Fixed RGB：固定通道阈值。
- RGB Ratio：整数颜色比例判断。
- HSV：定点颜色判定。

Mask 编码：

| 编码 | 含义 |
|---|---|
| `00` | 背景 |
| `01` | 红色 |
| `10` | 蓝色 |

Mask 根据实际识别像素绘制，红色和蓝色像素分别覆盖为纯红色、纯蓝色。

### 2.3 Dynamic Detection

- 每种颜色维护一个聚合 Bounding Box。
- 使用绿色边框显示检测区域。
- 显示检测像素的平均 RGB／对应 HSV 数值。
- 设置最小检测面积门限。

多个同色物体可能被合并到同一个大框中；当前未实现独立多目标分离。

统计结果用于后续帧显示，运动目标可能出现约一帧的框位置滞后。

### 2.4 Fixed ROI Calibration

固定 ROI：

```text
左上角：(220,160)
右下角：(419,319)
尺寸：200×160
```

功能：

- 固定红色边框。
- 只统计 ROI 内的颜色检测结果。
- Mask 开启时只覆盖 ROI 内的检测像素。
- 框外保留实时图像。
- 显示 MODE、RGB、HSV 和 DETECT。
- 不显示 MASK 百分比。

RGB 来自中央20×20采样区的原始平均像素值，不依赖检测成功：

```text
采样区：(310,230) 至 (329,249)
```

HSV 由平均 RGB 转换：

- H：0–359°
- S：0–255
- V：0–255

DETECT 默认要求 ROI 内红色与蓝色检测像素合计至少32个。

统计面积单位为显示像素。旋转后的缩放倍率为1.5倍，不能直接用面积除以4换算源图像像素数。

## 3. VGA 开关配置

| 开关 | 功能 |
|---|---|
| `SW[2:1] = 00` | Fixed RGB |
| `SW[2:1] = 01` | RGB Ratio |
| `SW[2:1] = 10` | HSV |
| `SW[2:1] = 11` | 安全默认算法：Fixed RGB |
| `SW3 = 0` | 关闭颜色 Mask Overlay |
| `SW3 = 1` | 开启对应模式的 Overlay |
| `SW4 = 0` | Dynamic Detection |
| `SW4 = 1` | Fixed ROI Calibration |
| `SW0` | 保留给后续 R9 Bypass |

固定 ROI 模式中，关闭 Mask 后仍可使用固定框和数值显示。

固定 ROI + HSV + Mask 的组合：

```text
SW4=1, SW3=1, SW2=1, SW1=0, SW0=0
```

## 4. Emergency Stop 安全控制

控制链路：

```text
IR Receiver
  → NEC Decoder
  → POWER Latch / Manual Motion Request
  → Control Watchdog
  → Motor Safety Arbiter
  → Priority Zero-Speed Sender
  → UART
  → UGV02
```

### 4.1 POWER 急停

已实现：

- 有效 POWER 事件锁存 `estop_latched`。
- 急停期间最终左右轮目标速度均为0。
- 松开 POWER 后保持急停。
- NEC Repeat Frame 不会解除急停。
- 再次 POWER 不会解除急停。
- 急停期间 CH/VOL 和进入同一安全接口的视觉请求不能产生非零输出。
- KEY0 清除急停，并进入零速度 IDLE。
- 复位后必须收到新的有效运动命令才能启动。

未来视觉 FSM 必须接入 `motorSafetyController`，不得直接绕过仲裁控制 UART。

### 4.2 POWER 编码配置与当前状态

原配遥控器 POWER 按键的人工读码结果：

```text
HEX1 = 1
HEX0 = 2
Command byte = 0x12
```

这里只确认了命令字节，尚未确认完整32位编码或设备地址。

当前匹配逻辑未限制 NEC 地址，因此其他遥控器的相同命令字节也可能被接受。

顶层配置位置：

```text
rtl/top_level.sv
```

启用已测量的 POWER 命令：

```systemverilog
parameter bit POWER_KEY_CONFIGURED = 1,
parameter logic [7:0] POWER_KEY = 8'h12,
```

最后一次有完整自动编译记录的版本使用：

```systemverilog
POWER_KEY_CONFIGURED = 0
POWER_KEY = 8'h00
```

该版本是安全读码版，始终输出零速度。

`0x12` 配置已提供人工修改方法，但交接时必须检查当前源码和实际下载版本，不能假定已经完成重新编译和上板验证。

测试中的 `0xA5` 是合成测试数据，不是实物 POWER 编码。

## 5. 手动运动控制

以下行为要求 POWER 已配置并重新编译、下载：

| 按键 | 功能 |
|---|---|
| CH+ | 前进 |
| CH− | 后退 |
| VOL− | 原地左转 |
| VOL+ | 原地右转 |
| 1 | 速度0.1 m/s |
| 2 | 速度0.2 m/s |
| 3 | 速度0.3 m/s |
| 4 | 速度0.5 m/s |
| POWER | 锁存急停 |
| 板上 KEY0 | 全局复位，清除急停，保持零速度 |

默认速度为0.1 m/s。实际运动效果仍需在底盘上验证。

## 6. 保持时间、Watchdog 与发送周期

参数位置：

```text
rtl/safety/safetySystem.sv
```

已验证的默认参数：

| 参数 | 默认值 | 50 MHz 下的含义 |
|---|---:|---|
| `HOLD_CLKS` | 15,000,000 | 300 ms 按键保持时间 |
| `WATCHDOG_CLKS` | 25,000,000 | 500 ms 控制请求有效期 |
| `PERIOD_CLKS` | 10,000,000 | 200 ms UART 命令发送周期 |
| `CLKS_PER_BIT` | 434 | 约115200 baud |

`HOLD_CLKS` 从最后一次有效运动按键或关联重复帧开始计算。

Watchdog 监测接受的控制请求更新，不由 UART TX 完成或 RX 活动刷新。超时后禁止沿用旧运动请求，持续请求零速度；新的合法请求才能恢复。

曾讨论过以下调整，但尚无对应修改与验证记录：

```systemverilog
HOLD_CLKS = 50_000_000       // 1秒
WATCHDOG_CLKS = 60_000_000   // 1.2秒
```

延长这些参数也会延长松键或红外信号丢失后的运动保持时间。交接时应核对实际参数。

## 7. UART 停车机制

协议沿用 UGV02 的 `T:1` JSON 速度命令：

```json
{"T":1,"L":0.0,"R":0.0}
```

每条命令以换行结束，串口为约115200 baud、8N1。

- 正常状态周期发送运动或停车命令。
- 安全停止时优先发送零速度，不等待普通200 ms周期。
- 在途 JSON 行先完整发送，再发送停车行。
- KEY0 也不会在中间截断正在发送的 JSON 行。
- 不通过关闭 UART 发送实现急停。

仿真扫描最长非零命令的26个发送位置，结果如下：

| 从 POWER 解码事件开始计时 | 最大实测值 |
|---|---:|
| 零速度帧第一个起始位 | 2.257350 ms |
| 零速度帧最后一个停止位完整结束 | 4.341030 ms |

这些结果不包含红外接收解码前的时间、底盘处理或车轮减速时间。

UART TX 完成不等于底盘收到命令。当前没有实现命令 ACK 或真实 UART 断线检测。

官方资料说明 UGV02 有约3秒无运动命令自动停车机制，但尚未确认本机固件及配置：
https://www.waveshare.com/wiki/UGV02

## 8. 双超声波

当前状态：

```text
Ultrasonic Safety DISABLED
sonar_safety_enable = 0
```

因此：

- 不接超声波不会因为缺少测量而阻止遥控运动。
- 超声波不会在接近障碍物时自动停车。
- 已接传感器仍执行真实测量，未用无限远替换数据。

已预留保护：

- 任一有效距离 ≤200 mm：禁止运动。
- 危险解除门限：230 mm。
- 未收到测量、无效测量或超过300 ms未更新：按故障处理。
- 两路独立维护有效性与数据年龄。
- 当前采用保守的全部方向停车策略，尚未定义传感器方向与允许避障方向。

测量接口包括：

```text
sonar1_distance_mm / sonar1_valid / sonar1_update
sonar2_distance_mm / sonar2_valid / sonar2_update
```

按住 KEY1 或 KEY2，HEX2..0 分别显示两只传感器的原始毫米值，采用十六进制：

```text
0C8 = 200 mm
FA0 = 4000
```

显示的旧距离不代表数据仍有效。测量上限4000被标记为无效。

## 9. 引脚

采用已确认的2026转接板接线：

| 信号 | FPGA 接口 | 器件引脚 |
|---|---|---|
| IR 接收 | IRDA_RXD | PIN_AA30 |
| 全局复位 | KEY[0] | PIN_AA14 |
| FPGA → 底盘 RX | GPIO_1[31] | PIN_AF23 |
| 底盘 TX → FPGA | GPIO_1[33] | PIN_AD21 |
| Sonar1 TRIG | GPIO_1[27] | PIN_AJ22 |
| Sonar1 ECHO | GPIO_1[29] | PIN_AG22 |
| Sonar2 TRIG，Port2/J4 | GPIO_1[35] | PIN_AC22 |
| Sonar2 ECHO，Port2/J4 | GPIO_1[34] | PIN_AA20 |

摄像头使用原有 GPIO_1[10..25]。

## 10. 状态显示

释放 KEY1、KEY2 时，HEX1..0 显示最后一个有效 NEC 命令字节。显示会保持，KEY0 清零。

| LED | 含义 |
|---|---|
| LEDR0 | 摄像头配置完成 |
| LEDR1 | 摄像头配置错误状态 |
| LEDR2 | 摄像头帧到达翻转 |
| LEDR3 | 安全停止状态 |
| LEDR4 | POWER 急停锁存 |
| LEDR5 | 控制请求过期 |
| LEDR6 | 曾收到有效 UART 字节，不代表命令 ACK |
| LEDR7 | 曾收到有效 IR 数据帧 |
| LEDR8 | POWER_KEY_CONFIGURED |
| LEDR9 | 超声波安全启用状态，当前为0 |

## 11. 主要文件

```text
rtl/top_level.sv                 顶层实例化和引脚连接
rtl/echo7/                      视觉算法、ROI、Mask、Bounding Box和显示
rtl/safety/
  irEmergencyStop.sv           POWER急停锁存
  controlWatchdog.sv           请求有效期监测
  motorSafetyArbiter.sv        最终速度仲裁
  motorSafetyController.sv     请求保存、Watchdog和仲裁组合
  ultrasonicSafety.sv         可禁用的双超声波保护
  irMotionControl.sv          手动请求与重复帧处理
  safeChassisCommand.sv       优先停车JSON发送
  necDecoderSafe.sv           完整复位的NEC解码器
  dualSonar.sv                双超声波测量
  sonarSampleCdc.sv           测量跨时钟域传输
  safetySystem.sv             IR、控制及UART组合
  safetyHex.sv                十六进制显示
  reference/                 原始课程参考源码
tb/safety/                    安全Self-checking Testbench
tools/echo7/run_tests.py       自动测试入口
quartus/Camera.qpf             Quartus工程
quartus/Camera.qsf             源文件列表和引脚
quartus/Camera.sdc             时序约束
work/safety/report.txt         详细实现与交接报告
work/safety/verification.json  实际验证记录
```

## 12. 已执行验证

使用 ModelSim Altera Starter Edition 10.5b。

以下测试最终均为 PASS：

- safety_unit_tb
- uartSafety_tb
- irSafety_tb
- sonarSafety_tb
- rotation_tb
- roiCalibration_protocol_tb
- ov7670_capture_tb
- frame_buffer_tb
- camera_display_tb
- camera_system_tb

覆盖急停锁存、重复帧、复位、请求超时、恢复行为、超声波阈值/无效/过期、UART帧和在途停车，以及原摄像头功能回归。

未运行 Verilator 5.050。失败尝试和修复后的成功运行均保留在验证记录中。

最后一次安全读码版 Quartus 完整编译结果：

| 项目 | 结果 |
|---|---:|
| Errors / Warnings | 0 / 93 |
| ALM | 3779 |
| 寄存器 | 3495 |
| Memory bits | 1,228,800 |
| RAM blocks | 152 |
| DSP | 8 |
| PLL | 2 |
| 最差 Setup Slack | +5.157 ns |
| 最差 Hold Slack | +0.144 ns |
| 显示时钟最低所报 Fmax | 28.70 MHz，工作25 MHz |

这些完整布线及时序结果对应 POWER_KEY_CONFIGURED=0。

启用运动路径使用测试码单独通过 Analysis & Synthesis；没有生成该测试配置的下载文件，也没有完成该配置的布线及时序检查。

## 13. 交接后的测试顺序

1. 核对当前 top_level.sv 的 POWER 参数，以及 safetySystem.sv 的时间参数。
2. 修改参数后重新编译，检查错误、警告及时间裕量。
3. 确认下载的是本次生成的 Camera.sof。
4. 先不接底盘，检查视频和遥控器读码。
5. 接底盘后先将车轮架空，使用最低速度测试方向和松键停车。
6. 按 POWER，确认锁存停车；再按方向键、重复 POWER 均不得运动。
7. 按 KEY0 后确认保持静止，再用新的方向命令启动。
8. 验证串口实际停车帧和车轮停止时间。
9. 单独验证底盘 UART 断线后的固件超时行为。
10. 保持超声波安全禁用，直到完成传感器测量、故障和实机保护验证。

## 14. 当前限制与未完成项

- 未完成底盘实机急停及停车距离验证。
- POWER 的0x12来自人工命令字节读码；尚未限制遥控器地址。
- 已观察到另一只遥控器也能产生0x12解码结果，原因尚未通过完整数据或波形确认。
- 未实现独立的硬件断电急停。
- 未实现真实 UART 断线检测或运动命令接收确认。
- 超声波停车保护当前关闭。
- 尚未实现自主停靠或视觉运动 FSM。
- Bounding Box 为每种颜色一个聚合框。
- 保留原单帧缓存可能出现的图像撕裂风险。
- 修改 POWER、运动保持时间等参数后，需要重新测试。
- 仿真和综合通过不能替代真实板卡与底盘测试。

## 15. 来源与人工审核

新增模块、测试及集成包含 OpenAI Codex AI 辅助实现。

工程决策、参数选择、硬件验证及最终提交由 MTRX3700 ECHO-7 团队负责。

参考：

- OWNERS.md
- AI_STATEMENT.md
- work/safety/reference_sources.json
- work/safety/verification.json

组员应补充实际负责人、人工审核记录及上板测试结果。