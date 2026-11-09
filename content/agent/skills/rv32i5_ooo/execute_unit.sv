module execute_unit (
    input logic [31:0] insn,
    input logic [31:0] pc,
    input logic [31:0] a,
    input logic [31:0] b,
    output logic [31:0] result,
    output logic [31:0] target,
    output logic taken
);

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [4:0] shamt;

    logic [31:0] imm_i;
    logic [31:0] imm_u;
    logic [31:0] imm_b;
    logic [31:0] imm_j;

    logic [31:0] result_op;
    logic [31:0] result_imm;
    logic [31:0] result_lui;
    logic [31:0] result_auipc;
    logic [31:0] result_jal;
    logic [31:0] result_jalr;
    logic [31:0] result_ecall;

    logic [31:0] target_branch;
    logic [31:0] target_jal;
    logic [31:0] target_jalr;

    logic taken_branch;
    logic taken_jal;
    logic taken_jalr;

    logic [31:0] sra_result;

    always @* begin
        opcode = insn[6:0];
        funct3 = insn[14:12];
        funct7 = insn[31:25];
        shamt  = insn[24:20];

        imm_i = {{20{insn[31]}}, insn[31:20]};
        imm_u = {insn[31:12], 12'b0};
        imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
        imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

        result_op    = 32'b0;
        result_imm   = 32'b0;
        result_lui   = 32'b0;
        result_auipc = 32'b0;
        result_jal   = 32'b0;
        result_jalr  = 32'b0;
        result_ecall = 32'b0;

        target_branch = pc + imm_b;
        target_jal    = pc + imm_j;
        target_jalr   = (a + imm_i) & 32'hFFFFFFFE;

        taken_branch = 1'b0;
        taken_jal    = 1'b0;
        taken_jalr   = 1'b0;

        sra_result = $signed(a) >>> shamt[4:0];

        case (opcode)
            7'b0110011: begin
                case (funct3)
                    3'b000: begin
                        if (funct7 == 7'b0100000)
                            result_op = a - b;
                        else
                            result_op = a + b;
                    end
                    3'b001: result_op = a << b[4:0];
                    3'b010: result_op = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
                    3'b011: result_op = (a < b) ? 32'd1 : 32'd0;
                    3'b100: result_op = a ^ b;
                    3'b101: begin
                        if (funct7 == 7'b0100000)
                            result_op = $signed(a) >>> b[4:0];
                        else
                            result_op = a >> b[4:0];
                    end
                    3'b110: result_op = a | b;
                    3'b111: result_op = a & b;
                    default: result_op = 32'b0;
                endcase
            end
            7'b0010011: begin
                case (funct3)
                    3'b000: result_imm = a + imm_i;
                    3'b001: result_imm = a << shamt[4:0];
                    3'b010: result_imm = ($signed(a) < $signed(imm_i)) ? 32'd1 : 32'd0;
                    3'b011: result_imm = (a < imm_i) ? 32'd1 : 32'd0;
                    3'b100: result_imm = a ^ imm_i;
                    3'b101: begin
                        if (funct7 == 7'b0100000)
                            result_imm = $signed(a) >>> shamt[4:0];
                        else
                            result_imm = a >> shamt[4:0];
                    end
                    3'b110: result_imm = a | imm_i;
                    3'b111: result_imm = a & imm_i;
                    default: result_imm = 32'b0;
                endcase
            end
            7'b0110111: result_lui = imm_u;
            7'b0010111: result_auipc = pc + imm_u;
            7'b1100011: begin
                case (funct3)
                    3'b000: taken_branch = (a == b);
                    3'b001: taken_branch = (a != b);
                    3'b100: taken_branch = ($signed(a) < $signed(b));
                    3'b101: taken_branch = ($signed(a) >= $signed(b));
                    3'b110: taken_branch = (a < b);
                    3'b111: taken_branch = (a >= b);
                    default: taken_branch = 1'b0;
                endcase
            end
            7'b1101111: begin
                taken_jal  = 1'b1;
                result_jal = pc + 32'd4;
            end
            7'b1100111: begin
                taken_jalr  = 1'b1;
                result_jalr = pc + 32'd4;
            end
            7'b1110011: result_ecall = 32'b0;
            default: begin
                result_op    = 32'b0;
                result_imm   = 32'b0;
                result_lui   = 32'b0;
                result_auipc = 32'b0;
                result_jal   = 32'b0;
                result_jalr  = 32'b0;
                result_ecall = 32'b0;
            end
        endcase

        result = 32'b0;
        target = pc + 32'd4;
        taken  = 1'b0;

        case (opcode)
            7'b0110011: result = result_op;
            7'b0010011: result = result_imm;
            7'b0110111: result = result_lui;
            7'b0010111: result = result_auipc;
            7'b1100011: begin
                taken  = taken_branch;
                target = target_branch;
            end
            7'b1101111: begin
                result = result_jal;
                taken  = taken_jal;
                target = target_jal;
            end
            7'b1100111: begin
                result = result_jalr;
                taken  = taken_jalr;
                target = target_jalr;
            end
            7'b1110011: result = result_ecall;
            default: begin
                result = 32'b0;
                target = pc + 32'd4;
                taken  = 1'b0;
            end
        endcase
    end

endmodule
