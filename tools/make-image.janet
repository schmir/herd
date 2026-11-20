# Writes the C source of a standalone executable: the marshaled image of a
# program's main function, and a C main that unmarshals and runs it.
#
#   janet tools/make-image.janet ENTRY OUT.c NATIVE...
#
# ENTRY is the program, such as src/main.janet. Each NATIVE is the import name
# of a native module the program loads, such as access or spork/json. The
# module path must find them; this script does not change it. The script
# stops when the program loads a native module that is not named, since that
# module would be missing from the binary, or when one named is not loaded.
#
# This does what jpm's create-executable does. Each native module is linked
# in statically, with its entry function renamed by JANET_ENTRY_NAME to the
# name entry-name gives, so that the entries do not clash.

(defn entry-name
  ``The name of the entry function of the native module `name`, as jpm makes
  it: janet_module_entry_ and the name, with each byte that is not a letter,
  digit or _ written as _<decimal code>_. tools/gen-ninja.py compiles each
  module with the same name and has a copy of this function.``
  [name]
  (def out @"janet_module_entry_")
  (each b name
    (if (or (<= (chr "a") b (chr "z")) (<= (chr "A") b (chr "Z"))
            (<= (chr "0") b (chr "9")) (= b (chr "_")))
      (buffer/push-byte out b)
      (buffer/push-string out "_" (string b) "_")))
  (string out))

(defn- byte-array
  "C source for the image as a byte array, in the names the C main uses."
  [image]
  (string "static const unsigned char bytes[] = {"
          (string/join (map string image) ", ")
          "};\n\n"
          "const unsigned char *janet_payload_image_embed = bytes;\n"
          "size_t janet_payload_image_embed_size = sizeof(bytes);\n"))

# The C main of jpm's make-bin-source, for an image with the core included.
# main-head and main-tail are copied from jpm, under jpm's license:
#
# Copyright (c) 2022 Calvin Rose and contributors
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
(def- main-head
  ```
int main(int argc, const char **argv) {

#if defined(JANET_PRF)
    uint8_t hash_key[JANET_HASH_KEY_SIZE + 1];
#ifdef JANET_REDUCED_OS
    char *envvar = NULL;
#else
    char *envvar = getenv("JANET_HASHSEED");
#endif
    if (NULL != envvar) {
        strncpy((char *) hash_key, envvar, sizeof(hash_key) - 1);
    } else if (janet_cryptorand(hash_key, JANET_HASH_KEY_SIZE) != 0) {
        fputs("unable to initialize janet PRF hash function.\n", stderr);
        return 1;
    }
    janet_init_hash_key(hash_key);
#endif

    janet_init();

    /* Get core env */
    JanetTable *env = janet_core_env(NULL);
    JanetTable *lookup = janet_env_lookup(env);
    JanetTable *temptab;
    int handle = janet_gclock();

```)

(def- main-tail
  ```
    /* Unmarshal bytecode */
    Janet marsh_out = janet_unmarshal(
      janet_payload_image_embed,
      janet_payload_image_embed_size,
      0,
      lookup,
      NULL);

    /* Verify the marshalled object is a function */
    if (!janet_checktype(marsh_out, JANET_FUNCTION)) {
        fprintf(stderr, "invalid bytecode image - expected function.");
        return 1;
    }
    JanetFunction *jfunc = janet_unwrap_function(marsh_out);

    /* Check arity */
    janet_arity(argc, jfunc->def->min_arity, jfunc->def->max_arity);

    /* Collect command line arguments */
    JanetArray *args = janet_array(argc);
    for (int i = 0; i < argc; i++) {
        janet_array_push(args, janet_cstringv(argv[i]));
    }

    /* Create environment */
    temptab = env;
    janet_table_put(temptab, janet_ckeywordv("args"), janet_wrap_array(args));
    janet_table_put(temptab, janet_ckeywordv("executable"), janet_cstringv(argv[0]));
    janet_gcroot(janet_wrap_table(temptab));

    /* Unlock GC */
    janet_gcunlock(handle);

    /* Run everything */
    JanetFiber *fiber = janet_fiber(jfunc, 64, argc, argc ? args->data : NULL);
    fiber->env = temptab;
#ifdef JANET_EV
    janet_gcroot(janet_wrap_fiber(fiber));
    janet_schedule(fiber, janet_wrap_nil());
    janet_loop();
    int status = janet_fiber_status(fiber);
    janet_deinit();
    return status;
#else
    Janet out;
    JanetSignal result = janet_continue(fiber, janet_wrap_nil(), &out);
    if (result != JANET_SIGNAL_OK && result != JANET_SIGNAL_EVENT) {
      janet_stacktrace(fiber, out);
      janet_deinit();
      return result;
    }
    janet_deinit();
    return 0;
#endif
}
```)

(defn- loaded-natives
  "The environments of the native modules the program has loaded, by real path."
  []
  (tabseq [[path m] :pairs module/cache :when (get m :native)]
    (os/realpath path) m))

(defn make-image
  ``The C source for the program `entry`, with the native modules `natives`
  linked in.``
  [entry natives]
  (def entry-env (dofile entry :env (make-env)))
  (def main (get-in entry-env ['main :value]))
  (unless (function? main)
    (errorf "no main function in %s" entry))

  # The environment of each named module, found by the path the module path
  # gives for it.
  (def loaded (loaded-natives))
  (def named @{})
  (each name natives
    (def [path kind] (module/find name))
    (unless (= kind :native)
      (errorf "%s is not a native module on the module path" name))
    (def m (get loaded (os/realpath path)))
    (unless m
      (errorf "the native module %s is named, but %s does not load it" name entry))
    (put named name m))
  (when (> (length loaded) (length named))
    (errorf "%s loads native modules that are not named: %s" entry
            (string/join (sorted (filter |(not (index-of (get loaded $) named))
                                         (keys loaded)))
                         " ")))

  # Marshal each native function by a name the C main registers it under.
  # Sorted, so that the C code is the same from one run to the next.
  (def mdict (invert (env-lookup root-env)))
  (def declarations @"")
  (def registrations @"")
  (each name (sorted (keys named))
    (def m (named name))
    (def prefix (string "native/" name "/"))
    (def proto (table/getproto m))
    (table/setproto m nil)
    (eachp [sym value] (env-lookup m)
      (put mdict value (symbol prefix sym)))
    (table/setproto m proto)
    (def entry-fn (entry-name name))
    (buffer/push declarations "extern void " entry-fn "(JanetTable *);\n")
    (buffer/push registrations
                 "    temptab = janet_table(0);\n"
                 "    temptab->proto = env;\n"
                 "    " entry-fn "(temptab);\n"
                 "    janet_env_lookup_into(lookup, temptab, \"" prefix "\", 0);\n\n"))

  (string "#include <janet.h>\n"
          (byte-array (marshal main mdict))
          declarations
          "\n"
          main-head
          registrations
          main-tail))

(defn main
  [_ entry out & natives]
  (spit out (make-image entry natives)))
