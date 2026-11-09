module dcache (
    input logic clk,
    input logic rst_n,
    input logic flush,
    input logic [1:0] flush_epoch,
    input logic cpu_req_valid,
    input logic cpu_req_we,
    input logic [31:0] cpu_req_addr,
    input logic [31:0] cpu_req_wdata,
    input logic [3:0] cpu_req_be,
    output logic cpu_req_ready,
    output logic cpu_resp_valid,
    output logic [31:0] cpu_resp_rdata,
    output logic mem_req_valid,
    output logic mem_req_we,
    output logic [31:0] mem_req_addr,
    output logic [31:0] mem_req_wdata,
    output logic [3:0] mem_req_be,
    input logic mem_req_ready,
    input logic mem_resp_valid,
    input logic [31:0] mem_resp_data
);
    localparam IDLE = 2'd0, REFILL = 2'd1, WRITE = 2'd2;
    logic [1:0] state, beat, epoch;
    logic [15:0] valid;
    logic [23:0] tags [0:15];
    logic [127:0] lines [0:15];
    logic [95:0] partial_line;
    logic [31:0] addr, wdata;
    logic [3:0] be;
    logic store, killed;

    function automatic [127:0] merge_word(
        input [127:0] line, input [1:0] index, input [31:0] value, input [3:0] lanes
    );
        integer byte_index;
        begin
            merge_word = line;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (lanes[byte_index])
                    merge_word[{index, 5'b0} + 8*byte_index +: 8] = value[8*byte_index +: 8];
        end
    endfunction

    wire [3:0] index = cpu_req_addr[7:4];
    wire [1:0] word_index = cpu_req_addr[3:2];
    wire hit = valid[index] && tags[index] == cpu_req_addr[31:8];
    wire [127:0] refill_line = {mem_resp_data, partial_line};

    assign cpu_req_ready = rst_n && state == IDLE;
    assign mem_req_valid = rst_n && state != IDLE;
    assign mem_req_we = state == WRITE;
    assign mem_req_addr = mem_req_we ? addr : {addr[31:4], beat, 2'b0};
    assign mem_req_wdata = wdata;
    assign mem_req_be = mem_req_we ? be : 4'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            valid <= 0;
            cpu_resp_valid <= 0;
        end else begin
            cpu_resp_valid <= 0;
            if (flush && state != IDLE) killed <= 1;
            case (state)
                IDLE: if (cpu_req_valid && cpu_req_ready && !flush) begin
                    if (hit && !cpu_req_we) begin
                        cpu_resp_valid <= 1;
                        cpu_resp_rdata <= lines[index][{word_index, 5'b0} +: 32];
                    end else begin
                        addr <= cpu_req_addr;
                        wdata <= cpu_req_wdata;
                        be <= cpu_req_be;
                        store <= cpu_req_we;
                        epoch <= flush_epoch;
                        killed <= 0;
                        beat <= 0;
                        state <= hit ? WRITE : REFILL;
                        if (hit)
                            lines[index] <= merge_word(lines[index], word_index, cpu_req_wdata, cpu_req_be);
                    end
                end
                REFILL: if (mem_req_ready && mem_resp_valid) begin
                    if (killed || flush || epoch != flush_epoch) begin
                        state <= IDLE;
                    end else if (beat == 3) begin
                        valid[addr[7:4]] <= 1;
                        tags[addr[7:4]] <= addr[31:8];
                        lines[addr[7:4]] <= store ? merge_word(refill_line, addr[3:2], wdata, be) : refill_line;
                        if (store) begin
                            state <= WRITE;
                        end else begin
                            cpu_resp_valid <= 1;
                            cpu_resp_rdata <= refill_line[{addr[3:2], 5'b0} +: 32];
                            state <= IDLE;
                        end
                    end else begin
                        partial_line[{beat, 5'b0} +: 32] <= mem_resp_data;
                        beat <= beat + 2'd1;
                    end
                end
                WRITE: if (mem_req_ready) begin
                    cpu_resp_valid <= !killed && !flush && epoch == flush_epoch;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
