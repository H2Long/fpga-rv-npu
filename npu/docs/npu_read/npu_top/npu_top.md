记9.29
阅读了mmioif模块的代码，梳理了一下对应的波形图
梳理如下：

首先外部的cpu在时钟下降沿给出cpu_valid和cpu_we以及写数据和地址数据

后面的第一个clk上升沿，mmio先锁存外部信号在req对应信号里

第二个clk，如果是写信号，进入resp完成状态

第三个clk,返回cpu_ready

总共是4个clk周期完成一次写操作
