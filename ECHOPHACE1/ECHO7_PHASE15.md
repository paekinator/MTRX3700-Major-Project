# ECHO-7 Phase 1.5 — 实现与人工审核记录

日期：2026-10-22（Australia/Sydney）。负责人：MTRX3700 ECHO-7 学生团队；具体姓名待团队填写。代码和测试由 OpenAI Codex 辅助编写，工程决策和最终验收由人工负责。

**工程范围**

实际修改目录为 `C:\Quartus_Projects\Majortut\ECHOPHACE1`，Quartus 工程/Revision 为 `Camera`，顶层为 `top_level`，器件为 `5CSEMA5F31C6`。本轮按最新指示直接修改源文件，没有新增源码备份、安装软件、Git commit/push 或编程开发板。旧工程没有修改。

初始检查确认 `rtl/`、`rtl/echo7/`、`tb/echo7/`、`tools/echo7/`、`quartus/Camera.qpf/.qsf/.sdc` 存在。保留原有 Phase 1 三种算法的判据及参数。

**新增和修改的文件**

| 文件 | 用途 |
|---|---|
| `rtl/echo7/echo7_diag_pkg.sv` | 统计/显示记录类型、帧末十进制转换 |
| `rtl/echo7/colourRegionStats.sv` | 每色一个聚合框、面积、原始 RGB 累加、帧有效性 |
| `rtl/echo7/unsignedDivider.sv` | 27 位共享迭代无符号除法 |
| `rtl/echo7/colourMeanHsv.sv` | 帧末平均 RGB、HSV、十进制数字和帧标识 |
| `rtl/echo7/diagnosticFont.sv` | 原创 5×7 字模的可综合常量表 |
| `rtl/echo7/diagnosticRenderer.sv` | 绿色边框、两倍字号、标签避让和边界限制 |
| `rtl/echo7/colourDiagnostics.sv` | 统计/绘制集成、原有 Mask 层、帧末等待与快照 |
| `tb/echo7/echo7_diag_ref_pkg.sv` | 独立的整数参考计算、文字和图像期望值 |
| `tb/echo7/unsignedDivider_tb.sv` | 除法器自检 |
| `tb/echo7/colourMeanHsv_tb.sv` | 均值、HSV、BCD、随机输入、Reset 自检 |
| `tb/echo7/colourRegionStats_tb.sv` | 形状、移动、噪声、边缘、满帧计数和包异常自检 |
| `tb/echo7/diagnosticRenderer_tb.sv` | 字模、数字、框、标签避让和完整光栅自检 |
| `tb/echo7/colourDiagnostics_protocol_tb.sv` | 无效数据、帧末等待、Reset、算法快照隔离自检 |
| `tb/echo7/echo7_diagnostics_tb.sv` | Frame Buffer → VGA 的十帧逐像素集成自检 |
| `rtl/echo7/segmentationSelector.sv`（修改） | 增加与像素同步的 `out_mode` 标签 |
| `rtl/top_level.sv`（修改） | Selector 接入 Diagnostics，保持原有 Camera 链路 |
| `quartus/Camera.qsf`（修改） | 添加七个新 RTL 文件；Package 在使用者之前 |
| `tools/echo7/run_tests.py`（修改） | 新测试列表、可选 ModelSim 后端、单项选择和日志 |
| `simulate.sh`（修改） | 为原有系统回归补充新模块源文件列表 |
| `OWNERS.md`、`AI_STATEMENT.md`（修改）及本文件（新增） | 归属、AI 来源、结果和限制 |

Quartus 编译会更新 `quartus/db`、`quartus/incremental_db`、`quartus/output_files`；仿真产物放在 `work/echo7_tests`。这些是工具输出，不是新增 Frame Buffer。Camera 配置/采集、`camera_pkg`、`frame_buffer`、`camera_display`、PLL 源码和 UART/IR/机器人控制未修改。

**数据流、坐标和时间关系**

```text
OV7670 --PCLK--> ov7670_capture --> frame_buffer (320×240 RGB565, 单缓冲)
                                           |
                                         clk_25
                                           v
camera_display (640×480, x/2、y/2 读取，RGB8+2 / RGB8+2 / RGB8+2)
    --> segmentationSelector (原像素 + Mask + 帧锁存开关 + mode)
    --> colourDiagnostics --> 原有 vgaMaskOverlay 弹性寄存器 --> vga_sink --> VGA
           |       ^
           |       +-- 上一显示帧的框、均值和字体
           +-- colourRegionStats --> colourMeanHsv --> 下一 SOP 原子锁存
```

所有新增 RTL 使用 `clk_25`，同步高有效 `reset25`。只有 `valid && ready` 的像素被统计和推进坐标。无效拍和背压不会重复计数。原像素、Mask、SOP/EOP 在同一次握手中处理。

统计发生在纯红/纯蓝覆盖之前。面积以 **640×480 显示像素**计数；稳定画面下，一个 320×240 存储像素贡献四个显示像素。坐标直接对应 VGA 光栅，不再对框进行二次放大。

EOP 被接收后，暂停接收下一帧，完成两种颜色的计算。原有输出寄存器仍可交付最后一个像素。结果齐备后才允许下一 SOP，并把框、RGB、HSV、数字和帧标识一起锁存。第一帧不画框；下一帧使用前一显示帧的统计，具有一帧延迟（25 MHz、800×525 时约 16.8 ms）。模式不同的旧统计被隐藏，新算法的首帧只有当前 Mask；后续帧显示新算法的框和数值。

`frame_id` 为 16 位显示统计序号，模 65536 回绕；没有用于跨时钟同步。双颜色有效时实测边界等待为 296 个时钟，测试约束为不超过 310 个时钟（12.4 µs）。现有 IP 的消隐为 45×800=36000 个时钟；边界等待不进入正常显示帧的有效像素时段。初次上电锁定与实际 DAC/显示器仍需上板确认。

| 模块 | 时钟/Reset/使能与延迟 |
|---|---|
| `colourRegionStats` | clk_25、同步高有效 Reset；CE 与 valid 同时为 1 时接收；EOP 接收沿发布含最后像素的快照和一拍 done |
| `unsignedDivider` | clk_25、同步高有效 Reset；idle 时接受 start，运行中不受像素 CE 影响；27 次迭代后给出商 |
| `colourMeanHsv` | clk_25、同步高有效 Reset；frame_done 启动；在像素暂停期间继续计算；两色结果齐备才给 done |
| `diagnosticFont`、`diagnosticRenderer` | 纯组合逻辑，无时钟/Reset/CE；由后续弹性寄存器保持稳定输出 |
| `colourDiagnostics` | clk_25、同步高有效 Reset；使用 ready/valid；含原有一拍 Mask 输出寄存器，帧间另有短暂计算等待 |
| `segmentationSelector`（保留） | 三拍共同 CE 流水；Fixed/Ratio 原为一拍，补两拍对齐 HSV；开关同步独立于 CE 运行 |

正常帧内总像素流水仍为 Selector 三拍加 Mask 输出一拍；吞吐为每时钟一个像素。帧间等待和下游背压会延长实际经过的时钟数。

**区域算法和计数范围**

每帧 SOP 清空累计量。每个红/蓝 Mask 像素更新该色 xmin/xmax/ymin/ymax、area 和 sum_R/G/B。EOP 的最后一个像素包含在结果中。`MIN_AREA` 默认 32，在 `top_level.sv` 的 Diagnostics 实例中可配置。

输出的 `red_xmin`、`red_xmax`、`red_ymin`、`red_ymax`、`red_area`、`red_valid` 及对应蓝色信号位于 `colourRegionStats`；它们是已完成帧的结果，不是累计到半帧的结果。`colourDiagnostics.display_red/display_blue` 是当前绘图帧使用的完整快照。

满屏面积 307200，19 位面积计数足够；每通道最大累加 78336000，27 位足够。计数达到配置的最大帧面积后饱和并置溢出标志，溢出结果不显示。提前 EOP、末像素缺 EOP、帧内 mode 改变均使结果无效；新的 SOP 重新开始统计。Reset 清除在途统计和显示快照。

这是每色一个**聚合 Bounding Box**。多个同色物体会合并成一个大框；不是连通域、独立多目标或物体跟踪。最小总面积能过滤总量很少的噪声，不能排除累计超过阈值的分散噪点。

**Detected-pixel Mean 与 HSV 规则**

屏幕数值明确解释为 **Detected-pixel Mean（通过当前分类阈值的像素均值）**，不是整个物体的真实平均颜色。先对命中像素求 RGB 均值，再由这个平均 RGB 求 HSV；不是逐像素 HSV 的平均。

RGB565 的展开复用原有位复制：R/B 为 `{5bit, top3bit}`，G 为 `{6bit, top2bit}`。显示路径保持原有 30 位格式，每通道低两位为零。

`mean = floor((sum + floor(area/2)) / area)`，四舍五入且恰好一半时向上，输出饱和到 0..255。area=0 时区域无效，不做有效除法。

由平均 RGB 求 `V=max(R,G,B)`、`d=max-min`，`S=round(255*d/V)`。V=0 时 S=0；d=0 时 H=0。Hue 使用标准六扇区的有符号整数分子，先归一化到 `[0,360*d)`，再除以 d 并四舍五入；舍入到 360 时映射回 0。H 为 0..359°，S/V 为 0..255。低饱和度仍有确定输出，灰度 H=0；这种 H 不代表可辨识的实际色相。

一个 27 位 restoring divider 共享执行两色各三次 RGB 均值、一次 Hue 和一次 Saturation。每次 27 次迭代，每拍一个移位/减法；逐像素路径没有新增除法或浮点运算。字体地址中的 `/12`、`%12` 为编译期常数除数。数字 BCD 在帧末计算，不在逐像素路径反复求十进制。

**绘制与开关**

边框为一像素宽纯绿色。22 字符标签使用 5×7 字模放大两倍，占 264×16 像素，白字黑底，格式为 `RED  R:211 G:062 B:057` 或 `BLUE H:238 S:185 V:194`。这些仅为格式示例，RTL 数字均来自统计结果。

标签通常放在框下两像素处；底部空间不足时放到框上方，仍不足时放到屏内底部。水平起点限制到 0..376。标签相撞时移动 BLUE 标签到 RED 标签旁的空闲文字行；因此边缘/重叠时不保证文字仍在原框下方。文字优先于穿过它的边框，两框交叉处仍为绿色，两个标签不互相覆盖。

| 开关 | 行为 |
|---|---|
| SW[2:1]=00 | Fixed RGB；显示 RGB 均值 |
| SW[2:1]=01 | RGB Ratio；显示 RGB 均值 |
| SW[2:1]=10 | HSV；显示由平均 RGB 计算的 HSV |
| SW[2:1]=11 | 保留模式，安全回退 Fixed RGB；显示 RGB 均值 |
| SW3=0 | 原始视频；统计仍运行 |
| SW3=1 | 当前 Mask + 上一帧绿色框 + 对应数值 |
| SW0 | 保留，无本阶段功能 |
| KEY0 | 原有系统复位与摄像头重新配置 |

开关继续经过两级同步、10 ms 稳定资格检查，并在接收 SOP 时锁存。没有新增控制开关，也没有改变 SW0 的用途。

**验证与重跑**

首选命令：`python tools/echo7/run_tests.py --regression`（需要预先安装可用的 Verilator 5.050）。当前环境找不到 Verilator，记录为 NOT_RUN，没有安装软件。

本轮使用已有的 ModelSim ALTERA STARTER EDITION 10.5b 执行 RTL 自检：

```powershell
python tools/echo7/run_tests.py --simulator modelsim --modelsim-bin C:\intelFPGA_lite\18.1\modelsim_ase\win32aloem --regression
```

ModelSim 在本环境的沙箱内启动失败，获准在沙箱外运行后可正常使用。每次运行创建独立的工作目录，不删除以前日志。首轮文本参考曾因 ModelSim `%03d` 空格补位而失败；已改为显式生成前导零后重跑，失败日志仍保留。

十项 ECHO-7 测试包含：三种原有算法、Mask、Selector、原有 Frame Buffer 集成、除法器、均值/HSV、区域统计、字模/绘制、Diagnostics 协议和新的十帧全路径自检。最终各项结果、对应日志及 Quartus 指标见 `work/phase15/verification.json`。Python 65536 输入数学检查也已 PASS，它独立于 RTL 仿真。

| 实际运行的 ModelSim Testbench | 最终结果 |
|---|---|
| `echo7_algorithms_tb` | PASS |
| `vgaMaskOverlay_tb` | PASS |
| `echo7_stream_tb` | PASS |
| `echo7_integration_tb` | PASS |
| `unsignedDivider_tb` | PASS |
| `colourMeanHsv_tb` | PASS |
| `colourRegionStats_tb` | PASS |
| `diagnosticRenderer_tb` | PASS |
| `colourDiagnostics_protocol_tb` | PASS |
| `echo7_diagnostics_tb` | PASS |
| `ov7670_capture_tb` | PASS |
| `frame_buffer_tb` | PASS |
| `camera_display_tb` | PASS |
| `camera_system_tb` | PASS |

全部 14 项通过。全系统测试在摄像头模型配置完成后检查四帧，共完成八帧显示，VGA/SCCB 无协议错误。新集成测试逐像素比对十帧；前四帧使用自由运行的 800×525 时序检测有效区欠载，后续增加随机背压。软件测试不能确认实际摄像头的曝光、白平衡或光照阈值。

Quartus 使用已安装的 Prime Lite 18.1 执行 `quartus_sh --flow compile Camera`。最终报告位于 `quartus/output_files/Camera.fit.summary`、`Camera.sta.summary`、`Camera.sta.rpt`，最终编译日志位于 `work/phase15/quartus-final.log`。综合/布局布线/时序结果不等于开发板测试通过。

| 最终 Quartus 指标 | 结果 |
|---|---|
| 完整编译 | 成功；0 errors、86 warnings、0 critical warnings |
| ALM | 2178 / 32070（7%） |
| 寄存器 | 2093 |
| RAM | 152 / 397 blocks；1228800 bits，与原单帧缓存容量一致 |
| DSP | 7 / 87 |
| 显示域最差报告 Fmax | 30.10 MHz（当前使用 25 MHz） |
| 显示域最差 setup slack | +6.778 ns |
| 全部时钟/角落最差 setup slack | +5.608 ns |
| 全部时钟/角落最差 hold slack | +0.158 ns |
| 报告的 setup/hold/minimum pulse-width slack | 全部非负；TNS=0 |

警告包括原有 PLL Reset 连接、未使用输入/端口、部分 I/O 约束及工具配置提示；没有为消除这些警告修改无关 Camera 代码。`work/phase15/protected-source-check.json` 记录 13 个受保护文件与修改前记录的哈希一致。最终 .sof 的 SHA-256 和源文件哈希记录在 `verification.json`，便于人工确认下载版本。

**人工审核和上板步骤**

1. 审查本文、RTL、测试日志和最终时序，确认具名学生负责人。先在课程 Verilator 5.050 环境重跑，记录与 ModelSim 的差异。
2. 打开本目录 `quartus/Camera.qpf`，确认 Revision 为 Camera、顶层 top_level 和新增源文件列表；核对最终 .sof 的生成时间与报告。按实验室流程使用 Programmer 下载到正确的 FPGA 设备。
3. SW3=0、SW[2:1]=00，按 KEY0，确认原有实时画面、LEDR0/1 配置状态、画面方向与同步正常。
4. SW3=1，放入一个红色和一个蓝色物体。检查纯色 Mask 随形状变化，绿色框覆盖命中像素范围，RGB 数值随实际照明/物体变化。
5. 移动并缩小目标，确认下一帧框跟随；移除目标后下一帧应隐藏框/数值。靠近四边及角落，检查裁剪；让两个标签靠近，检查避让。
6. 放入两个同色物体，确认一个聚合框包含二者，并记录这是一版限制。检查小面积噪声和光照误检，校准颜色阈值及 MIN_AREA。
7. 依次切换 00/01/10/11，验证整帧切换；HSV 模式观察红色绕 0°、蓝色约 240°，以及低饱和度目标是否被算法拒绝。数值因传感器白平衡、曝光、阈值和均值取样而变化，不要求固定示例值。
8. 切回 SW3=0，确认原画面恢复；拨动 SW0 确认本阶段没有作用。反复切换并 Reset，记录是否出现黑屏、错位、闪框或掉帧。

未完成的验证是课程指定 Verilator 版本和真实 DE1-SoC 上板测试。现有单缓冲可发生撕裂，统计帧是显示器实际读取的像素流，不保证对应一个完整传感器帧。框的一帧延迟在快速移动时会产生落后。现有 VGA 输出 false-path 与相机输入时序假设沿用原工程；静态时序通过不替代外部接口测量。没有实现运动控制、UART、自动停靠、连通域、跟踪或 Bounding Box 平滑。
