// Word cache between the SA-1's ROM port and the SDRAM controller's CPU2
// read lane. The SA-1 holds its address and ROM_REQ until ROM_WAIT drops,
// so each new word is fetched once; the two sequential words after the one
// being consumed are prefetched (a fetch takes longer than consuming one
// word). Four entries cover the SA-1 CPU / DMA / VBP interleave on the
// one address mux.
module sa1_rom_cache (
    input             mclk,
    input             resetn,
    input             active,       // SA-1 game running, not loading

    input      [22:0] rom_addr,     // byte address from SA1Map
    input             rom_req,
    output     [15:0] rom_q,
    output            rom_wait,

    output reg [22:1] cpu2_addr = 0,
    output reg        cpu2_req = 0,
    input             cpu2_req_ack,
    input      [15:0] cpu2_dout
);

reg        valid [0:3];
reg [21:0] tag   [0:3];
reg [15:0] data  [0:3];

wire [21:0] want = rom_addr[22:1];
wire [3:0]  hits = { valid[3] && tag[3] == want, valid[2] && tag[2] == want,
                     valid[1] && tag[1] == want, valid[0] && tag[0] == want };
wire        hit = |hits;
assign rom_q = hits[0] ? data[0] : hits[1] ? data[1] : hits[2] ? data[2] : data[3];
assign rom_wait = active && rom_req && ~hit;

reg [1:0]  ack_sync = 0;            // cpu2_req_ack (fclk) into mclk
reg        inflight = 0;
reg [21:0] inflight_tag = 0;
reg [1:0]  victim = 0;
reg [21:0] last_want = 0;           // last word the SA-1 actually consumed
reg        last_valid = 0;

// fill the round-robin victim, but never the entry the SA-1 is reading now
wire [1:0]  fill_idx = hits[victim] ? victim + 2'd1 : victim;

wire [21:0] pf1 = last_want + 22'd1;
wire [21:0] pf2 = last_want + 22'd2;
wire        pf1_cached = (valid[0] && tag[0] == pf1) || (valid[1] && tag[1] == pf1) ||
                         (valid[2] && tag[2] == pf1) || (valid[3] && tag[3] == pf1) ||
                         (inflight && inflight_tag == pf1);
wire        pf2_cached = (valid[0] && tag[0] == pf2) || (valid[1] && tag[1] == pf2) ||
                         (valid[2] && tag[2] == pf2) || (valid[3] && tag[3] == pf2) ||
                         (inflight && inflight_tag == pf2);
wire [21:0] pf_word = ~pf1_cached ? pf1 : pf2;
wire        pf_needed = last_valid && (~pf1_cached || ~pf2_cached);

integer i;
always @(posedge mclk) begin
    ack_sync <= {ack_sync[0], cpu2_req_ack};
    if (~resetn || ~active) begin
        for (i = 0; i < 4; i = i + 1) valid[i] <= 0;
        inflight <= 0;
        last_valid <= 0;
    end else begin
        if (inflight && ack_sync[1] == cpu2_req) begin
            // cpu2_req_ack toggled: the word is in cpu2_dout
            inflight <= 0;
            tag[fill_idx] <= inflight_tag;
            data[fill_idx] <= cpu2_dout;
            valid[fill_idx] <= 1;
            victim <= fill_idx + 2'd1;
        end else if (~inflight && rom_req && ~hit) begin
            cpu2_addr <= want;
            cpu2_req <= ~cpu2_req;
            inflight <= 1;
            inflight_tag <= want;
        end else if (~inflight && pf_needed) begin
            cpu2_addr <= pf_word;
            cpu2_req <= ~cpu2_req;
            inflight <= 1;
            inflight_tag <= pf_word;
        end
        if (rom_req && hit) begin
            last_want <= want;
            last_valid <= 1;
        end
    end
end

endmodule

