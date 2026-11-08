// fndump: tiny RE helper. Dumps the first N instructions of an exported function from a loaded
// framework as an assembler file, and annotates every BL/B target with its symbol (via dladdr).
// Used because lldb from this Mac's Command Line Tools crashes.
//   tools/fndump <framework path> <symbol> [instructions] > out.s ; clang -c out.s ; otool -tv out.o
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <ptrauth.h>
#include <objc/runtime.h>
#include <CoreFoundation/CoreFoundation.h>

// ADRP page + ADD/LDR imm12 resolution, so we can name selector stubs and constant strings.
static uintptr_t adrp_target(uintptr_t pc, uint32_t w) {
    int64_t imm = (((int64_t)((w >> 5) & 0x7FFFF)) << 2) | ((w >> 29) & 3);
    imm = (imm << 43) >> 43;
    return (pc & ~0xFFFul) + (imm << 12);
}
static int is_adrp(uint32_t w) { return (w & 0x9F000000) == 0x90000000; }
// objc_msgSend$sel stubs in the shared cache: adrp x1; ldr x1,[x1,#imm]; adrp x16; ...; br x16
static const char *stub_selector(uintptr_t stub) {
    const uint32_t *c = (const uint32_t *)stub;
    if (!is_adrp(c[0]) || (c[0] & 0x1F) != 1) return NULL;
    if ((c[1] & 0xFFC00000) != 0xF9400000) return NULL;          // LDR x, [x, #imm*8]
    uintptr_t ref = adrp_target(stub, c[0]) + (((c[1] >> 10) & 0xFFF) << 3);
    SEL sel = *(SEL *)ref;
    return sel ? sel_getName(sel) : NULL;
}
static void describe_constant(uintptr_t addr) {
    // A CFConstantString's first word is its class; try CFString description safely via type check.
    CFTypeRef obj = (CFTypeRef)addr;
    Dl_info info;
    if (!dladdr((void *)addr, &info)) return;
    if (CFGetTypeID(obj) == CFStringGetTypeID()) {
        char buf[256];
        if (CFStringGetCString(obj, buf, sizeof buf, kCFStringEncodingUTF8)) printf("\t; constant string @\"%s\"\n", buf);
    }
}

static const char *name_of(uintptr_t addr, char *buf, size_t n) {
    Dl_info info;
    if (dladdr((void *)addr, &info) && info.dli_sname)
        snprintf(buf, n, "%s+0x%lx", info.dli_sname, (unsigned long)(addr - (uintptr_t)info.dli_saddr));
    else {
        const char *sel = stub_selector(addr);
        if (sel) snprintf(buf, n, "objc_msgSend [%s]", sel);
        else snprintf(buf, n, "0x%lx", (unsigned long)addr);
    }
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: fndump <framework> <symbol> [count]\n"); return 2; }
    if (!dlopen(argv[1], RTLD_NOW)) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    void *sym = dlsym(RTLD_DEFAULT, argv[2]);
    if (!sym) { fprintf(stderr, "dlsym: %s\n", dlerror()); return 1; }
    const uint32_t *code = ptrauth_strip(sym, ptrauth_key_function_pointer);
    int count = argc > 3 ? atoi(argv[3]) : 120;
    printf("\t.text\n\t.globl _%s_dump\n_%s_dump:\n", argv[2], argv[2]);
    char buf[256];
    for (int i = 0; i < count; i++) {
        uint32_t w = code[i];
        uintptr_t pc = (uintptr_t)&code[i];
        if ((w & 0x7C000000) == 0x14000000) {          // B / BL imm26
            int64_t off = ((int64_t)(int32_t)(w << 6)) >> 4;
            printf("\t.long 0x%08x ; %s -> %s\n", w, (w & 0x80000000) ? "bl" : "b", name_of(pc + off, buf, sizeof buf));
        } else if (is_adrp(w) && i + 1 < count && (code[i + 1] & 0xFF800000) == 0x91000000) {   // ADRP + ADD
            uintptr_t a = adrp_target(pc, w) + ((code[i + 1] >> 10) & 0xFFF);
            printf("\t.long 0x%08x ; adrp+add -> %s\n", w, name_of(a, buf, sizeof buf));
            describe_constant(a);
        } else {
            printf("\t.long 0x%08x\n", w);
        }
        if (w == 0xd65f03c0 || w == 0xd65f0fff || w == 0xd65f0bff) { printf("\t; ret\n"); if (i > 8) break; }
    }
    return 0;
}
