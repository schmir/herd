/* Asking the terminal behind a stream how wide it is.
 *
 * spork's rawterm/size asks stdin, whatever herd writes to, and returns what
 * the ioctl left in its buffer even when the call failed, so with stdin
 * redirected the width is garbage. herd needs the width of the terminal it
 * draws on, stdout for results and stderr for progress, and needs to know
 * when there is none.
 */
/* fileno is POSIX, which jpm's -std=c99 hides on Linux unless asked for. */
#define _POSIX_C_SOURCE 200809L

#include <janet.h>
#include <stdio.h>
#include <sys/ioctl.h>

static Janet cfun_columns(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    FILE *file = janet_getfile(argv, 0, NULL);
    struct winsize size;
    /* A pseudo-terminal nobody gave a size reports zero columns. */
    if (ioctl(fileno(file), TIOCGWINSZ, &size) != 0 || size.ws_col == 0) {
        return janet_wrap_nil();
    }
    return janet_wrap_integer(size.ws_col);
}

static const JanetReg cfuns[] = {
    {"columns", cfun_columns,
     "(terminal/columns stream)\n\n"
     "The number of columns of the terminal stream writes to, or nil when "
     "stream is not a terminal or the terminal does not say."},
    {NULL, NULL, NULL}
};

JANET_MODULE_ENTRY(JanetTable *env) {
    janet_cfuns(env, "terminal", cfuns);
}
