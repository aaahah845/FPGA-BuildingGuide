


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

`define	  SDR_CLK_PERIOD				10 // 1 GHz PLL VCO / 10 = 100 MHz
// Counter visits 0..terminal inclusive; subtract one to stay within 64 ms.
`define   SELF_REFRESH_INTERVAL			(64000000/`SDR_CLK_PERIOD/(2**(`ROW_WIDTH))-1)



