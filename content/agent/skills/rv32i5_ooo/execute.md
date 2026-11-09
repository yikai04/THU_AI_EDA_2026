Implement exactly one combinational synthesizable SystemVerilog module in ANSI style. Output only the complete module. No dependencies, parameters, state, or extra ports. Use Verilog-2005-compatible RTL with explicit defaults and an always @* block. The interface is frozen:

module execute_unit (
    input logic [31:0] insn,
    input logic [31:0] pc,
    input logic [31:0] a,
    input logic [31:0] b,
    output logic [31:0] result,
    output logic [31:0] target,
    output logic taken
);

a and b are already renamed register operands. Decode RV32I opcode and funct3. For OP implement ADD SUB SLL SLT SLTU XOR SRL SRA OR AND. For OP-IMM implement ADDI SLLI SLTI SLTIU XORI SRLI SRAI ORI ANDI. R-type SLL/SRL/SRA use b[4:0], NEVER insn[24:20], which is the register index. Only I-type SLLI/SRLI/SRAI use insn[24:20]. Keep these amounts separate. SLTIU compares against a sign-extended immediate interpreted as unsigned. Use explicit signed arithmetic right shift in its own assignment, avoiding ternary signedness coercion. LUI returns U immediate; AUIPC returns pc + U immediate.
For BEQ BNE BLT BGE BLTU BGEU compute taken and target = pc + B immediate, even when not taken. JAL and JALR are taken and return pc+4 in result. JAL target = pc + J immediate, JALR target = (a + signed I immediate) with bit 0 cleared. Immediate bit positions are standard RV32I, with B and J immediates including the trailing zero. Non-control defaults are taken=0 and target=pc+4. ECALL returns result=0, taken=0, target=pc+4. No load/store work in this module. No simulation-only constructs.
