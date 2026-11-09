module fetch_unit (
    input logic clk,
    input logic rst_n,
    input logic stop,
    input logic flush,
    input logic redirect,
    input logic [31:0] target_pc,
    output logic [1:0] epoch,
    output logic [31:0] req_pc,
    input logic [31:0] predicted_pc,
    output logic req_valid,
    input logic req_ready,
    input logic resp_valid,
    input logic [31:0] resp_insn,
    output logic inst_valid,
    output logic [31:0] inst_pc,
    output logic [31:0] inst_prediction,
    output logic [31:0] inst_word,
    input logic dispatch
);
    logic [31:0] request_pc, request_prediction;
    logic held;
    logic [31:0] held_pc, held_prediction, held_insn;

    assign inst_valid = held || resp_valid;
    assign inst_pc = held ? held_pc : request_pc;
    assign inst_prediction = held ? held_prediction : request_prediction;
    assign inst_word = held ? held_insn : resp_insn;
    // The response register bypasses the skid buffer on a ready dispatch.
    assign req_valid = rst_n && !stop && !flush && (!inst_valid || dispatch);

    always @(posedge clk) begin
        if (!rst_n) begin
            req_pc <= 0;
            held <= 0;
            epoch <= 0;
        end else if (flush) begin
            held <= 0;
            epoch <= epoch + 2'd1;
            if (redirect) req_pc <= target_pc;
        end else begin
            if (dispatch) held <= 0;
            if (resp_valid && !dispatch) begin
                held <= 1;
                held_pc <= request_pc;
                held_prediction <= request_prediction;
                held_insn <= resp_insn;
            end
            if (req_valid && req_ready) begin
                request_pc <= req_pc;
                request_prediction <= predicted_pc;
                req_pc <= predicted_pc;
            end
        end
    end
endmodule
