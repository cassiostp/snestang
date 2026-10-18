module tb_gsu_multiply;
    GSU dut(.CLK(1'b0), .RST_N(1'b1), .ENABLE(1'b0),
        .ADDR(24'b0), .DI(8'b0), .RD_N(1'b1), .WR_N(1'b1),
        .ROM_DI(8'b0), .ROM_WAIT(1'b0), .RAM_DI(8'b0), .RAM_WAIT(1'b0));
    integer checks = 0;
    integer x, y, mode, i;
    integer signed a, b;
    reg [31:0] product;
    reg [31:0] seed = 32'h324a195f;
    task check8(input integer lhs, rhs, unsigned_mode);
        begin
            dut.R[0] = 16'(lhs);
            dut.R[7] = 16'(rhs);
            dut.OPCODE = 8'h87;
            dut.FLAG_ALT1 = 1'(unsigned_mode);
            a = unsigned_mode != 0 ? lhs : (lhs < 128 ? lhs : lhs - 256);
            b = unsigned_mode != 0 ? rhs : (rhs < 128 ? rhs : rhs - 256);
            product = a * b;
            #1;
            if (dut.ALUR !== product[15:0] || dut.ALUS !== product[15] ||
                dut.ALUZ !== (product[15:0] == 0))
                $fatal(1, "MULT mode=%0d lhs=%h rhs=%h got=%h expected=%h", unsigned_mode, lhs, rhs, dut.ALUR, product[15:0]);
            checks++;
        end
    endtask
    task check16(input reg [15:0] lhs, rhs, input bit long_mode);
        begin
            dut.R[0] = lhs;
            dut.R[6] = rhs;
            dut.OPCODE = 8'h9f;
            dut.FLAG_ALT1 = long_mode;
            a = lhs[15] ? int'(lhs) - 65536 : int'(lhs);
            b = rhs[15] ? int'(rhs) - 65536 : int'(rhs);
            product = a * b;
            #1;
            if (dut.ALUR !== product[31:16] || dut.MULR !== product[15:0] ||
                dut.ALUCY !== product[15] || dut.ALUS !== product[31] ||
                dut.ALUZ !== (product[31:16] == 0))
                $fatal(1, "FMULT mode=%0d lhs=%h rhs=%h got=%h:%h expected=%h", long_mode, lhs, rhs, dut.ALUR, dut.MULR, product);
            checks++;
        end
    endtask
    initial begin
        dut.SREG = 0;
        dut.DREG = 0;
        dut.FLAG_ALT1 = 0;
        dut.FLAG_ALT2 = 0;
        dut.FLAG_B = 0;
        dut.FLAG_CY = 0;
        dut.FLAG_OV = 0;
        dut.STATE = 0;
        check8(255, 2, 0);
        for (mode = 0; mode < 2; mode++)
            for (x = 0; x < 256; x++)
                for (y = 0; y < 256; y++) check8(x, y, mode);
        for (mode = 0; mode < 2; mode++) begin
            check16(16'h8000, 16'h8000, 1'(mode));
            check16(16'h8000, 16'h7fff, 1'(mode));
            check16(16'hffff, 16'h0001, 1'(mode));
            check16(16'hffff, 16'hffff, 1'(mode));
            check16(16'h0000, 16'h8000, 1'(mode));
            check16(16'h7fff, 16'h7fff, 1'(mode));
            for (i = 0; i < 4096; i++) begin
                seed = seed * 32'd1664525 + 32'd1013904223;
                check16(seed[31:16], seed[15:0], 1'(mode));
            end
        end
        $display("PASS gsu_multiply %0d checks", checks);
        $finish;
    end
endmodule
