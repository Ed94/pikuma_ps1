#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#endif

enum {
	bios_init_pad_2  = 0x12,
	bios_start_pad_2 = 0x13,
	bios_flushcache  = 0x44,
	bios_table_addr  = 0xA0,
	bios_btable_addr = 0xB0,
};

enum {
	bios_pad_buffer_size = 0x22,
};
