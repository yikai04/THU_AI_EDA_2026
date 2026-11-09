module reorder_buffer (
    input logic clk,
    input logic rst_n,
    input logic dispatch,
    input logic [31:0] dispatch_pc,
    input logic [31:0] dispatch_insn,
    input logic [5:0] new_pr,
    input logic [5:0] old_pr,
    output logic ready,
    output logic [2:0] dispatch_id,
    input logic int_done,
    input logic [2:0] int_id,
    input logic mem_done,
    input logic [2:0] mem_id,
    input logic squash,
    input logic [2:0] branch_id,
    output logic [7:0] discard,
    output logic [2:0] head_id,
    output logic head_done,
    output logic [31:0] head_pc,
    output logic [31:0] head_insn,
    output logic [5:0] head_pr,
    output logic [5:0] head_old_pr,
    input logic retire
);
    logic [3:0] head, tail;
    logic [7:0] completed;
    logic [31:0] pcs [0:7], insns [0:7];
    logic [5:0] dests [0:7], olds [0:7];
    wire [3:0] occupancy = tail - head;
    wire [2:0] branch_age = branch_id - head_id;

    assign ready = occupancy < 4'd8;
    assign dispatch_id = tail[2:0];
    assign head_id = head[2:0];
    assign head_done = occupancy != 0 && completed[head_id];
    assign head_pc = pcs[head_id];
    assign head_insn = insns[head_id];
    assign head_pr = dests[head_id];
    assign head_old_pr = olds[head_id];

    genvar slot;
    generate
        for (slot = 0; slot < 8; slot = slot + 1) begin : age_mask
            localparam [2:0] SLOT = slot;
            wire [2:0] age = SLOT - head_id;
            assign discard[slot] = squash && age > branch_age;
        end
    endgenerate

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            head <= 0;
            tail <= 0;
            completed <= 0;
        end else begin
            if (int_done) completed[int_id] <= 1;
            if (mem_done) completed[mem_id] <= 1;
            if (retire) begin
                completed[head_id] <= 0;
                head <= head + 4'd1;
            end
            if (squash) begin
                tail <= head + {1'b0, branch_age} + 4'd1;
                for (i = 0; i < 8; i = i + 1)
                    if (discard[i]) completed[i] <= 0;
            end else if (dispatch) begin
                completed[dispatch_id] <= 0;
                pcs[dispatch_id] <= dispatch_pc;
                insns[dispatch_id] <= dispatch_insn;
                dests[dispatch_id] <= new_pr;
                olds[dispatch_id] <= old_pr;
                tail <= tail + 4'd1;
            end
        end
    end
endmodule
