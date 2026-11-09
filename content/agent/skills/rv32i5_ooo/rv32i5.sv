module rv32i5 (
    input logic clk,
    input logic rst_n,
    output logic [31:0] imem_addr,
    input logic [31:0] imem_rdata,
    output logic imem_valid,
    input logic imem_ready,
    output logic dmem_valid,
    output logic dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0] dmem_be,
    input logic [31:0] dmem_rdata,
    input logic dmem_ready,
    input logic [4:0] dbg_reg_addr,
    output logic [31:0] dbg_reg_data,
    output logic halted,
    output logic [31:0] exit_code,
    output logic [2:0] dbg_features,
    output logic dbg_retire_valid,
    output logic [31:0] dbg_retire_pc,
    output logic [31:0] dbg_retire_insn,
    output logic dbg_bp_resolve,
    output logic dbg_bp_mispredict,
    output logic dbg_ooo_issue,
    output logic dbg_ooo_bypass
);
    logic halt_pending, halt_after_retire, retired;
    logic ic_req_valid, ic_req_ready, ic_resp_valid;
    logic [1:0] epoch;
    logic [31:0] fetch_pc, prediction, ic_word;
    logic inst_valid;
    logic [31:0] inst_pc, inst_word, inst_prediction;

    logic rob_ready, rename_ready, head_done;
    logic [2:0] head_id, dispatch_id;
    logic [31:0] head_pc, head_insn, committed_x10;
    logic [5:0] ps1, ps2, new_pr, old_pr, head_pr, head_old_pr;
    logic [7:0] discard;
    logic [39:0] pr_ready;
    logic iq_valid, issue_control;
    logic [2:0] issue_id;
    logic [31:0] issue_pc, issue_insn, issue_prediction;
    logic [5:0] issue_ps1, issue_ps2, issue_pr;
    logic [31:0] int_a, int_b, int_value, branch_target;
    logic taken;
    logic dc_req_valid, dc_req_ready, dc_req_we, dc_resp_valid, waiting_load, mem_done;
    logic [31:0] dc_addr, dc_wdata, dc_rdata, mem_a, mem_b, mem_value;
    logic [3:0] dc_be;
    logic [2:0] mem_id;
    logic [5:0] mem_pr, mem_src_a, mem_src_b;

    wire [6:0] op = inst_word[6:0];
    wire is_memory = op == 7'h03 || op == 7'h23;
    wire is_control = op == 7'h63 || op == 7'h67 || op == 7'h6f;
    wire is_ecall = inst_word == 32'h00000073;
    wire uses_a = is_memory || op == 7'h63 || op == 7'h67 || op == 7'h13 || op == 7'h33;
    wire uses_b = op == 7'h23 || op == 7'h63 || op == 7'h33;
    wire writes_rd = op == 7'h03 || op == 7'h13 || op == 7'h33 ||
                     op == 7'h17 || op == 7'h37 || op == 7'h67 || op == 7'h6f;
    wire [4:0] rs1 = uses_a ? inst_word[19:15] : 5'd0;
    wire [4:0] rs2 = uses_b ? inst_word[24:20] : 5'd0;
    wire [4:0] rd = writes_rd ? inst_word[11:7] : 5'd0;
    wire active = rst_n && !halted && !halt_after_retire;
    wire mem_issue = dc_req_valid && dc_req_ready;
    wire int_ready = active && !mem_issue;
    wire int_done = iq_valid && int_ready;
    wire resolve = int_done && issue_control;
    wire [31:0] actual_pc = taken ? branch_target : issue_pc + 32'd4;
    wire squash = resolve && actual_pc != issue_prediction;
    wire dispatch = active && !halt_pending && !squash && inst_valid && rob_ready && rename_ready;
    wire stop_fetch = dispatch && is_ecall;
    wire flush_fetch = squash || stop_fetch;
    wire head_ecall = head_insn == 32'h00000073;
    wire retire = active && head_done && (!head_ecall || !imem_valid);

    assign dbg_features = 3'b111;
    assign dbg_retire_valid = rst_n && !halted && retired;
    assign dbg_bp_resolve = resolve;
    assign dbg_bp_mispredict = squash;
    assign dbg_ooo_issue = active && (int_done || mem_issue);
    assign dbg_ooo_bypass = int_done && !issue_control && issue_insn[6:0] != 7'h73 &&
                            waiting_load && dmem_valid && !dmem_we;

    fetch_unit fetch (
        .clk(clk), .rst_n(rst_n), .stop(!active || halt_pending),
        .flush(flush_fetch), .redirect(squash), .target_pc(actual_pc),
        .epoch(epoch), .req_pc(fetch_pc), .predicted_pc(prediction),
        .req_valid(ic_req_valid), .req_ready(ic_req_ready),
        .resp_valid(ic_resp_valid), .resp_insn(ic_word),
        .inst_valid(inst_valid), .inst_pc(inst_pc), .inst_prediction(inst_prediction),
        .inst_word(inst_word), .dispatch(dispatch)
    );
    icache i_cache (
        .clk(clk), .rst_n(rst_n), .flush(flush_fetch), .flush_epoch(epoch),
        .cpu_req_valid(ic_req_valid), .cpu_req_addr(fetch_pc), .cpu_req_ready(ic_req_ready),
        .cpu_resp_valid(ic_resp_valid), .cpu_resp_data(ic_word),
        .mem_req_valid(imem_valid), .mem_req_addr(imem_addr),
        .mem_req_ready(imem_ready), .mem_resp_valid(imem_ready), .mem_resp_data(imem_rdata)
    );
    branch_predictor predictor (
        .clk(clk), .rst_n(rst_n), .fetch_pc(fetch_pc), .predicted_pc(prediction),
        .resolve(resolve), .resolve_pc(issue_pc), .target(branch_target),
        .kind(issue_insn[6:0] == 7'h63 ? 2'd0 : issue_insn[3] ? 2'd1 : 2'd2),
        .taken(taken)
    );

    reorder_buffer rob (
        .clk(clk), .rst_n(rst_n), .dispatch(dispatch),
        .dispatch_pc(inst_pc), .dispatch_insn(inst_word), .new_pr(new_pr), .old_pr(old_pr),
        .ready(rob_ready), .dispatch_id(dispatch_id),
        .int_done(int_done), .int_id(issue_id), .mem_done(mem_done), .mem_id(mem_id),
        .squash(squash), .branch_id(issue_id), .discard(discard),
        .head_id(head_id), .head_done(head_done), .head_pc(head_pc), .head_insn(head_insn),
        .head_pr(head_pr), .head_old_pr(head_old_pr), .retire(retire)
    );
    rename_unit rename (
        .clk(clk), .rst_n(rst_n), .dispatch(dispatch), .control_transfer(is_control),
        .dispatch_id(dispatch_id), .rs1(rs1), .rs2(rs2), .rd(rd),
        .available(rename_ready), .ps1(ps1), .ps2(ps2), .new_pr(new_pr), .old_pr(old_pr),
        .squash(squash), .branch_id(issue_id), .retire(retire),
        .retire_rd(head_insn[11:7]), .retire_pr(head_pr), .retire_old_pr(head_old_pr),
        .int_done(int_done), .int_pr(issue_pr), .int_value(int_value),
        .mem_done(mem_done), .mem_pr(mem_pr), .mem_value(mem_value), .ready(pr_ready),
        .int_src_a(issue_ps1), .int_src_b(issue_ps2), .mem_src_a(mem_src_a), .mem_src_b(mem_src_b),
        .int_a(int_a), .int_b(int_b), .mem_a(mem_a), .mem_b(mem_b),
        .dbg_addr(dbg_reg_addr), .dbg_data(dbg_reg_data), .committed_x10(committed_x10)
    );
    issue_queue iq (
        .clk(clk), .rst_n(rst_n), .dispatch(dispatch && !is_memory),
        .dispatch_id(dispatch_id), .dispatch_pc(inst_pc), .dispatch_insn(inst_word),
        .dispatch_prediction(inst_prediction), .ps1(ps1), .ps2(ps2), .new_pr(new_pr),
        .dispatch_control(is_control), .discard(discard), .head_id(head_id), .ready(pr_ready),
        .issue_ready(int_ready), .issue_valid(iq_valid), .issue_id(issue_id),
        .issue_pc(issue_pc), .issue_insn(issue_insn), .issue_prediction(issue_prediction),
        .issue_ps1(issue_ps1), .issue_ps2(issue_ps2), .issue_pr(issue_pr), .issue_control(issue_control)
    );
    execute_unit execute (
        .insn(issue_insn), .pc(issue_pc), .a(int_a), .b(int_b),
        .result(int_value), .target(branch_target), .taken(taken)
    );
    load_store_unit lsu (
        .clk(clk), .rst_n(rst_n), .dispatch(dispatch && is_memory),
        .dispatch_id(dispatch_id), .dispatch_insn(inst_word), .ps1(ps1), .ps2(ps2), .new_pr(new_pr),
        .discard(discard), .head_id(head_id), .ready(pr_ready),
        .mem_src_a(mem_src_a), .mem_src_b(mem_src_b), .a(mem_a), .b(mem_b),
        .req_valid(dc_req_valid), .req_ready(dc_req_ready), .req_we(dc_req_we), .req_addr(dc_addr),
        .req_wdata(dc_wdata), .req_be(dc_be), .resp_valid(dc_resp_valid), .resp_rdata(dc_rdata),
        .waiting_load(waiting_load), .complete(mem_done), .complete_id(mem_id),
        .complete_pr(mem_pr), .complete_value(mem_value)
    );
    // A D request belongs to the ROB head and cannot be younger than a redirect.
    dcache d_cache (
        .clk(clk), .rst_n(rst_n), .flush(1'b0), .flush_epoch(2'b0),
        .cpu_req_valid(dc_req_valid), .cpu_req_we(dc_req_we), .cpu_req_addr(dc_addr),
        .cpu_req_wdata(dc_wdata), .cpu_req_be(dc_be), .cpu_req_ready(dc_req_ready),
        .cpu_resp_valid(dc_resp_valid), .cpu_resp_rdata(dc_rdata),
        .mem_req_valid(dmem_valid), .mem_req_we(dmem_we), .mem_req_addr(dmem_addr),
        .mem_req_wdata(dmem_wdata), .mem_req_be(dmem_be), .mem_req_ready(dmem_ready),
        .mem_resp_valid(dmem_ready), .mem_resp_data(dmem_rdata)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            halt_pending <= 0;
            halt_after_retire <= 0;
            halted <= 0;
            exit_code <= 0;
            retired <= 0;
        end else begin
            retired <= retire;
            if (squash) halt_pending <= 0;
            else if (stop_fetch) halt_pending <= 1;
            if (retire) begin
                dbg_retire_pc <= head_pc;
                dbg_retire_insn <= head_insn;
                halt_after_retire <= head_ecall;
            end
            if (halt_after_retire) begin
                halted <= 1;
                exit_code <= committed_x10;
            end
        end
    end
endmodule
