`timescale 1ns/1ps
module tb_instruction;
  reg clk=0,rst=1;
  always #5 clk=~clk;
  wire [31:0] bus_addr,bus_data;
  wire [3:0] bus_be;
  wire bus_we;
  cpu_top dut(.clk(clk),.rst(rst),.bus_addr_out(bus_addr),.bus_data_out(bus_data),
    .bus_be_out(bus_be),.bus_we_out(bus_we),.ibus_addr_out(),.ibus_re_out(),.ibus_req_valid(),
    .ibus_data_in(32'd0),.ibus_addr_in(16'd0),.bus_data_in_ext(32'd0),
    .ibus_we_in(1'b0),.bus_loaded_in(1'b0),.bus_hold_in(1'b0),.exti(1'b0),.i_busy(1'b0));
  wire [31:0] x1=dut.u_regfile.regs[1],x2=dut.u_regfile.regs[2],x3=dut.u_regfile.regs[3];
  wire [31:0] memory_word=dut.u_dtcm.dtcm[3];
  // Observational aliases only: bus address is a word address in this RTL.
  wire [31:0] effective_byte_addr=dut.r1_data_final_lsu+dut.offset_store0_2;
  wire [31:0] bus_byte_addr=bus_addr<<2;
  wire gpr_write=dut.we_5 && dut.rd_5!=0;
  wire load_write=dut.ld_we && dut.rd_load!=0;
  integer case_id,i,store_count=0,add_write_count=0,other_write_count=0;
  reg [1023:0] wave_path;
  always @(posedge clk) if(!rst) begin
    if(bus_we) begin
      store_count=store_count+1;
      if(case_id!=2 || bus_addr!==32'h00200003 || bus_data!==32'h12345678 || bus_be!==4'b1111)
        $fatal(1,"Invalid store addr=%h data=%h be=%b",bus_addr,bus_data,bus_be);
      $display("STORE SAMPLE t=%0t addr_word=%h addr_byte=%h data=%h be=%b",$time,bus_addr,bus_byte_addr,bus_data,bus_be);
    end
    if(gpr_write) begin
      if(case_id==1 && dut.rd_5==3) begin
        add_write_count=add_write_count+1;
        if(dut.result_5!==32'h35) $fatal(1,"Wrong ADD write data");
        $display("ADD WB SAMPLE t=%0t rd=%0d data=%h",$time,dut.rd_5,dut.result_5);
      end else other_write_count=other_write_count+1;
    end
    if(load_write) $fatal(1,"Unexpected load write");
  end
  initial begin
    if(!$value$plusargs("case=%d",case_id)) case_id=1;
    if(!$value$plusargs("wave=%s",wave_path)) wave_path="instruction.vcd";
    $dumpfile(wave_path);$dumpvars(0,tb_instruction);
    #1;
    for(i=0;i<8192;i=i+1) dut.u_itcm.itcm[i]=32'h00000013;
    for(i=0;i<4096;i=i+1) dut.u_dtcm.dtcm[i]=0;
    for(i=0;i<32;i=i+1) dut.u_regfile.regs[i]=0;
    dut.u_regfile.regs[3]=32'hdeadbeef;
    dut.u_dtcm.dtcm[3]=32'hdeadbeef;
    if(case_id==1) begin
      dut.u_regfile.regs[1]=32'h12;
      dut.u_regfile.regs[2]=32'h23;
      dut.u_itcm.itcm[0]=32'h002081b3; // add x3,x1,x2
      $display("ADD: PC=0 inst=002081b3 x1=00000012 x2=00000023 expected x3=00000035");
    end else if(case_id==2) begin
      dut.u_regfile.regs[1]=32'h00800000;
      dut.u_regfile.regs[2]=32'h12345678;
      dut.u_itcm.itcm[0]=32'h0020a623; // sw x2,12(x1)
      $display("STORE: PC=0 inst=0020a623 x1=00800000 x2=12345678 offset=12 expected byte address=0080000c");
    end else $fatal(1,"Invalid case");
    repeat(4) @(negedge clk);
    rst=0;
    repeat(12) @(negedge clk);
    if(dut.u_regfile.regs[0]!==0 || other_write_count!=0) $fatal(1,"Unexpected register side effect");
    if(case_id==1) begin
      if(x3!==32'h35 || add_write_count!=1 || store_count!=0 || memory_word!==32'hdeadbeef)
        $fatal(1,"ADD result/count/side effect mismatch");
      if(x1!==32'h12 || x2!==32'h23) $fatal(1,"ADD changed source registers");
      $display("PASS ADD: x3=00000035, exactly one x3 write, no stores");
    end else begin
      if(memory_word!==32'h12345678 || store_count!=1 || add_write_count!=0 || x3!==32'hdeadbeef)
        $fatal(1,"STORE result/count/side effect mismatch");
      if(x1!==32'h00800000 || x2!==32'h12345678) $fatal(1,"STORE changed source registers");
      if(dut.u_dtcm.dtcm[2]!==0 || dut.u_dtcm.dtcm[4]!==0) $fatal(1,"STORE changed adjacent words");
      $display("PASS STORE: DTCM[3]=12345678, exactly one full-word write, no GPR writes");
    end
    $finish;
  end
  initial begin #5000;$fatal(1,"Timeout");end
endmodule
