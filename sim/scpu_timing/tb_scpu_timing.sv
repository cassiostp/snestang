// S-CPU timing: WRAM refresh stall and H-IRQ/HDMA trigger positions.
// The real SCPU runs a NOP sled (DI=EA everywhere) with
// a synthetic 262-line frame of LINE_CLKS master clocks per line.
//
// Real hardware (fullsnes "SNES Timing H/V Counters"; ares
// sfc/cpu/timing.cpp): the CPU is stalled 40 master clocks once per
// scanline at about dot 133; H-IRQ fires at dot HTIME on the PPU dot
// grid; HDMA triggers at master clock 1104 (dot 276) of visible lines.
// The bench measures SNES_REFRESH widths per frame, and the master
// clocks from HBLANK fall (line start) to IRQ_FLAG / HDMA_RUN rising,
// and fails on a refresh width outside 40+-8 or a missing pulse.
// IRQ/HDMA positions are reported for comparison (the SCPU counts its
// own dots at 4 clocks each, resynced by HBLANK, like SNES_MiSTer).
`timescale 1ns/1ps

module tb_scpu_timing;
    parameter LINE_CLKS = 1364;
    parameter HBLANK_AT = 1096;    // dot 274 * 4

    logic clk = 0;
    always #1 clk = ~clk;
    logic rst_n = 0;

    // synthetic frame
    integer line_pos = 0;
    integer line_no = 0;
    logic hblank = 0, vblank = 0;
    integer frames_done = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            line_pos <= 0; line_no <= 0; hblank <= 0; vblank <= 0;
        end else begin
            if (line_pos == LINE_CLKS-1) begin
                line_pos <= 0;
                if (line_no == 261) begin
                    line_no <= 0;
                    frames_done <= frames_done + 1;
                end else line_no <= line_no + 1;
            end else line_pos <= line_pos + 1;
            hblank <= (line_pos >= HBLANK_AT-1);
            vblank <= (line_no >= 225);
        end
    end

    wire [23:0] ca;
    wire [7:0] pa, cpu_do;
    wire refresh, sysclk, sysclkf_ce, sysclkr_ce;

    SCPU dut (
        .CLK(clk), .RST_N(rst_n), .ENABLE(1'b1),
        .CA(ca), .CPURD_N(), .CPUWR_N(), .CPURD_CYC_N(), .PARD_CYC_N(),
        .DOT_CLK_CE_O(),
        .PA(pa), .PARD_N(), .PAWR_N(), .DI(8'hEA), .DO(cpu_do),
        .RAMSEL_N(), .ROMSEL_N(), .JPIO67(), .SNES_REFRESH(refresh),
        .SYSCLK(sysclk), .SYSCLKF_CE(sysclkf_ce), .SYSCLKR_CE(sysclkr_ce),
        .HBLANK(hblank), .VBLANK(vblank), .IRQ_N(1'b1),
        .JOY1_DI(2'b0), .JOY2_DI(2'b0), .JOY_STRB(), .JOY1_CLK(), .JOY2_CLK(),
        .TURBO(1'b0),
        .DBG_CPU_BRK(), .DBG_REG(8'b0), .DBG_DAT(), .DBG_DAT_IN(8'b0),
        .DBG_CPU_DAT(), .DBG_CPU_WR(1'b0)
    );

    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    integer errors = 0;
    // refresh measurement
    integer ref_width = 0, ref_pulses = 0, ref_total = 0;
    integer ref_min = 100000, ref_max = 0, ref_at [0:63];
    reg prev_ref = 0;
    longint ref_rise = 0;
    // irq / hdma measurement
    longint line_start = 0;
    reg prev_hblank = 0, prev_irq = 0, prev_hdma = 0;
    integer irq_pos = -1, hdma_pos = -1;
    integer hcnt_max = 0;

    always @(negedge clk) begin
        if (rst_n) begin
            if (refresh && !prev_ref) begin
                ref_rise = cyc;
                if (ref_pulses < 64) ref_at[ref_pulses] = cyc - line_start;
            end
            if (!refresh && prev_ref) begin
                ref_width = cyc - ref_rise;
                if (ref_width < ref_min) ref_min = ref_width;
                if (ref_width > ref_max) ref_max = ref_width;
                ref_total += ref_width;
                ref_pulses++;
            end
            prev_ref = refresh;

            if (!hblank && prev_hblank) begin
                line_start = cyc;
                if (dut.H_CNT > hcnt_max) hcnt_max = dut.H_CNT;
                if (dut.IRQ_FLAG) dut.IRQ_FLAG = 1'b0;   // stand in for TIMEUP reads
            end
            prev_hblank = hblank;
            if (dut.H_CNT > hcnt_max) hcnt_max = dut.H_CNT;

            if (dut.IRQ_FLAG && !prev_irq) irq_pos = cyc - line_start;
            prev_irq = dut.IRQ_FLAG;
            if (dut.HDMA_RUN && !prev_hdma && !vblank) hdma_pos = cyc - line_start;
            prev_hdma = dut.HDMA_RUN;
        end
    end

    task wait_frames(input integer n);
        integer t;
        begin
            t = frames_done + n;
            while (frames_done < t) @(negedge clk);
        end
    endtask

    integer htimes [0:6];
    initial begin
        htimes = '{10, 100, 200, 277, 323, 330, 339};
        repeat (20) @(posedge clk);
        rst_n = 1;
        wait_frames(1);               // settle (reset vector, NOP sled)

        // refresh over one full frame
        @(negedge clk);
        ref_pulses = 0; ref_total = 0; ref_min = 100000; ref_max = 0;
        wait_frames(1);
        $display("refresh: pulses/frame=%0d width min=%0d max=%0d total=%0d first_at=%0d (clocks)",
                 ref_pulses, ref_min, ref_max, ref_total, ref_at[0]);
        if (ref_pulses != 262) begin errors++; $display("FAIL: refresh pulses got=%0d want=262", ref_pulses); end
        if (ref_min < 32 || ref_max > 48) begin
            errors++;
            $display("FAIL: refresh width min=%0d max=%0d want 40+-8", ref_min, ref_max);
        end

        // H-IRQ positions
        for (int i = 0; i < 7; i++) begin
            @(negedge clk);
            dut.HTIME = htimes[i];
            dut.VTIME = 9'd50;
            dut.HVIRQ_EN = 2'b01;
            dut.IRQ_FLAG = 1'b0;
            irq_pos = -1;
            wait_frames(1);
            $display("hirq: HTIME=%0d irq at %0d clocks from line start (4*HTIME=%0d, hw beam=%0d)",
                     htimes[i], irq_pos, 4*htimes[i],
                     4*htimes[i] + 2*(htimes[i]>323) + 2*(htimes[i]>327));
        end

        // HDMA trigger position: poke channel 0 enable, watch HDMA_RUN
        @(negedge clk);
        dut.HVIRQ_EN = 2'b00;
        dut.HDMAEN = 8'h01;
        hdma_pos = -1;
        wait_frames(2);
        $display("hdma: HDMA_RUN at %0d clocks from line start (hw 1104)", hdma_pos);
        $display("scpu H_CNT max per line: %0d (line is %0d clocks)", hcnt_max, LINE_CLKS);

        if (errors == 0) begin
            $display("tb_scpu_timing: PASS");
            $finish;
        end else begin
            $display("tb_scpu_timing: %0d FAILURES", errors);
            $fatal(1);
        end
    end

    initial begin
        #60000000;
        $display("tb_scpu_timing: TIMEOUT frames=%0d", frames_done);
        $fatal(1);
    end
endmodule
