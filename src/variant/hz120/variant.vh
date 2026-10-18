// TangCore build variant: hz120 (480p120). The RTL selects the 120 Hz path
// with `ifdef HZ120; the benches define it with iverilog -DHZ120 instead.
`define HZ120 1
