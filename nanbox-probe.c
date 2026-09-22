/* Test whether an allocation can return an address above 2^47.
 *
 * Janet stores pointers in double mantissas. Nanboxing supports only 47-bit
 * pointers. Real x86-64 Linux meets this limit. QEMU amd64 on arm64 and
 * native arm64 can return 0x0000ffff........ addresses. The Containerfile
 * uses this result to decide whether to define JANET_NO_NANBOX.
 *
 * Exit 0 if a pointer is above 2^47; otherwise exit 1. Test several sizes
 * because malloc may use the program break for small requests and mmap for
 * large requests.
 */
#include <stdint.h>
#include <stdlib.h>

int main(void) {
    size_t sizes[] = {1, 64, 4096, 1 << 20};
    for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++)
        if ((uintptr_t) malloc(sizes[i]) >> 47)
            return 0;
    return 1;
}
