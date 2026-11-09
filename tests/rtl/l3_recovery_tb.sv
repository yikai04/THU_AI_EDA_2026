`timescale 1ns/1ps
module l3_recovery_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    wire [31:0] imem_addr, dmem_addr, dmem_wdata;
    wire [3:0] dmem_be;
    wire imem_valid, dmem_valid, dmem_we;
    wire [31:0] exit_code, dbg_reg_data, dbg_retire_pc, dbg_retire_insn;
    wire halted, dbg_retire_valid, dbg_ooo_bypass;
    reg [4:0] dbg_reg_addr = 0;

    reg [31:0] program_words [0:31];
    reg [31:0] data_words [0:3];
    wire [31:0] imem_rdata = program_words[imem_addr[6:2]];
    wire [31:0] dmem_rdata = data_words[dmem_addr[3:2]];
    integer wait_cycles = 0;
    wire dmem_ready = dmem_valid && wait_cycles == 12;
    rv32i5 dut (
        .clk(clk), .rst_n(rst_n), .imem_addr(imem_addr),
        .imem_valid(imem_valid), .imem_ready(imem_valid), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_valid(dmem_valid), .dmem_ready(dmem_ready),
        .dmem_we(dmem_we), .dmem_wdata(dmem_wdata), .dmem_be(dmem_be),
        .dmem_rdata(dmem_rdata), .halted(halted), .exit_code(exit_code),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data),
        .dbg_retire_valid(dbg_retire_valid), .dbg_retire_pc(dbg_retire_pc),
        .dbg_retire_insn(dbg_retire_insn), .dbg_ooo_bypass(dbg_ooo_bypass)
    );

    integer expected_pc [0:12];
    integer retired = 0, writes = 0, bypasses = 0;
    reg full_seen = 0, wrong_ecall_seen = 0;
    always @(posedge clk) begin
        if (!rst_n || !dmem_valid || dmem_ready) wait_cycles <= 0;
        else wait_cycles <= wait_cycles + 1;
        if (rst_n) begin
            if (!dut.rob_ready) full_seen <= 1;
            if (dut.stop_fetch && dut.inst_pc == 32) wrong_ecall_seen <= 1;
            if (dbg_ooo_bypass && dmem_valid && !dmem_ready) bypasses <= bypasses + 1;
            if (dmem_valid && dmem_we && dmem_ready) begin
                if (dmem_addr !== 32'h101 || dmem_be !== 4'b0010 || dmem_wdata !== 32'h08080808)
                    $fatal(1, "wrong-path store or incorrect byte write");
                data_words[0][15:8] <= dmem_wdata[15:8];
                writes <= writes + 1;
            end
            if (dbg_retire_valid) begin
                if (retired >= 13 || dbg_retire_pc !== expected_pc[retired] ||
                    dbg_retire_insn !== program_words[dbg_retire_pc[6:2]])
                    $fatal(1, "unexpected retirement %0d at PC %h", retired, dbg_retire_pc);
                if (halted || exit_code !== 0) $fatal(1, "halt preceded ECALL retirement");
                retired <= retired + 1;
            end
        end
    end

    task check_reg(input [4:0] addr, input [31:0] expected);
        begin
            dbg_reg_addr = addr;
            #1;
            if (dbg_reg_data !== expected)
                $fatal(1, "x%0d: expected %h, got %h", addr, expected, dbg_reg_data);
        end
    endtask

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) program_words[i] = 32'h00000013;
        for (i = 0; i < 4; i = i + 1) data_words[i] = 0;
        data_words[0] = 1;
        program_words[0] = 32'h10000113; // addi x2,x0,256
        program_words[1] = 32'h00012083; // lw x1,0(x2), delayed miss
        program_words[2] = 32'h00508493; // addi x9,x1,5, older than the branch
        program_words[3] = 32'h02009263; // bne x1,x0,48, held by load RAW
        program_words[4] = 32'h06300493; // wrong-path WAW x9
        program_words[5] = 32'h00912223; // wrong-path store
        program_words[6] = 32'h06300293; // wrong-path destination
        program_words[7] = 32'h06300313; // wrong-path destination
        program_words[8] = 32'h00000073; // wrong-path ECALL fills last ROB slot
        program_words[12] = 32'h00700293; // addi x5,x0,7
        program_words[13] = 32'h00012303; // lw x6,0(x2), hit
        program_words[14] = 32'h005303b3; // add x7,x6,x5, uses older x5
        program_words[15] = 32'h00900293; // addi x5,x0,9, younger WAR
        program_words[16] = 32'h007100a3; // sb x7,1(x2)
        program_words[17] = 32'h00015503; // lhu x10,0(x2)
        program_words[18] = 32'h008005ef; // jal x11,80, keep the redirect's own link
        program_words[19] = 32'h00000073; // wrong-path ECALL
        program_words[20] = 32'h00158613; // addi x12,x11,1
        program_words[21] = 32'h00000073; // correct ECALL
        expected_pc[0] = 0;
        expected_pc[1] = 4;
        expected_pc[2] = 8;
        expected_pc[3] = 12;
        expected_pc[4] = 48;
        expected_pc[5] = 52;
        expected_pc[6] = 56;
        expected_pc[7] = 60;
        expected_pc[8] = 64;
        expected_pc[9] = 68;
        expected_pc[10] = 72;
        expected_pc[11] = 80;
        expected_pc[12] = 84;
        repeat (3) @(negedge clk);
        rst_n = 1;
        wait (halted === 1);
        @(negedge clk);
        if (!full_seen || !wrong_ecall_seen || bypasses == 0 || retired != 13 || writes != 1)
            $fatal(1, "missing pressure/recovery coverage: full=%b wrong_ecall=%b bypass=%0d retire=%0d stores=%0d",
                   full_seen, wrong_ecall_seen, bypasses, retired, writes);
        if (data_words[0] !== 32'h801 || exit_code !== 32'h801)
            $fatal(1, "incorrect byte merge or exit code");
        check_reg(0, 0);
        check_reg(5, 9);
        check_reg(7, 8);
        check_reg(9, 6);
        check_reg(11, 76);
        check_reg(12, 77);
        $display("L3_RECOVERY: PASS retired=%0d stores=%0d miss_overlap=%0d", retired, writes, bypasses);
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "L3 recovery test timed out");
    end
endmodule
