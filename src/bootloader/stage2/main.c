#include "stdint.h"
#include "stdio.h"

void _cdecl cstart_(uint16_t bootDrive) {
    const char far* farStr = "Far String";

    puts("Bootloader Stage 2\r\n");
    printf("Boot drive: %d\r\n", bootDrive);
    printf("Written in %s by %s\r\n", "C", "LoreSchaeffer");
    printf("Compilation timestamp in %s %s\r\n", __DATE__, __TIME__);

    printf("Completing booloading process...\r\n");
    printf("Starting kernel...\r\n");

    for(;;);
}
