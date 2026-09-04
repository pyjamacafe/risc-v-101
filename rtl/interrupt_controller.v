`timescale 1ns/1ps
// Interrupt controller: aggregates the peripheral interrupt request lines
// into the core's irq vector.
//
// IRQ mapping (as seen by the core):
//   irq[0] = timer expired
//   irq[1] = UART RX data available
//   irq[2] = UART TX transmission complete
//
// Each line is passed through a two-flop synchronizer so the inputs are
// clean if the peripherals ever run in a different clock domain.

module interrupt_controller (
    input  wire clk,
    input  wire rst,
    input  wire timer_irq,
    input  wire uart_rx_irq,
    input  wire uart_tx_irq,
    output wire [3:0] irq
);

    reg t_s1, t_s2;
    reg r_s1, r_s2;
    reg x_s1, x_s2;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            t_s1 <= 1'b0; t_s2 <= 1'b0;
            r_s1 <= 1'b0; r_s2 <= 1'b0;
            x_s1 <= 1'b0; x_s2 <= 1'b0;
        end else begin
            t_s1 <= timer_irq;  t_s2 <= t_s1;
            r_s1 <= uart_rx_irq; r_s2 <= r_s1;
            x_s1 <= uart_tx_irq; x_s2 <= x_s1;
        end
    end

    assign irq = {1'b0, x_s2, r_s2, t_s2};

endmodule