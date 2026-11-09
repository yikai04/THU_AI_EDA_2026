module load_store_unit (
    input logic clk,
    input logic rst_n,
    input logic dispatch,
    input logic [2:0] dispatch_id,
    input logic [31:0] dispatch_insn,
    input logic [5:0] ps1,
    input logic [5:0] ps2,
    input logic [5:0] new_pr,
    input logic [7:0] discard,
    input logic [2:0] head_id,
    input logic [39:0] ready,
    output logic [5:0] mem_src_a,
    output logic [5:0] mem_src_b,
    input logic [31:0] a,
    input logic [31:0] b,
    output logic req_valid,
    input logic req_ready,
    output logic req_we,
    output logic [31:0] req_addr,
    output logic [31:0] req_wdata,
    output logic [3:0] req_be,
    input logic resp_valid,
    input logic [31:0] resp_rdata,
    output logic waiting_load,
    output logic complete,
    output logic [2:0] complete_id,
    output logic [5:0] complete_pr,
    output logic [31:0] complete_value
);
    // One slot per ROB tag. The head-only issue rule prevents speculative
    // memory effects and keeps a request valid even across a younger redirect.
    logic [7:0] valid, stores;
    logic [5:0] sources_a [0:7], sources_b [0:7], dests [0:7];
    logic [11:0] offsets [0:7];
    logic [2:0] sizes [0:7], active_id;
    logic [1:0] active_lane;
    logic waiting;

    assign mem_src_a = sources_a[head_id];
    assign mem_src_b = sources_b[head_id];
    assign req_valid = rst_n && !waiting && valid[head_id] &&
                       ready[mem_src_a] && ready[mem_src_b];
    assign req_we = stores[head_id];
    assign req_addr = a + {{20{offsets[head_id][11]}}, offsets[head_id]};
    assign req_be = !req_we ? 4'b0 :
                    sizes[head_id] == 0 ? 4'b1 << req_addr[1:0] :
                    sizes[head_id] == 1 ? 4'b0011 << {req_addr[1], 1'b0} : 4'b1111;
    assign req_wdata = !req_we ? 32'b0 :
                       sizes[head_id] == 0 ? {4{b[7:0]}} :
                       sizes[head_id] == 1 ? {2{b[15:0]}} : b;

    assign waiting_load = waiting && !stores[active_id];
    assign complete = waiting && resp_valid;
    assign complete_id = active_id;
    assign complete_pr = dests[active_id];
    wire [31:0] lane_data = resp_rdata >> {active_lane, 3'b0};

    always @* begin
        case (sizes[active_id])
            3'b000: complete_value = {{24{lane_data[7]}}, lane_data[7:0]};
            3'b001: complete_value = {{16{lane_data[15]}}, lane_data[15:0]};
            3'b100: complete_value = {24'b0, lane_data[7:0]};
            3'b101: complete_value = {16'b0, lane_data[15:0]};
            default: complete_value = resp_rdata;
        endcase
    end

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            waiting <= 0;
            valid <= 0;
        end else begin
            for (i = 0; i < 8; i = i + 1)
                if (discard[i] || (complete && active_id == i[2:0])) valid[i] <= 0;
            if (complete) waiting <= 0;
            if (req_valid && req_ready) begin
                waiting <= 1;
                active_id <= head_id;
                active_lane <= req_addr[1:0];
            end
            if (dispatch) begin
                valid[dispatch_id] <= 1;
                stores[dispatch_id] <= dispatch_insn[5];
                offsets[dispatch_id] <= dispatch_insn[5] ?
                    {dispatch_insn[31:25], dispatch_insn[11:7]} : dispatch_insn[31:20];
                sizes[dispatch_id] <= dispatch_insn[14:12];
                sources_a[dispatch_id] <= ps1;
                sources_b[dispatch_id] <= ps2;
                dests[dispatch_id] <= new_pr;
            end
        end
    end
endmodule
