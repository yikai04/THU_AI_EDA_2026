module aes128 (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [127:0] key,
    input  logic [127:0] plaintext,
    output logic         ready,
    output logic         done,
    output logic [127:0] ciphertext
);

    // ---------------------------------------------------------------
    // S-box function (standard AES S-box, 256 entries)
    // ---------------------------------------------------------------
    function automatic [7:0] sbox;
        input [7:0] x;
        reg [7:0] y;
        begin
            case (x)
                8'h00: y = 8'h63; 8'h01: y = 8'h7c; 8'h02: y = 8'h77; 8'h03: y = 8'h7b;
                8'h04: y = 8'hf2; 8'h05: y = 8'h6b; 8'h06: y = 8'h6f; 8'h07: y = 8'hc5;
                8'h08: y = 8'h30; 8'h09: y = 8'h01; 8'h0a: y = 8'h67; 8'h0b: y = 8'h2b;
                8'h0c: y = 8'hfe; 8'h0d: y = 8'hd7; 8'h0e: y = 8'hab; 8'h0f: y = 8'h76;
                8'h10: y = 8'hca; 8'h11: y = 8'h82; 8'h12: y = 8'hc9; 8'h13: y = 8'h7d;
                8'h14: y = 8'hfa; 8'h15: y = 8'h59; 8'h16: y = 8'h47; 8'h17: y = 8'hf0;
                8'h18: y = 8'had; 8'h19: y = 8'hd4; 8'h1a: y = 8'ha2; 8'h1b: y = 8'haf;
                8'h1c: y = 8'h9c; 8'h1d: y = 8'ha4; 8'h1e: y = 8'h72; 8'h1f: y = 8'hc0;
                8'h20: y = 8'hb7; 8'h21: y = 8'hfd; 8'h22: y = 8'h93; 8'h23: y = 8'h26;
                8'h24: y = 8'h36; 8'h25: y = 8'h3f; 8'h26: y = 8'hf7; 8'h27: y = 8'hcc;
                8'h28: y = 8'h34; 8'h29: y = 8'ha5; 8'h2a: y = 8'he5; 8'h2b: y = 8'hf1;
                8'h2c: y = 8'h71; 8'h2d: y = 8'hd8; 8'h2e: y = 8'h31; 8'h2f: y = 8'h15;
                8'h30: y = 8'h04; 8'h31: y = 8'hc7; 8'h32: y = 8'h23; 8'h33: y = 8'hc3;
                8'h34: y = 8'h18; 8'h35: y = 8'h96; 8'h36: y = 8'h05; 8'h37: y = 8'h9a;
                8'h38: y = 8'h07; 8'h39: y = 8'h12; 8'h3a: y = 8'h80; 8'h3b: y = 8'he2;
                8'h3c: y = 8'heb; 8'h3d: y = 8'h27; 8'h3e: y = 8'hb2; 8'h3f: y = 8'h75;
                8'h40: y = 8'h09; 8'h41: y = 8'h83; 8'h42: y = 8'h2c; 8'h43: y = 8'h1a;
                8'h44: y = 8'h1b; 8'h45: y = 8'h6e; 8'h46: y = 8'h5a; 8'h47: y = 8'ha0;
                8'h48: y = 8'h52; 8'h49: y = 8'h3b; 8'h4a: y = 8'hd6; 8'h4b: y = 8'hb3;
                8'h4c: y = 8'h29; 8'h4d: y = 8'he3; 8'h4e: y = 8'h2f; 8'h4f: y = 8'h84;
                8'h50: y = 8'h53; 8'h51: y = 8'hd1; 8'h52: y = 8'h00; 8'h53: y = 8'hed;
                8'h54: y = 8'h20; 8'h55: y = 8'hfc; 8'h56: y = 8'hb1; 8'h57: y = 8'h5b;
                8'h58: y = 8'h6a; 8'h59: y = 8'hcb; 8'h5a: y = 8'hbe; 8'h5b: y = 8'h39;
                8'h5c: y = 8'h4a; 8'h5d: y = 8'h4c; 8'h5e: y = 8'h58; 8'h5f: y = 8'hcf;
                8'h60: y = 8'hd0; 8'h61: y = 8'hef; 8'h62: y = 8'haa; 8'h63: y = 8'hfb;
                8'h64: y = 8'h43; 8'h65: y = 8'h4d; 8'h66: y = 8'h33; 8'h67: y = 8'h85;
                8'h68: y = 8'h45; 8'h69: y = 8'hf9; 8'h6a: y = 8'h02; 8'h6b: y = 8'h7f;
                8'h6c: y = 8'h50; 8'h6d: y = 8'h3c; 8'h6e: y = 8'h9f; 8'h6f: y = 8'ha8;
                8'h70: y = 8'h51; 8'h71: y = 8'ha3; 8'h72: y = 8'h40; 8'h73: y = 8'h8f;
                8'h74: y = 8'h92; 8'h75: y = 8'h9d; 8'h76: y = 8'h38; 8'h77: y = 8'hf5;
                8'h78: y = 8'hbc; 8'h79: y = 8'hb6; 8'h7a: y = 8'hda; 8'h7b: y = 8'h21;
                8'h7c: y = 8'h10; 8'h7d: y = 8'hff; 8'h7e: y = 8'hf3; 8'h7f: y = 8'hd2;
                8'h80: y = 8'hcd; 8'h81: y = 8'h0c; 8'h82: y = 8'h13; 8'h83: y = 8'hec;
                8'h84: y = 8'h5f; 8'h85: y = 8'h97; 8'h86: y = 8'h44; 8'h87: y = 8'h17;
                8'h88: y = 8'hc4; 8'h89: y = 8'ha7; 8'h8a: y = 8'h7e; 8'h8b: y = 8'h3d;
                8'h8c: y = 8'h64; 8'h8d: y = 8'h5d; 8'h8e: y = 8'h19; 8'h8f: y = 8'h73;
                8'h90: y = 8'h60; 8'h91: y = 8'h81; 8'h92: y = 8'h4f; 8'h93: y = 8'hdc;
                8'h94: y = 8'h22; 8'h95: y = 8'h2a; 8'h96: y = 8'h90; 8'h97: y = 8'h88;
                8'h98: y = 8'h46; 8'h99: y = 8'hee; 8'h9a: y = 8'hb8; 8'h9b: y = 8'h14;
                8'h9c: y = 8'hde; 8'h9d: y = 8'h5e; 8'h9e: y = 8'h0b; 8'h9f: y = 8'hdb;
                8'ha0: y = 8'he0; 8'ha1: y = 8'h32; 8'ha2: y = 8'h3a; 8'ha3: y = 8'h0a;
                8'ha4: y = 8'h49; 8'ha5: y = 8'h06; 8'ha6: y = 8'h24; 8'ha7: y = 8'h5c;
                8'ha8: y = 8'hc2; 8'ha9: y = 8'hd3; 8'haa: y = 8'hac; 8'hab: y = 8'h62;
                8'hac: y = 8'h91; 8'had: y = 8'h95; 8'hae: y = 8'he4; 8'haf: y = 8'h79;
                8'hb0: y = 8'he7; 8'hb1: y = 8'hc8; 8'hb2: y = 8'h37; 8'hb3: y = 8'h6d;
                8'hb4: y = 8'h8d; 8'hb5: y = 8'hd5; 8'hb6: y = 8'h4e; 8'hb7: y = 8'ha9;
                8'hb8: y = 8'h6c; 8'hb9: y = 8'h56; 8'hba: y = 8'hf4; 8'hbb: y = 8'hea;
                8'hbc: y = 8'h65; 8'hbd: y = 8'h7a; 8'hbe: y = 8'hae; 8'hbf: y = 8'h08;
                8'hc0: y = 8'hba; 8'hc1: y = 8'h78; 8'hc2: y = 8'h25; 8'hc3: y = 8'h2e;
                8'hc4: y = 8'h1c; 8'hc5: y = 8'ha6; 8'hc6: y = 8'hb4; 8'hc7: y = 8'hc6;
                8'hc8: y = 8'he8; 8'hc9: y = 8'hdd; 8'hca: y = 8'h74; 8'hcb: y = 8'h1f;
                8'hcc: y = 8'h4b; 8'hcd: y = 8'hbd; 8'hce: y = 8'h8b; 8'hcf: y = 8'h8a;
                8'hd0: y = 8'h70; 8'hd1: y = 8'h3e; 8'hd2: y = 8'hb5; 8'hd3: y = 8'h66;
                8'hd4: y = 8'h48; 8'hd5: y = 8'h03; 8'hd6: y = 8'hf6; 8'hd7: y = 8'h0e;
                8'hd8: y = 8'h61; 8'hd9: y = 8'h35; 8'hda: y = 8'h57; 8'hdb: y = 8'hb9;
                8'hdc: y = 8'h86; 8'hdd: y = 8'hc1; 8'hde: y = 8'h1d; 8'hdf: y = 8'h9e;
                8'he0: y = 8'he1; 8'he1: y = 8'hf8; 8'he2: y = 8'h98; 8'he3: y = 8'h11;
                8'he4: y = 8'h69; 8'he5: y = 8'hd9; 8'he6: y = 8'h8e; 8'he7: y = 8'h94;
                8'he8: y = 8'h9b; 8'he9: y = 8'h1e; 8'hea: y = 8'h87; 8'heb: y = 8'he9;
                8'hec: y = 8'hce; 8'hed: y = 8'h55; 8'hee: y = 8'h28; 8'hef: y = 8'hdf;
                8'hf0: y = 8'h8c; 8'hf1: y = 8'ha1; 8'hf2: y = 8'h89; 8'hf3: y = 8'h0d;
                8'hf4: y = 8'hbf; 8'hf5: y = 8'he6; 8'hf6: y = 8'h42; 8'hf7: y = 8'h68;
                8'hf8: y = 8'h41; 8'hf9: y = 8'h99; 8'hfa: y = 8'h2d; 8'hfb: y = 8'h0f;
                8'hfc: y = 8'hb0; 8'hfd: y = 8'h54; 8'hfe: y = 8'hbb; 8'hff: y = 8'h16;
            endcase
            sbox = y;
        end
    endfunction

    // ---------------------------------------------------------------
    // xtime function
    // ---------------------------------------------------------------
    function automatic [7:0] xtime;
        input [7:0] x;
        begin
            xtime = {x[6:0], 1'b0} ^ (x[7] ? 8'h1b : 8'h00);
        end
    endfunction

    // ---------------------------------------------------------------
    // State / key registers
    // ---------------------------------------------------------------
    logic [127:0] state;      // current data state
    logic [127:0] rkey;       // current round key
    logic [127:0] next_rkey;  // combinational next round key

    logic [3:0]   round;      // 0..10
    logic [3:0]   byte_cnt;   // 0..7 (pairs of bytes)
    logic [1:0]   phase;      // FSM phase

    // FSM states
    localparam IDLE   = 2'd0;
    localparam SUB    = 2'd1;  // SubBytes + ShiftRows (2 bytes/cycle)
    localparam MIX    = 2'd2;  // MixColumns + AddRoundKey + key expand
    localparam FINAL  = 2'd3;  // final round (no MixColumns)

    logic [1:0] fsm;

    // ---------------------------------------------------------------
    // Key expansion combinational logic
    // ---------------------------------------------------------------
    logic [31:0] w0, w1, w2, w3;
    logic [31:0] temp, nw0, nw1, nw2, nw3;
    logic [7:0]  rcon;

    assign w0 = rkey[127:96];
    assign w1 = rkey[95:64];
    assign w2 = rkey[63:32];
    assign w3 = rkey[31:0];

    // Rcon for round+1 (round is current round index 0..9)
    always_comb begin
        case (round)
            4'd0: rcon = 8'h01;
            4'd1: rcon = 8'h02;
            4'd2: rcon = 8'h04;
            4'd3: rcon = 8'h08;
            4'd4: rcon = 8'h10;
            4'd5: rcon = 8'h20;
            4'd6: rcon = 8'h40;
            4'd7: rcon = 8'h80;
            4'd8: rcon = 8'h1b;
            4'd9: rcon = 8'h36;
            default: rcon = 8'h00;
        endcase
    end

    // RotWord + SubWord on w3
    wire [31:0] rot_sub;
    assign rot_sub = {sbox(w3[23:16]), sbox(w3[15:8]), sbox(w3[7:0]), sbox(w3[31:24])};

    assign temp = rot_sub ^ {rcon, 24'h000000};
    assign nw0 = w0 ^ temp;
    assign nw1 = w1 ^ nw0;
    assign nw2 = w2 ^ nw1;
    assign nw3 = w3 ^ nw2;
    assign next_rkey = {nw0, nw1, nw2, nw3};

    // ---------------------------------------------------------------
    // SubBytes + ShiftRows: process 2 bytes per cycle
    // We process byte positions in the "shifted" order so that
    // writing back to state directly yields ShiftRows result.
    //
    // ShiftRows mapping (column-major, byte index = 4*c + r):
    //   new[r][c] = old[r][(c+r) mod 4]
    // In byte index terms (idx = 4*c + r):
    //   new_idx(4*c+r) = old_idx(4*((c+r) mod 4) + r)
    //
    // We iterate over destination byte index d = 0..15 in pairs.
    // For each destination d, source s = 4*((c+r)%4)+r where c=d/4, r=d%4.
    // ---------------------------------------------------------------

    // Compute source index for a given destination index
    function automatic [3:0] src_idx;
        input [3:0] d;
        reg [1:0] c, r;
        reg [1:0] cs;
        begin
            c = d[3:2];
            r = d[1:0];
            cs = c + r;  // mod 4 automatically by 2-bit
            src_idx = {cs, r};
        end
    endfunction

    // Byte selection helper: get byte at index i from 128-bit vector
    function automatic [7:0] get_byte;
        input [127:0] v;
        input [3:0]   i;
        begin
            get_byte = v[127 - 8*i -: 8];
        end
    endfunction

    // ---------------------------------------------------------------
    // MixColumns combinational (applied to state after SubBytes/ShiftRows)
    // ---------------------------------------------------------------
    function automatic [127:0] mixcolumns;
        input [127:0] s;
        reg [7:0] a0,a1,a2,a3,b0,b1,b2,b3,t;
        reg [127:0] out;
        integer c;
        begin
            out = 128'h0;
            for (c = 0; c < 4; c = c + 1) begin
                a0 = s[127 - 8*(4*c+0) -: 8];
                a1 = s[127 - 8*(4*c+1) -: 8];
                a2 = s[127 - 8*(4*c+2) -: 8];
                a3 = s[127 - 8*(4*c+3) -: 8];
                t  = a0 ^ a1 ^ a2 ^ a3;
                b0 = a0 ^ t ^ xtime(a0 ^ a1);
                b1 = a1 ^ t ^ xtime(a1 ^ a2);
                b2 = a2 ^ t ^ xtime(a2 ^ a3);
                b3 = a3 ^ t ^ xtime(a3 ^ a0);
                out[127 - 8*(4*c+0) -: 8] = b0;
                out[127 - 8*(4*c+1) -: 8] = b1;
                out[127 - 8*(4*c+2) -: 8] = b2;
                out[127 - 8*(4*c+3) -: 8] = b3;
            end
            mixcolumns = out;
        end
    endfunction

    // ---------------------------------------------------------------
    // SubBytes+ShiftRows working register
    // ---------------------------------------------------------------
    logic [127:0] sb_state;   // accumulates SubBytes+ShiftRows result

    // Two S-box instances (shared for data and key expansion)
    logic [7:0] sbox_in0, sbox_in1;
    wire  [7:0] sbox_out0, sbox_out1;
    assign sbox_out0 = sbox(sbox_in0);
    assign sbox_out1 = sbox(sbox_in1);

    // Source byte indices for current pair
    wire [3:0] d0, d1;
    assign d0 = {byte_cnt, 1'b0};        // 2*byte_cnt
    assign d1 = {byte_cnt, 1'b0} + 4'd1; // 2*byte_cnt + 1

    wire [3:0] s0, s1;
    assign s0 = src_idx(d0);
    assign s1 = src_idx(d1);

    // ---------------------------------------------------------------
    // FSM
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fsm        <= IDLE;
            ready      <= 1'b1;
            done       <= 1'b0;
            state      <= 128'h0;
            rkey       <= 128'h0;
            sb_state   <= 128'h0;
            round      <= 4'd0;
            byte_cnt   <= 4'd0;
            ciphertext <= 128'h0;
        end else begin
            done <= 1'b0;

            case (fsm)
                IDLE: begin
                    ready <= 1'b1;
                    if (start && ready) begin
                        state    <= plaintext ^ key;
                        rkey     <= key;
                        round    <= 4'd0;
                        byte_cnt <= 4'd0;
                        sb_state <= 128'h0;
                        ready    <= 1'b0;
                        fsm      <= SUB;
                    end
                end

                SUB: begin
                    // Process 2 bytes per cycle: SubBytes + ShiftRows
                    // sbox_in0/1 driven combinationally below
                    sb_state[127 - 8*d0 -: 8] <= sbox_out0;
                    sb_state[127 - 8*d1 -: 8] <= sbox_out1;

                    if (byte_cnt == 4'd7) begin
                        byte_cnt <= 4'd0;
                        if (round == 4'd9)
                            fsm <= FINAL;
                        else
                            fsm <= MIX;
                    end else begin
                        byte_cnt <= byte_cnt + 4'd1;
                    end
                end

                MIX: begin
                    // sb_state now holds SubBytes+ShiftRows result
                    // Apply MixColumns, then AddRoundKey with next_rkey
                    state <= mixcolumns(sb_state) ^ next_rkey;
                    rkey  <= next_rkey;
                    round <= round + 4'd1;
                    fsm   <= SUB;
                end

                FINAL: begin
                    // Last round: SubBytes+ShiftRows done, AddRoundKey only
                    ciphertext <= sb_state ^ next_rkey;
                    rkey       <= next_rkey;
                    done       <= 1'b1;
                    ready      <= 1'b1;
                    fsm        <= IDLE;
                end

                default: fsm <= IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // S-box input muxing (combinational)
    // During SUB phase: data path (from state)
    // During MIX phase: key expansion (RotWord+SubWord on w3)
    // ---------------------------------------------------------------
    always_comb begin
        if (fsm == SUB) begin
            sbox_in0 = get_byte(state, s0);
            sbox_in1 = get_byte(state, s1);
        end else begin
            // Key expansion: SubWord(RotWord(w3))
            // rot_sub = {sbox(w3[23:16]), sbox(w3[15:8]), sbox(w3[7:0]), sbox(w3[31:24])}
            sbox_in0 = w3[23:16];
            sbox_in1 = w3[15:8];
        end
    end

endmodule
