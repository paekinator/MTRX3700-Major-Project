# ECHO-7 Phase 1 使用与审核说明

归属：MTRX3700 ECHO-7 项目组。由 OpenAI Codex 辅助编写；人工审核待完成。

## 数据流

Camera PCLK -> ov7670_capture -> 原有双时钟 frame_buffer -> clk_25 camera_display
-> segmentationSelector（并行 Fixed/Ratio/HSV）-> vgaMaskOverlay -> vga_sink。

保持原有 320×240 RGB565 缓存、偶数行列降采样和 640×480 显示。
从 camera_display 30 位输出恢复 RGB565：{data[29:25],data[19:14],data[9:5]}。
原始 30 位值始终随像素传输，关闭覆盖时逐位保留；没有新增 Mask 帧缓存。

## 时序与控制

- 所有新增 RTL 使用 clk_25、同步高有效 reset25。
- Fixed/Ratio 各 1 个 CE 寄存级，HSV 3 个 CE 寄存级。
- Selector 将 Fixed/Ratio 补齐至 3 级，原像素、SOP/EOP 和控制标签同拍推进。
- Overlay 有 1 个弹性寄存级。整个新增路径无暂停时为 4 级、160 ns，吞吐 1 像素/周期。
- Selector 输出停顿时统一冻结流水线；Overlay 独立保持输出。延迟按推进拍计，停顿增加墙钟延迟。
- SW[3:1] 两级同步，并要求整个向量稳定 250,000 周期（25 MHz 下约 10 ms）。
- 算法和覆盖开关在输入 SOP 真正被握手接收时一起采纳，SOP 像素使用新设置。
- 原始模式仍经过同一流水线，不是后续 R9 Bypass。SW0 完全不参与逻辑。

| SW2 SW1 | 算法 |
|---|---|
| 00 | Fixed RGB |
| 01 | RGB Ratio |
| 10 | HSV |
| 11 | 安全回退 Fixed RGB |

SW3=0 原图，SW3=1 覆盖；SW0 保留。开关稳定后等待下一输入帧边界生效。
Mask=00 保持原像素，01 红色，10 蓝色；算法双命中输出 00，Overlay 对 11 保持原像素。

## 参数

Fixed: RED_R_MIN=160, RED_G_MAX=100, RED_B_MAX=100;
BLUE_B_MIN=160, BLUE_R_MAX=100, BLUE_G_MAX=100。
Ratio: MIN_VALUE=80, RATIO_NUM=3, RATIO_DEN=2；主通道至少为每个其他通道的 1.5 倍。
Ratio 支持 MIN_VALUE 0..255，NUM/DEN 1..255。
HSV: SAT_MIN=96, VALUE_MIN=80, RED_H_MAX=85, RED_H_MIN=1451,
BLUE_H_MIN=853, BLUE_H_MAX=1109。H 一周为 1536 单位，S 以 255 为满量程。
HSV 支持 S/V 0..255、H 阈值 0..1535，蓝色下限不大于上限。
这些都是后续实物校准的起始值。

HSV 实现：第一级寄存 RGB/max/delta；第二级形成色相分子和阈值乘积并判定 S/V；
第三级比较输出 Mask。H=num/delta 的范围判断改为 num 与阈值×delta 比较；
S 判断使用 255×delta >= SAT_MIN×max。无浮点、无运行时除法、无倒数 LUT，且无除法舍入误差。
delta=0 时明确禁止颜色命中；红色区间覆盖色相环两端。常数乘法仍可能占用 DSP。

## 自动化检查

在已有 Verilator 5.050、C++ 编译器和 make 的课程环境中，从工程根目录运行：

```text
python tools/echo7/run_tests.py
python tools/echo7/run_tests.py --regression
python tools/echo7/check_math.py
```

run_tests.py 不安装软件，不删除旧结果；每次在 work/echo7_tests 下建立新目录。
需要在平台原生可用的 Python/Verilator 环境运行；缺少工具时返回 2，测试失败返回 1。
测试编译和仿真日志、命令及汇总保存在每次运行目录。脚本使用 --timing --assert。
check_math.py 仅验证独立数学模型，不能替代 RTL 测试。

| 自检测试 | 覆盖 |
|---|---|
| echo7_algorithms_tb | 三算法各穷举 65536 个 RGB565，CE/reset/invalid，固定阈值等号及重叠 |
| vgaMaskOverlay_tb | 全部 Mask/enable 组合、保留编码、任意原数据、停顿/复位/空拍 |
| echo7_stream_tb | Selector+Overlay，所有开关模式、帧边界、抖动、满吞吐、反压和复位 |
| echo7_integration_tb | 8 个 640×480 帧，真实 frame_buffer/camera_display，不同时钟、缩放、多不规则区域、并发写入 |

--regression 还运行已有 capture/frame_buffer/display/system 测试；system 显式固定 SW=0。
实际是否通过必须查看该次运行 summary.json；未运行的测试不能标为 PASS。

## 引脚及已知限制

SW0=AB12, SW1=AC12, SW2=AF9, SW3=AF10，3.3-V LVTTL。
来源为本地 C:/Quartus_Projects/Test_BUTT/DE1-SoC_pin_assignments.csv，
并与 C:/Quartus_Projects/Majortut/alltest/mtrx3700-hwtest-src/hwtest/quartus/hwtest.qsf 交叉核对。
SW 异步输入在 Camera.sdc 中设置输入 false path；内部同步级间路径仍被正常分析。

单缓存撕裂以及双时钟 RAM 同地址读写不确定性仍属于原结构限制。
颜色阈值未上板校准，自动曝光/白平衡会影响识别；未更改任何 OV7670 寄存器。
有效像素 Mask 与其被接受的原像素同源，不能保证消除原有视频撕裂或恢复传感器丢失的细节。
初始缓存填充前显示内容仍遵循原工程行为。

## 上板步骤（人工执行）

1. 先在课程仿真环境运行上述 RTL 测试，审核结果与源码；审查 Quartus 报告。
2. 保留原 Camera.sof；核对目标板为 DE1-SoC/5CSEMA5F31C6。
3. 断电连接原有摄像头适配板和 VGA，按原工程方式上电。
4. 人工选择审核过的 Phase 1 SOF 编程；SW3=0、SW2:1=00，按 KEY0 重新配置摄像头。
5. 检查 LEDR0 配置完成、LEDR1 无错误，确认原视频、颜色、方向、同步正常。
6. SW3=1，分别选择 00/01/10。用多个不规则红蓝物体移动、旋转并改变距离，观察覆盖随轮廓变化。
7. 使用白/灰/黑/绿/黄/品红背景及弱光进行误检测试；记录参数、光照和现象。
8. 帧中反复切换算法及 SW3，检查下一帧切换、画面无错位或丢同步；11 应与 Fixed 相同。
9. 拨动 SW0，确认第一阶段画面行为不受影响。必要时恢复原 SOF 对比。

备份位于 Codex outputs/echo7-baseline-20261022-022255，包含修改前源码、SHA-256 清单和原 SOF。
恢复源码时按清单从备份复制原文件；新增 echo7 文件另行保留，避免覆盖后续人工修改。
