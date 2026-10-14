// Word cache between the SA-1's ROM port and the SDRAM controller's CPU2
// read lane. The SA-1 holds its address and ROM_REQ until ROM_WAIT drops,
// so each new word is fetched once; the two sequential words after the one
// being consumed are prefetched (a fetch takes longer than consuming one
// word). Four entries cover the SA-1 CPU / DMA / VBP interleave on the
// one address mux.
//
// QUALIFY_WAIT = 1 is the CX4 instance: the CX4 advances its fetch address
// on most mclk edges, so the registered hit_q/q_q below still describe the
// previous word when the wait counter already matches (WS1 = 0). The wait
// then also covers that one-mclk register lag (want_q records which word
// the registered outputs are for). Costs one mclk per word change even on
// a hit; the SA-1 instance keeps QUALIFY_WAIT = 0 and is unchanged.
module sa1_rom_cache #(
    parameter QUALIFY_WAIT = 0
) (
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
wire [15:0] hit_data = hits[0] ? data[0] : hits[1] ? data[1] : hits[2] ? data[2] : data[3];

// Registered outputs. The combinational S-CPU-address -> SA-1-core path
// (Super MMC map + cache comparators + SA-1 datapath, 41 logic levels)
// misses mclk setup by 0.5 ns, so the hit decision and the word are
// sampled here. Safe because every consumer advances its ROM address only
// on CE/EN edges, which are 2 mclk apart (P65_CE, the DMA SDA/DDA/DTC
// updates and the VBP VDA updates are all gated by the toggling CLK_CE
// via EN): the word for the new address is in q_q a full mclk before any
// CE/EN edge can sample it. The registers track only while rom_req is up,
// so an S-CPU window (which forces rom_req low and freezes the SA-1 side)
// leaves the SA-1's word in place with no re-hit bubble. Cost: one extra
// mclk per cache miss; cached address changes cost nothing. (With
// QUALIFY_WAIT = 1 the mismatch term below re-adds one mclk per word
// change, hit or miss: the price of the CX4's every-mclk addresses.)
reg         hit_q = 0;
reg  [15:0] q_q = 0;
assign rom_q = q_q;
generate
if (QUALIFY_WAIT) begin : g_qualify_wait
    reg [21:0] want_q = 0;
    always @(posedge mclk) begin
        if (~resetn || ~active) want_q <= 0;
        else if (rom_req) want_q <= want;
    end
    assign rom_wait = active && rom_req && (~hit_q || want_q != want);
end else begin : g_plain_wait
    assign rom_wait = active && rom_req && ~hit_q;
end
endgenerate

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
        hit_q <= 0;
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
        if (rom_req) begin
            hit_q <= hit;
            q_q <= hit_data;
        end
    end
end

endmodule

