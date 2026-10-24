/* Asking the kernel what a process may do with a file.
 *
 * The permission bits a stat returns describe the owner, the owning group and
 * everyone else, and Janet offers no way to ask which of those this process
 * is: it binds no getuid, geteuid, getgid, getgroups or access. Reading an "x"
 * out of the bits therefore answers whether somebody may execute a file, not
 * whether we may. The kernel already knows, so ask it.
 */
#include <janet.h>
#include <unistd.h>

static Janet cfun_executable(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    const char *path = janet_getcstring(argv, 0);
    /* X_OK is weighed against the real user and group rather than the
     * effective ones. herd is never installed setuid, so the two agree, and
     * access() carries further than faccessat(AT_EACCESS) does. */
    return janet_wrap_boolean(access(path, X_OK) == 0);
}

static const JanetReg cfuns[] = {
    {"executable?", cfun_executable,
     "(access/executable? path)\n\n"
     "Whether this process may execute path. Answers for the user herd runs "
     "as, so it accounts for ownership, group membership and anything else "
     "the kernel weighs, rather than for the permission bits alone."},
    {NULL, NULL, NULL}
};

JANET_MODULE_ENTRY(JanetTable *env) {
    janet_cfuns(env, "access", cfuns);
}
