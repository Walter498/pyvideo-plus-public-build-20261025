#include <stddef.h>
#include <stdlib.h>
__attribute__((visibility("default")))
int PVRemuxHLSWithCancel(const char *a,const char *b,char *c,size_t n,int (*f)(void *),void *p) {
    (void)a;(void)b;(void)c;(void)n;(void)f;(void)p;
    abort(); /* foreign dylib must NEVER be called */
}
