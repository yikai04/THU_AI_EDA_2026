module branch_predictor (
    input logic clk,
    input logic rst_n,
    input logic [31:0] fetch_pc,
    output logic [31:0] predicted_pc,
    input logic resolve,
    input logic [31:0] resolve_pc,
    input logic [31:0] target,
    input logic [1:0] kind,
    input logic taken
);
    logic [15:0] valid;
    logic [25:0] tag [0:15];
    logic [31:0] targets [0:15];
    logic [1:0] kinds [0:15];
    logic [1:0] counters [0:15];
    wire [3:0] lookup = fetch_pc[5:2], update = resolve_pc[5:2];
    wire hit = valid[lookup] && tag[lookup] == fetch_pc[31:6];
    wire update_hit = valid[update] && tag[update] == resolve_pc[31:6];

    assign predicted_pc = hit && (kinds[lookup] != 0 || counters[lookup][1])
                        ? targets[lookup] : fetch_pc + 32'd4;

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid <= 0;
            for (i = 0; i < 16; i = i + 1)
                counters[i] <= 2'b01;
        end else if (resolve) begin
            if (kind == 0) begin
                if (taken && counters[update] != 2'b11)
                    counters[update] <= counters[update] + 2'd1;
                if (!taken && counters[update] != 2'b00)
                    counters[update] <= counters[update] - 2'd1;
            end
            if (taken || update_hit) begin
                valid[update] <= 1'b1;
                tag[update] <= resolve_pc[31:6];
                targets[update] <= target;
                kinds[update] <= kind;
            end
        end
    end
endmodule
