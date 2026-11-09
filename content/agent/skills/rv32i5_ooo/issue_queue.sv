module issue_queue (
    input logic clk,
    input logic rst_n,
    input logic dispatch,
    input logic [2:0] dispatch_id,
    input logic [31:0] dispatch_pc,
    input logic [31:0] dispatch_insn,
    input logic [31:0] dispatch_prediction,
    input logic [5:0] ps1,
    input logic [5:0] ps2,
    input logic [5:0] new_pr,
    input logic dispatch_control,
    input logic [7:0] discard,
    input logic [2:0] head_id,
    input logic [39:0] ready,
    input logic issue_ready,
    output logic issue_valid,
    output logic [2:0] issue_id,
    output logic [31:0] issue_pc,
    output logic [31:0] issue_insn,
    output logic [31:0] issue_prediction,
    output logic [5:0] issue_ps1,
    output logic [5:0] issue_ps2,
    output logic [5:0] issue_pr,
    output logic issue_control
);
    logic [7:0] valid, control;
    logic [5:0] sources_a [0:7], sources_b [0:7], dests [0:7];
    logic [31:0] pcs [0:7], insns [0:7], predictions [0:7];

    wire [7:0] operands_ready;
    genvar entry;
    generate
        for (entry = 0; entry < 8; entry = entry + 1) begin : ready_check
            wire [5:0] a = sources_a[entry];
            wire [5:0] b = sources_b[entry];
            assign operands_ready[entry] = ready[a] && ready[b];
        end
    endgenerate

    always @* begin : select_ready
        integer j;
        reg seen_control;
        reg [2:0] slot;
        seen_control = 0;
        issue_valid = 0;
        issue_id = 0;
        for (j = 0; j < 8; j = j + 1) begin
            slot = head_id + j[2:0];
            if (valid[slot]) begin
                if (!issue_valid && (!control[slot] || !seen_control) && operands_ready[slot]) begin
                    issue_valid = 1;
                    issue_id = slot;
                end
                // Resolve branches in program order. Unrelated ALU ops can pass.
                seen_control = seen_control || control[slot];
            end
        end
    end
    assign issue_pc = pcs[issue_id];
    assign issue_insn = insns[issue_id];
    assign issue_prediction = predictions[issue_id];
    assign issue_ps1 = sources_a[issue_id];
    assign issue_ps2 = sources_b[issue_id];
    assign issue_pr = dests[issue_id];
    assign issue_control = control[issue_id];

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid <= 0;
        end else begin
            for (i = 0; i < 8; i = i + 1)
                if (discard[i] || (issue_valid && issue_ready && issue_id == i[2:0]))
                    valid[i] <= 0;
            if (dispatch) begin
                valid[dispatch_id] <= 1;
                control[dispatch_id] <= dispatch_control;
                pcs[dispatch_id] <= dispatch_pc;
                insns[dispatch_id] <= dispatch_insn;
                predictions[dispatch_id] <= dispatch_prediction;
                sources_a[dispatch_id] <= ps1;
                sources_b[dispatch_id] <= ps2;
                dests[dispatch_id] <= new_pr;
            end
        end
    end
endmodule
