/*
 * A deliberately empty shared library whose only purpose is its PT_GNU_STACK
 * program header.
 *
 * musl's default thread stack is 128 KiB against glibc's 8 MiB, which is not
 * enough for the MapLibre Native tile workers and is the classic cause of
 * segfaults in native C++ addons on Alpine.
 *
 * musl raises its default from a loaded object's PT_GNU_STACK, but only while
 * the dynamic linker is still in startup (`if (!runtime ...)` in ldso/dynlink.c).
 * Node loads mbgl.node with dlopen(), long after that, so linking the addon
 * itself with -Wl,-z,stack-size has no effect. LD_PRELOAD, however, is
 * processed during startup -- so preloading this stub does raise the default
 * for every std::thread the process later creates.
 *
 * Build:  gcc -shared -fPIC -O2 -o libmusl-bigstack.so musl-bigstack.c \
 *              -Wl,-z,stack-size=8388608 -Wl,--build-id=none
 * Verify: readelf -lW libmusl-bigstack.so | grep GNU_STACK   -> 0x800000
 *
 * Harmless on glibc, which does not size thread stacks from PT_GNU_STACK.
 */
static int musl_bigstack_placeholder;
