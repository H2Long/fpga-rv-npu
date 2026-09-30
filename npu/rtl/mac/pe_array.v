`timescale 1ns / 1ps
// pe_array — 4x4 PE 阵列:A 从左向右传播,BT 从上向下传播,
// PE[r][c] 累加 C[r][c] = sum_k A[r][k] * BT[c][k](输出驻留)。
// a_lanes[7:0]+r*8 = 行 r 的最左输入;bt_lanes[7:0]+c*8 = 列 c 的最上输入。
`include "npu_defines.vh"

module pe_array(
    input        clk,
    input        rst,
    input        enable,
    input        clear_acc,
    input [31:0] a_lanes,      // {行3, 行2, 行1, 行0} 各 8 bit
    input [3:0]  a_lane_v,
    input [31:0] bt_lanes,     // {列3, 列2, 列1, 列0}
    input [3:0]  bt_lane_v,
    output reg [16*`NPU_ACC_W-1:0] acc_flat   // PE[r][c] 在 (r*4+c)*32 偏移
);

    // 内部转发连线:a_out_grid[(r*4+c)*8 +: 8] = PE[r][c].a_out
    wire [127:0] a_out_grid;
    wire [127:0] bt_out_grid;
    wire [15:0]  a_v_grid;
    wire [15:0]  bt_v_grid;
    wire [16*`NPU_ACC_W-1:0] acc_flat_w;

    // ---- 行 0 ----
    pe_cell u_pe00(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_lanes[7:0]),            .a_v_in(a_lane_v[0]),
        .bt_in(bt_lanes[7:0]),          .bt_v_in(bt_lane_v[0]),
        .a_out(a_out_grid[7:0]),        .a_v_out(a_v_grid[0]),
        .bt_out(bt_out_grid[7:0]),      .bt_v_out(bt_v_grid[0]),
        .acc(acc_flat_w[31:0]));
    pe_cell u_pe01(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[7:0]),         .a_v_in(a_v_grid[0]),
        .bt_in(bt_lanes[15:8]),         .bt_v_in(bt_lane_v[1]),
        .a_out(a_out_grid[15:8]),       .a_v_out(a_v_grid[1]),
        .bt_out(bt_out_grid[15:8]),     .bt_v_out(bt_v_grid[1]),
        .acc(acc_flat_w[63:32]));
    pe_cell u_pe02(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[15:8]),        .a_v_in(a_v_grid[1]),
        .bt_in(bt_lanes[23:16]),        .bt_v_in(bt_lane_v[2]),
        .a_out(a_out_grid[23:16]),      .a_v_out(a_v_grid[2]),
        .bt_out(bt_out_grid[23:16]),    .bt_v_out(bt_v_grid[2]),
        .acc(acc_flat_w[95:64]));
    pe_cell u_pe03(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[23:16]),       .a_v_in(a_v_grid[2]),
        .bt_in(bt_lanes[31:24]),        .bt_v_in(bt_lane_v[3]),
        .a_out(a_out_grid[31:24]),      .a_v_out(a_v_grid[3]),
        .bt_out(bt_out_grid[31:24]),    .bt_v_out(bt_v_grid[3]),
        .acc(acc_flat_w[127:96]));

    // ---- 行 1 ----
    pe_cell u_pe10(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_lanes[15:8]),           .a_v_in(a_lane_v[1]),
        .bt_in(bt_out_grid[7:0]),       .bt_v_in(bt_v_grid[0]),
        .a_out(a_out_grid[39:32]),      .a_v_out(a_v_grid[4]),
        .bt_out(bt_out_grid[39:32]),    .bt_v_out(bt_v_grid[4]),
        .acc(acc_flat_w[159:128]));
    pe_cell u_pe11(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[39:32]),       .a_v_in(a_v_grid[4]),
        .bt_in(bt_out_grid[15:8]),      .bt_v_in(bt_v_grid[1]),
        .a_out(a_out_grid[47:40]),      .a_v_out(a_v_grid[5]),
        .bt_out(bt_out_grid[47:40]),    .bt_v_out(bt_v_grid[5]),
        .acc(acc_flat_w[191:160]));
    pe_cell u_pe12(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[47:40]),       .a_v_in(a_v_grid[5]),
        .bt_in(bt_out_grid[23:16]),     .bt_v_in(bt_v_grid[2]),
        .a_out(a_out_grid[55:48]),      .a_v_out(a_v_grid[6]),
        .bt_out(bt_out_grid[55:48]),    .bt_v_out(bt_v_grid[6]),
        .acc(acc_flat_w[223:192]));
    pe_cell u_pe13(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[55:48]),       .a_v_in(a_v_grid[6]),
        .bt_in(bt_out_grid[31:24]),     .bt_v_in(bt_v_grid[3]),
        .a_out(a_out_grid[63:56]),      .a_v_out(a_v_grid[7]),
        .bt_out(bt_out_grid[63:56]),    .bt_v_out(bt_v_grid[7]),
        .acc(acc_flat_w[255:224]));

    // ---- 行 2 ----
    pe_cell u_pe20(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_lanes[23:16]),          .a_v_in(a_lane_v[2]),
        .bt_in(bt_out_grid[39:32]),     .bt_v_in(bt_v_grid[4]),
        .a_out(a_out_grid[71:64]),      .a_v_out(a_v_grid[8]),
        .bt_out(bt_out_grid[71:64]),    .bt_v_out(bt_v_grid[8]),
        .acc(acc_flat_w[287:256]));
    pe_cell u_pe21(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[71:64]),       .a_v_in(a_v_grid[8]),
        .bt_in(bt_out_grid[47:40]),     .bt_v_in(bt_v_grid[5]),
        .a_out(a_out_grid[79:72]),      .a_v_out(a_v_grid[9]),
        .bt_out(bt_out_grid[79:72]),    .bt_v_out(bt_v_grid[9]),
        .acc(acc_flat_w[319:288]));
    pe_cell u_pe22(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[79:72]),       .a_v_in(a_v_grid[9]),
        .bt_in(bt_out_grid[55:48]),     .bt_v_in(bt_v_grid[6]),
        .a_out(a_out_grid[87:80]),      .a_v_out(a_v_grid[10]),
        .bt_out(bt_out_grid[87:80]),    .bt_v_out(bt_v_grid[10]),
        .acc(acc_flat_w[351:320]));
    pe_cell u_pe23(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[87:80]),       .a_v_in(a_v_grid[10]),
        .bt_in(bt_out_grid[63:56]),     .bt_v_in(bt_v_grid[7]),
        .a_out(a_out_grid[95:88]),      .a_v_out(a_v_grid[11]),
        .bt_out(bt_out_grid[95:88]),    .bt_v_out(bt_v_grid[11]),
        .acc(acc_flat_w[383:352]));

    // ---- 行 3 ----
    pe_cell u_pe30(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_lanes[31:24]),          .a_v_in(a_lane_v[3]),
        .bt_in(bt_out_grid[71:64]),     .bt_v_in(bt_v_grid[8]),
        .a_out(a_out_grid[103:96]),     .a_v_out(a_v_grid[12]),
        .bt_out(bt_out_grid[103:96]),   .bt_v_out(bt_v_grid[12]),
        .acc(acc_flat_w[415:384]));
    pe_cell u_pe31(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[103:96]),      .a_v_in(a_v_grid[12]),
        .bt_in(bt_out_grid[79:72]),     .bt_v_in(bt_v_grid[9]),
        .a_out(a_out_grid[111:104]),    .a_v_out(a_v_grid[13]),
        .bt_out(bt_out_grid[111:104]),  .bt_v_out(bt_v_grid[13]),
        .acc(acc_flat_w[447:416]));
    pe_cell u_pe32(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[111:104]),     .a_v_in(a_v_grid[13]),
        .bt_in(bt_out_grid[87:80]),     .bt_v_in(bt_v_grid[10]),
        .a_out(a_out_grid[119:112]),    .a_v_out(a_v_grid[14]),
        .bt_out(bt_out_grid[119:112]),  .bt_v_out(bt_v_grid[14]),
        .acc(acc_flat_w[479:448]));
    pe_cell u_pe33(.clk(clk), .rst(rst), .enable(enable), .clear_acc(clear_acc),
        .a_in(a_out_grid[119:112]),     .a_v_in(a_v_grid[14]),
        .bt_in(bt_out_grid[95:88]),     .bt_v_in(bt_v_grid[11]),
        .a_out(a_out_grid[127:120]),    .a_v_out(a_v_grid[15]),
        .bt_out(bt_out_grid[127:120]),  .bt_v_out(bt_v_grid[15]),
        .acc(acc_flat_w[511:480]));

    always @(*) begin
        acc_flat = acc_flat_w;
    end

endmodule
