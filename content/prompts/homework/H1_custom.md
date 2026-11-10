你是一名专业的 ASIC/RTL 设计与验证工程师，精通 FIPS-197 AES-128、SystemVerilog、Icarus Verilog、Yosys 0.70，以及面积和功耗优化。

你的任务是修复并完成一个单模块 AES-128 加密核，确保它通过全部教师测试，然后在此基础上尽量降低芯片面积和功耗。

**重要：之前的实现已经在功能测试中失败。此次必须优先修复 AES 算法，而不是继续盲目优化面积。**

# 1. 已知失败信息

上一次生成的 RTL 有以下测试结果：

- reset：PASS
- ready/done 握手：PASS
- done 单周期脉冲：PASS
- ready 恢复：PASS
- 加密延迟：139 cycles，满足 200 cycles 上限
- AES 标准密文：全部 FAIL

错误详情：

Test 1:
key = 000102030405060708090a0b0c0d0e0f
plaintext = 00112233445566778899aabbccddeeff
actual = 60aa77d8db9fddbb78ece2260c45a18a
expected = 69c4e0d86a7b0430d8cdb78070b4c55a

Test 2:
key = 00000000000000000000000000000000
plaintext = 00000000000000000000000000000000
actual = 67269ee32a2b3b095e249393b813ce28
expected = 66e94bd4ef8a2c3b884cfa59ca342b2e

Test 3:
key = 2b7e151628aed2a6abf7158809cf4f3c
plaintext = 3243f6a8885a308d313198a2e0370734
actual = 283ca6265a7a57ab7312ce0af8e6c7a2
expected = 3925841d02dc09fbdc118597196a0b32

重复运行相同输入会得到相同的错误密文。

判断：握手和延迟基本正确，但 AES 计算逻辑存在确定性错误。不要仅因为最终输出可重复就认为算法正确。

# 2. 必须保留的接口

```systemverilog
module aes128 (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [127:0] key,
    input  logic [127:0] plaintext,
    output logic         ready,
    output logic         done,
    output logic [127:0] ciphertext
);
```

只能有一个 module，所有 AES 逻辑必须在其中实现。

不得实例化其他模块，不得使用 include、readmemh、DPI、外部 ROM 或 IP。

必须兼容：

- iverilog -g2012
- Yosys 0.70
- gscl45nm 标准单元库

函数返回值使用 Verilog-2005 风格的函数名赋值，不使用 SystemVerilog return。

# 3. 第一步：彻底排查 AES 字节排列

AES 数据是大端 128-bit 向量：

byte[i] = state[127-8*i -: 8]

状态矩阵为列优先：

state[r][c] = byte[4*c+r]

也就是说，128-bit 数据：

00112233445566778899aabbccddeeff

表示矩阵：

00 44 88 cc
11 55 99 dd
22 66 aa ee
33 77 bb ff

ShiftRows 后：

00 44 88 cc
55 99 dd 11
aa ee 22 66
ff 33 77 bb

对应 128-bit 输出：

0055aaff4499ee3388dd2277cc1166bb

必须确保所有中间状态继续采用同一列优先、大端顺序，不允许任意调换字节。

请重点检查：

1. 128-bit part-select 是否正确。
2. S-box 处理的第 i 个字节是否正确。
3. 状态寄存器的写回位置是否正确。
4. ShiftRows 是左移还是右移。
5. MixColumns 是否对同一列的连续四个字节操作。
6. 输出 ciphertext 是否保持 FIPS 字节排列。

# 4. 第二步：使用标准中间值逐轮验证

下面是 FIPS-197 C.1 标准测试向量对应的正确中间结果。

key:
000102030405060708090a0b0c0d0e0f

plaintext:
00112233445566778899aabbccddeeff

初始 AddRoundKey 后：

00102030405060708090a0b0c0d0e0f0

Round 1：

SubBytes:
63cab7040953d051cd60e0e7ba70e18c

ShiftRows:
6353e08c0960e104cd70b751bacad0e7

MixColumns:
5f72641557f5bc92f7be3b291db9f91a

Round 1 Key:
d6aa74fdd2af72fadaa678f1d6ab76fe

Round 1 AddRoundKey 后：
89d810e8855ace682d1843d8cb128fe4

Round 2 Key:
b692cf0b643dbdf1be9bc5006830b3fe

Round 2 AddRoundKey 后：
4915598f55e5d7a0daca94fa1f0a63f7

第 3–10 轮 AddRoundKey 后的正确状态依次为：

Round 3:
fa636a2825b339c940668a3157244d17

Round 4:
247240236966b3fa6ed2753288425b6c

Round 5:
c81677bc9b7ac93b25027992b0261996

Round 6:
c62fe109f75eedc3cc79395d84f9cf5d

Round 7:
d1876c0f79c4300ab45594add66ff41f

Round 8:
fde3bad205e5d0d73547964ef1fe37f1

Round 9:
bd6e7c3df2b5779e0b61216e8b10b689

Round 10:
69c4e0d86a7b0430d8cdb78070b4c55a

Round 10 Key:
13111d7fe3944a17f307a78b4d2b30c5

这些是正确性检查点。

如果可以运行仿真，必须使用独立调试 Testbench 或临时调试输出逐轮对比内部状态，不得修改教师 TB。

从最早出现错误的步骤开始定位，不要在没有明确原因的情况下随机修改 AES 算法。

最终提交 RTL 不要保留调试代码。

# 5. 第三步：重点检查密钥扩展

AES-128 每轮密钥是 128-bit。

输入 key 分成四个 32-bit 字：

w0 = key[127:96]
w1 = key[95:64]
w2 = key[63:32]
w3 = key[31:0]

当前轮密钥生成下一轮：

temp = SubWord(RotWord(w3)) XOR {Rcon, 24'h000000}

new_w0 = w0 XOR temp
new_w1 = w1 XOR new_w0
new_w2 = w2 XOR new_w1
new_w3 = w3 XOR new_w2

Rcon 序列：

01 02 04 08 10 20 40 80 1b 36

必须特别检查：

- RotWord 是将 32-bit 字左循环移动 8 bit。
- SubWord 对 RotWord 的四个字节分别调用标准 S-box。
- Rcon 只 XOR 到 32-bit 字的最高字节。
- 下一轮的 w1/w2/w3 依赖新生成的前一个字，不是旧值。
- 如果使用 nonblocking assignment，不允许意外读取旧的 new_w0、new_w1、new_w2。
- 第 r 轮必须使用第 r 轮密钥，而不是第 r-1 轮或第 r+1 轮密钥。

请优先采用明确的组合 next_key 计算，再在时钟沿统一更新密钥寄存器。

# 6. 第四步：检查 S-box 和 MixColumns

S-box 必须完整、准确实现标准 AES 256 项映射。

禁止使用不完整查表、错误 GF 逆元、多项式错误或近似实现。

请检查所有 256 个 S-box 输入对应的输出。

如有必要，重新实现完整的 256-entry case-based AES S-box。为了降低出错风险，优先保证查表正确性。

MixColumns 使用：

t = a0 XOR a1 XOR a2 XOR a3

b0 = a0 XOR t XOR xtime(a0 XOR a1)
b1 = a1 XOR t XOR xtime(a1 XOR a2)
b2 = a2 XOR t XOR xtime(a2 XOR a3)
b3 = a3 XOR t XOR xtime(a3 XOR a0)

其中：

xtime(x) = {x[6:0],1'b0} XOR (x[7] ? 8'h1b : 8'h00)

确认每个 xtime 输出和 XOR 运算都是严格的 8-bit GF(2^8) 运算。

最后一轮不得使用 MixColumns。

# 7. 第五步：重新设计可靠的低面积数据通路

优先采用：

**共享 S-box + 128-bit 状态寄存器 + 在线密钥扩展 + 迭代轮函数。**

但是这次必须避免为了共享资源而破坏 AES 数据依赖。

建议先评估两个结构：

方案 A：2 个 S-box

- 每周期进行 2 字节 SubBytes。
- 每轮使用 8 周期处理 16 字节。
- 密钥扩展复用 S-box，需要 2 周期。
- 后续执行 ShiftRows、MixColumns、AddRoundKey。
- 总延迟目标小于 150 周期。
- 更适合面积优化。

方案 B：4 个 S-box

- 每周期处理 4 字节。
- 每轮使用 4 周期处理数据 SubBytes。
- 密钥扩展可复用同一组 S-box。
- 轮计算延迟进一步降低。
- 结构较容易验证，但 S-box 面积可能较大。

优先实现方案 A；如果无法确保它正确，采用方案 B 作为可靠基线。

无论选择哪个方案，必须保证物理 S-box 资源确实共享。

不要在多个不同组合表达式中重复调用 sbox function 而无意生成额外并行 S-box。

不要把大规模纯组合 S-box 展开 16 份。

对于 2-S-box 架构，建议：

- 使用明确的 sbox_in0、sbox_in1。
- 使用 sbox_out0、sbox_out1。
- 根据 FSM 阶段选择输入。
- SubBytes 每周期处理两个固定位置的字节。
- 数据 S-box 输出只写回对应的数据状态字节。
- 密钥 S-box 输出只写入密钥扩展临时寄存器。
- 在一个完整轮完成前，不得开始使用下一轮数据。

特别警惕：

1. 数据状态被提前覆盖。
2. ShiftRows 处理的是未完成全部 SubBytes 的状态。
3. 密钥扩展还没完成就执行 AddRoundKey。
4. 计数器最后一个值对应的数据没有写回。
5. 同一时钟沿读取了尚未更新的寄存器。
6. 最后一轮和普通轮共用状态机时的 off-by-one 错误。

任何共享资源和流水时序都必须具有明确的数据有效性。

# 8. 面积和功耗优化

在全部功能测试通过后，再优化 PPA。

优化目标为课程 gscl45nm 标准单元库映射后的：

- chip area
- internal power
- switching power
- leakage power
- total power

优先考虑：

1. 2-S-box 共享，避免 S-box 组合逻辑复制。
2. 128-bit 轮密钥寄存器原位更新，避免存储全部 11 组轮密钥。
3. ShiftRows 固定布线重排。
4. MixColumns 复用 XOR 和 xtime 中间结果。
5. 状态寄存器仅在数据有效时更新。
6. 空闲时避免状态和密钥寄存器无意义翻转。
7. 避免过宽的动态多路选择器。
8. 简化轮数和字节索引计数器。
9. 保留单一 clk 时钟域，不使用组合门控时钟。
10. 避免使用大量中间寄存器换取有限的组合逻辑减少。

如果增加某种优化使功能失败，立即回退到最后一次功能通过的实现。

如果有综合评估工具，以真实面积和功耗结果决定是否保留优化，而不是凭 RTL 代码长度猜测。

# 9. 严格握手与时序

rst_n 是同步低有效复位，只允许在 clk 上升沿生效。

复位期间忽略 start。

ready=1 表示空闲，可以接收新的 start。

start && ready 在上升沿成立时，采样 key 和 plaintext。

计算期间 ready=0，忽略新的 start。

done 必须恰好持续一个周期，且 done=1 时：

- ready=0
- ciphertext 有效且稳定

done 后的下一个上升沿恢复 ready=1，并能立即接受下一次任务，不引入额外空闲气泡。

单次加密从 start 接收沿之后到 done 拉高沿，不超过 200 周期。

支持：

- 任意合法 key/plaintext
- 重复加密
- 连续不同 key 加密
- 忙碌期间同步复位
- 复位后重新启动

上一次设计的握手测试已经通过，因此在修改 RTL 时尽可能保留其正确的外部协议行为，但不要保留导致计算错误的内部结构。

# 10. 强制验证与修复流程

如果能访问测试工具，必须执行：

步骤 1：
实现或修复 RTL。

步骤 2：
运行 iverilog -g2012 功能仿真。

步骤 3：
检查三组公开 AES 向量。

步骤 4：
如发生密文不匹配，进行逐轮比对：

- 初始 AddRoundKey
- Round 1 SubBytes
- Round 1 ShiftRows
- Round 1 MixColumns
- Round 1 AddRoundKey
- Round 2 以及后续轮

定位第一处偏差并修正对应逻辑。

步骤 5：
重新验证全部公开向量、连续加密、重复加密、同步复位、忙时复位、ready/done 和 200 周期限制。

步骤 6：
确认全部通过后运行 Yosys 综合。

步骤 7：
若综合成功且功能正确，进一步进行面积/功耗优化，并重新执行功能验证。

步骤 8：
如果可以获得 test_report.json，必须确认 passed=true，并记录真实面积、功耗和延迟。

禁止修改教师 tb.sv、power_tb.sv 或综合脚本。

禁止通过硬编码测试向量或判断特定输入绕过 AES 算法。

禁止虚构测试结果。如果不能执行仿真，就通过明确的数据流和中间值对照进行静态检查，但不能宣称已经通过测试。

# 11. 最终输出格式

只输出完整的 SystemVerilog RTL 代码。

从：

module aes128 (

开始，到：

endmodule

结束。

不要输出 Markdown 代码围栏、解释、调试日志或伪代码。

代码必须直接符合教师模块接口并可用于 Icarus Verilog 与 Yosys。

最终要求：

**先通过全部 AES-128 功能测试，再最小化面积与功耗。绝对不能以错误的 AES 结果换取更小面积。**

请立即完成修复与实现，输出最终可提交的 aes128 模块源码。