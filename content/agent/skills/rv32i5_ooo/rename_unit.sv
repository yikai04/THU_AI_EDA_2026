module rename_unit (
    input logic clk,
    input logic rst_n,
    input logic dispatch,
    input logic control_transfer,
    input logic [2:0] dispatch_id,
    input logic [4:0] rs1,
    input logic [4:0] rs2,
    input logic [4:0] rd,
    output logic available,
    output logic [5:0] ps1,
    output logic [5:0] ps2,
    output logic [5:0] new_pr,
    output logic [5:0] old_pr,
    input logic squash,
    input logic [2:0] branch_id,
    input logic retire,
    input logic [4:0] retire_rd,
    input logic [5:0] retire_pr,
    input logic [5:0] retire_old_pr,
    input logic int_done,
    input logic [5:0] int_pr,
    input logic [31:0] int_value,
    input logic mem_done,
    input logic [5:0] mem_pr,
    input logic [31:0] mem_value,
    output logic [39:0] ready,
    input logic [5:0] int_src_a,
    input logic [5:0] int_src_b,
    input logic [5:0] mem_src_a,
    input logic [5:0] mem_src_b,
    output logic [31:0] int_a,
    output logic [31:0] int_b,
    output logic [31:0] mem_a,
    output logic [31:0] mem_b,
    input logic [4:0] dbg_addr,
    output logic [31:0] dbg_data,
    output logic [31:0] committed_x10
);
    logic [5:0] rat [0:31], committed [0:31];
    logic [31:0] values [0:39];
    logic [5:0] free_list [0:7];
    logic [3:0] free_head, free_tail;
    logic [191:0] checkpoints [0:7];
    logic [3:0] free_heads [0:7];
    wire allocate = dispatch && rd != 0;
    wire [3:0] saved_head = free_heads[branch_id];
    wire [3:0] rollback_count = free_head - saved_head;

    assign available = rd == 0 || free_head != free_tail;
    assign ps1 = rat[rs1];
    assign ps2 = rat[rs2];
    assign new_pr = rd == 0 ? 6'd0 : free_list[free_head[2:0]];
    assign old_pr = rat[rd];
    assign int_a = values[int_src_a];
    assign int_b = values[int_src_b];
    assign mem_a = values[mem_src_a];
    assign mem_b = values[mem_src_b];
    assign dbg_data = dbg_addr == 0 ? 32'd0 : values[committed[dbg_addr]];
    assign committed_x10 = values[committed[10]];

    logic [39:0] reclaim_mask;
    integer j;
    always @* begin
        reclaim_mask = 0;
        for (j = 0; j < 8; j = j + 1)
            if (j < rollback_count)
                reclaim_mask = reclaim_mask | (40'b1 << free_list[(saved_head + j) & 7]);
    end

    genvar physical;
    generate
        for (physical = 0; physical < 40; physical = physical + 1) begin : scoreboard
            localparam [5:0] PR = physical;
            always @(posedge clk) begin
                if (!rst_n) ready[physical] <= physical < 32;
                else if (squash && reclaim_mask[physical]) ready[physical] <= 0;
                else if (physical != 0 &&
                         ((int_done && int_pr == PR) || (mem_done && mem_pr == PR)))
                    ready[physical] <= 1;
                else if (!squash && allocate && new_pr == PR) ready[physical] <= 0;
            end
        end
    endgenerate

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            free_head <= 0;
            free_tail <= 8;
            for (i = 0; i < 32; i = i + 1) begin
                rat[i] <= i[5:0];
                committed[i] <= i[5:0];
            end
            for (i = 0; i < 40; i = i + 1) values[i] <= 0;
            for (i = 0; i < 8; i = i + 1) free_list[i] <= 6'd32 + i[5:0];
        end else begin
            if (int_done && int_pr != 0) values[int_pr] <= int_value;
            if (mem_done && mem_pr != 0) values[mem_pr] <= mem_value;
            if (retire && retire_pr != 0) begin
                committed[retire_rd] <= retire_pr;
                free_list[free_tail[2:0]] <= retire_old_pr;
                free_tail <= free_tail + 4'd1;
            end
            if (squash) begin
                // Rewind allocations only. Preserve tail advances from older commits.
                for (i = 0; i < 32; i = i + 1)
                    rat[i] <= checkpoints[branch_id][6*i +: 6];
                free_head <= saved_head;
            end else if (dispatch) begin
                if (allocate) begin
                    rat[rd] <= new_pr;
                    free_head <= free_head + 4'd1;
                end
                if (control_transfer) begin
                    // The branch itself survives recovery, including a JAL/R link.
                    for (i = 0; i < 32; i = i + 1)
                        checkpoints[dispatch_id][6*i +: 6] <=
                            allocate && rd == i[4:0] ? new_pr : rat[i];
                    free_heads[dispatch_id] <= free_head + {3'b0, allocate};
                end
            end
        end
    end
endmodule
