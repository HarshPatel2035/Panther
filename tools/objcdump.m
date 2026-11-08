// objcdump: lists the methods of an Objective-C class inside a (private) framework, via the runtime.
//   tools/objcdump <framework binary> <ClassName>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: objcdump <framework> <Class>\n"); return 2; }
    if (!dlopen(argv[1], RTLD_NOW)) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    Class cls = objc_getClass(argv[2]);
    if (!cls) { fprintf(stderr, "no class %s\n", argv[2]); return 1; }
    for (int meta = 0; meta < 2; meta++) {
        Class c = meta ? object_getClass((id)cls) : cls;
        unsigned n = 0;
        Method *methods = class_copyMethodList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            printf("%c %s  %s\n", meta ? '+' : '-', sel_getName(method_getName(methods[i])),
                   method_getTypeEncoding(methods[i]));
        }
        free(methods);
    }
    return 0;
}
