# Writing the shell completion scripts for the herd command line.

(import ./options)
(import ./run)

(def shells
  "Shells a completion script can be written for."
  ["bash" "fish" "zsh"])

(defn- flags-of
  "Every spelling of the options, as they are written on the command line."
  [options]
  (mapcat (fn [option] (filter truthy? [(when (option :short) (string "-" (option :short)))
                                        (string "--" (option :name))]))
          options))

(def- value-flags
  "Every spelling of every option that takes a value, whichever command has it."
  (distinct (flags-of (filter (fn [option] (option :value-name))
                              (mapcat options/for-command
                                      ["clone" "list" "run" "completions" "tree"])))))

(defn- bash-script []
  (string
    ``# bash completion for herd. Source it, or save it where bash-completion
# looks, as in: herd completions bash > ~/.local/share/bash-completion/completions/herd
_herd() {
    local cur=${COMP_WORDS[COMP_CWORD]} cmd= cmd_index=0 i
    case ${COMP_WORDS[COMP_CWORD-1]} in
        -f|--filter)
            COMPREPLY=($(compgen -W "$(herd completions filters 2>/dev/null | cut -f1)" -- "$cur"))
            return ;;
        -C|--at)
            COMPREPLY=($(compgen -d -- "$cur"))
            return ;;
        # A number cannot be completed, and flag names would be misleading.
        -j|--jobs|-n|--limit|--sample|--max-depth)
            return ;;
        --show-output)
            COMPREPLY=($(compgen -W "`` (string/join run/show-output-conditions " ") ``" -- "$cur"))
            return ;;
    esac
    # The command is the first word that is neither an option nor its value.
    for ((i = 1; i < COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            `` (string/join value-flags "|") ``) ((i++)) ;;
            -*) ;;
            *) cmd=${COMP_WORDS[i]}; cmd_index=$i; break ;;
        esac
    done
    if [[ -z $cmd ]]; then
        COMPREPLY=($(compgen -W "$(herd completions commands 2>/dev/null | cut -f1) `` (string/join (map (fn [option] (string "--" (option :name))) options/top-level) " ") ``" -- "$cur"))
        return
    fi
    case $cmd in
``
    (string/join
      (seq [cmd :in ["clone" "list" "completions" "tree"]]
        (string "        " cmd ")\n"
                "            COMPREPLY=($(compgen -W \""
                (string/join (flags-of (options/for-command cmd)) " ")
                "\" -- \"$cur\")) ;;\n"))
      "")
    "        *)\n            COMPREPLY=($(compgen -W \""
    (string/join (flags-of (options/for-command "run")) " ")
    ``" -- "$cur")) ;;
    esac
    if [[ $cmd == run ]]; then
        # The command to run is the first word after run that is neither an
        # option nor its value; complete it, and what follows it, as a command.
        local run_index=0
        for ((i = cmd_index + 1; i < COMP_CWORD; i++)); do
            case ${COMP_WORDS[i]} in
                `` (string/join value-flags "|") ``) ((i++)) ;;
                -*) ;;
                *) run_index=$i; break ;;
            esac
        done
        if ((run_index > 0)); then
            COMPREPLY=()
            if declare -F _command_offset >/dev/null; then
                _command_offset $run_index
            fi
            return
        elif [[ $cur != -* ]]; then
            COMPREPLY=($(compgen -c -- "$cur"))
            return
        fi
    fi
    if [[ $cmd == completions && $COMP_CWORD -eq $((cmd_index + 1)) ]]; then
        COMPREPLY=($(compgen -W "bash fish zsh" -- "$cur"))
    fi
}
complete -F _herd herd
``))

(defn- fish-quote [text]
  (string "'" (string/replace-all "'" "\\'" text) "'"))

(defn- description
  "What a menu says of `option`: the short form where there is one."
  [option]
  (or (option :summary) (option :help)))

(defn- fish-lines [quoted-condition options]
  (seq [option :in options
        :let [long (option :name)]]
    (string "complete -c herd -n " quoted-condition
            (if (option :short) (string " -s " (option :short)) "")
            " -l " long
            # A filter name is never a file, so offer the names alone.
            (cond
              (= long "filter") " -x -a '(herd completions filters 2>/dev/null)'"
              (= long "at") " -x -a '(__fish_complete_directories)'"
              (= long "show-output")
              (string " -x -a '" (string/join run/show-output-conditions " ") "'")
              (option :value-name) " -r"
              "")
            " -d " (fish-quote (description option)) "\n")))

(defn- fish-script []
  (def cond-none "__herd_command_is ''")
  (string
    "# fish completion for herd: herd completions fish | source\n"
    "# or: herd completions fish > ~/.config/fish/completions/herd.fish\n"
    # The subcommand is the first word that is not an option or an option's value.
    "function __herd_command\n"
    "    set -l skip 0\n"
    "    for word in (commandline -opc)[2..-1]\n"
    "        if test $skip = 1\n"
    "            set skip 0\n"
    "        else if contains -- $word -C --at -d --depth -f --filter -j --jobs --show-output\n"
    "            set skip 1\n"
    "        else if not string match -q -- '-*' $word\n"
    "            echo $word\n"
    "            return\n"
    "        end\n"
    "    end\n"
    "end\n"
    "function __herd_command_is\n"
    "    test \"$(__herd_command)\" = \"$argv[1]\"\n"
    "end\n"
    "function __herd_command_other\n"
    "    set -l command (__herd_command)\n"
    "    test -n \"$command\"; and not contains -- $command clone list completions tree\n"
    "end\n"
    # Where the command to run starts, as a position in the command line: the
    # first word after run that is neither an option nor its value.
    "function __herd_run_index\n"
    "    set -l skip 0\n"
    "    set -l seen 0\n"
    "    set -l i 1\n"
    "    for word in (commandline -opc)[2..-1]\n"
    "        set i (math $i + 1)\n"
    "        if test $skip = 1\n"
    "            set skip 0\n"
    "        else if contains -- $word " (string/join value-flags " ") "\n"
    "            set skip 1\n"
    "        else if not string match -q -- '-*' $word\n"
    "            if test $seen = 0\n"
    "                set seen 1\n"
    "            else\n"
    "                echo $i\n"
    "                return\n"
    "            end\n"
    "        end\n"
    "    end\n"
    "end\n"
    "complete -c herd -f\n"
    "complete -c herd -n '" cond-none "' -a '(herd completions commands 2>/dev/null)'\n"
    (string/join (fish-lines (string "'" cond-none "'") options/top-level) "")
    "complete -c herd -n '__herd_command_is run; and test -z \"$(__herd_run_index)\"' -a '(__fish_complete_command)'\n"
    "complete -c herd -n '__herd_command_is run; and test -n \"$(__herd_run_index)\"' -x -a '(__fish_complete_subcommand --fcs-skip=2 " (string/join value-flags " ") ")'\n"
    "complete -c herd -n '__herd_command_is completions' -a '" (string/join shells " ") "'\n"
    (string/join (fish-lines (fish-quote "__herd_command_is clone") (options/for-command "clone")) "")
    (string/join (fish-lines (fish-quote "__herd_command_is list") (options/for-command "list")) "")
    (string/join (fish-lines (fish-quote "__herd_command_is completions") (options/for-command "completions")) "")
    (string/join (fish-lines (fish-quote "__herd_command_is tree") (options/for-command "tree")) "")
    (string/join (fish-lines (fish-quote "__herd_command_other") (options/for-command "run")) "")))

(defn- zsh-spec [option]
  (def {:short short :name long :value-name value} option)
  (def text (string/replace-all "]" "\\]" (string/replace-all "'" "'\\''" (description option))))
  (def action
    (if value
      (string ":" (string/ascii-lower value) ":"
              (case long
                "filter" " _herd_filters"
                "show-output" (string "(" (string/join run/show-output-conditions " ") ")")
                "at" " _files -/"
                ""))
      ""))
  (if (nil? short)
    (string "'--" long "[" text "]" action "'")
    (string "'(-" short " --" long ")'{-" short ",--" long "}'[" text "]" action "'")))

(defn- zsh-script []
  (def (clone list-opts run) [(options/for-command "clone")
                              (options/for-command "list")
                              (options/for-command "run")])
  (defn specs [options]
    (string/join (map (fn [option] (string "                " (zsh-spec option) " \\\n")) options) ""))
  (string
    "#compdef herd\n"
    "# zsh completion for herd: source <(herd completions zsh) after compinit, or\n# herd completions zsh > ~/.zfunc/_herd with ~/.zfunc in $fpath\n"
    "_herd_commands() {\n"
    "    local -a commands\n"
    "    commands=(${(f)\"$(herd completions commands 2>/dev/null | sed 's/:/\\\\:/; s/\\t/:/')\"})\n"
    "    _describe -t commands 'herd command' commands\n"
    "}\n\n"
    "_herd_filters() {\n"
    "    local -a filters\n"
    "    filters=(${(f)\"$(herd completions filters 2>/dev/null | sed 's/:/\\\\:/; s/\\t/:/')\"})\n"
    "    _describe -t filters 'herd filter' filters\n"
    "}\n\n"
    "_herd() {\n"
    # The command is the first word that is neither an option nor its value.
    # _arguments cannot be told that, so find it here and complete the rest as
    # though the command were the program.
    "    local i=2 command\n"
    "    for ((; i < CURRENT; i++)); do\n"
    "        case $words[i] in\n"
    "            " (string/join value-flags "|") ") ((i++)) ;;\n"
    "            -*) ;;\n"
    "            *) command=$words[i]; break ;;\n"
    "        esac\n"
    "    done\n"
    "    if [[ -z $command ]]; then\n"
    "        if [[ $words[CURRENT] == -* ]]; then\n"
    "            _arguments \\\n"
    "                " (string/join (map zsh-spec options/top-level) " \\\n                ") "\n"
    "        else\n"
    "            _herd_commands\n"
    "        fi\n"
    "        return\n"
    "    fi\n"
    "    words=(\"${(@)words[i,-1]}\")\n"
    "    (( CURRENT -= i - 1 ))\n"
    "    case $command in\n"
    "        completions) _arguments '1:shell:(" (string/join shells " ") ")' ;;\n"
    "        clone)\n            _arguments \\\n" (specs clone) "                ;;\n"
    "        list)\n            _arguments \\\n" (specs list-opts) "                ;;\n"
    "        tree)\n            _arguments \\\n" (specs (options/for-command "tree")) "                ;;\n"
    # Only run takes a command. -A stops option completion at the command, so
    # its own options are left to _normal.
    "        run)\n            _arguments -A '-*' \\\n" (specs run) "                '*::command:_normal' ;;\n"
    "        *)\n            _arguments \\\n" (specs run) "                ;;\n"
    "    esac\n"
    "}\n\n"
    "if [[ $funcstack[1] == _herd ]]; then\n"
    "    _herd \"$@\"\n"
    "else\n"
    "    compdef _herd herd\n"
    "fi\n"))

(defn script
  "The completion script for `shell`, or nil when there is none."
  [shell]
  (case shell
    "bash" (bash-script)
    "fish" (fish-script)
    "zsh" (zsh-script)))

(defn filter-lines
  "One `name TAB expression` line per filter, which the scripts offer as choices."
  [filters]
  (string/join
    (seq [name :in (sort (keys filters))]
      (string name "\t" (filters name)))
    "\n"))

(defn subcommand-lines
  "One `name TAB summary` line per subcommand, which the scripts offer as choices."
  [subcommands]
  (string/join
    (seq [name :in (sort (keys subcommands))]
      (string name "\t" (get-in subcommands [name :help])))
    "\n"))
