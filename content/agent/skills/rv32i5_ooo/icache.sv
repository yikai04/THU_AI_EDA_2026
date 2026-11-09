module icache (
    input logic clk,
    input logic rst_n,
    input logic flush,
    input logic [1:0] flush_epoch,
    input logic cpu_req_valid,
    input logic [31:0] cpu_req_addr,
    output logic cpu_req_ready,
    output logic cpu_resp_valid,
    output logic [31:0] cpu_resp_data,
    output logic mem_req_valid,
    output logic [31:0] mem_req_addr,
    input logic mem_req_ready,
    input logic mem_resp_valid,
    input logic [31:0] mem_resp_data
);
    logic [15:0] valid;
    logic [23:0] tags [0:15];
    logic [127:0] lines [0:15];
    logic busy, killed;
    logic [31:0] miss_addr, bus_addr;
    logic [1:0] beat, epoch;
    logic [95:0] partial_line;
    wire [3:0] index = cpu_req_addr[7:4];
    wire hit = valid[index] && tags[index] == cpu_req_addr[31:8];
    wire [127:0] refill_line = {mem_resp_data, partial_line};

    assign cpu_req_ready = rst_n && !busy;
    assign mem_req_valid = rst_n && busy;
    assign mem_req_addr = rst_n ? bus_addr : 32'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            valid <= 0;
            busy <= 0;
            killed <= 0;
            bus_addr <= 0;
            cpu_resp_valid <= 0;
        end else begin
            cpu_resp_valid <= 0;
            if (busy) begin
                if (flush) killed <= 1;
                if (mem_req_ready && mem_resp_valid) begin
                    if (killed || flush || epoch != flush_epoch) begin
                        busy <= 0;
                    end else if (beat == 3) begin
                        busy <= 0;
                        valid[miss_addr[7:4]] <= 1;
                        tags[miss_addr[7:4]] <= miss_addr[31:8];
                        lines[miss_addr[7:4]] <= refill_line;
                        cpu_resp_valid <= 1;
                        cpu_resp_data <= refill_line[{miss_addr[3:2], 5'b0} +: 32];
                    end else begin
                        partial_line[{beat, 5'b0} +: 32] <= mem_resp_data;
                        beat <= beat + 2'd1;
                        bus_addr <= bus_addr + 32'd4;
                    end
                end
            end else if (cpu_req_valid && cpu_req_ready && !flush) begin
                if (hit) begin
                    cpu_resp_valid <= 1;
                    cpu_resp_data <= lines[index][{cpu_req_addr[3:2], 5'b0} +: 32];
                end else begin
                    busy <= 1;
                    killed <= 0;
                    miss_addr <= cpu_req_addr;
                    bus_addr <= {cpu_req_addr[31:4], 4'b0};
                    beat <= 0;
                    epoch <= flush_epoch;
                end
            end
        end
    end
endmodule
