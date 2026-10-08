(def shells
  "Shells a completion script can be written for."
  ["bash" "fish" "zsh"])

(def selection-options
  "Options every selecting command takes, as [short long value-name help]."
  [["C" "at" "PATH" "Select repositories using PATH as the working location."]
   ["a" "all-anchors" nil "Consider repositories from every configuration anchor."]
   ["f" "filter" "NAME" "Select only repositories kept by the named filter."]
   ["h" "help" nil "Show this help message."]])

(def- jobs-option
  ["j" "jobs" "N" "Run at most N repository operations at the same time."])

(def- running-options
  [["" "show-output" "WHEN" "Show command output: never, on-failure, or always."]
   jobs-option])

(def- list-options
  [["" "ok" nil "Print configured repositories that are on disk."]
   ["" "missing" nil "Print configured repositories that are not on disk."]
   ["" "extra" nil "Print repositories on disk that no configuration defines."]
   ["" "status" nil "Print the status of each repository first."]
   ["" "max-depth" "N" "Scan at most N directories below the path for extra repositories."]
   ["" "hidden" nil "Scan hidden directories for extra repositories."]
   ["" "follow-links" nil "Follow symbolic links when scanning for extra repositories."]])

(defn command-options
  ``The options `command` takes. Commands from `:commands` in config.jdn run a
  command in each repository, so anything that is not built in takes what
  `herd run` does apart from the command itself.``
  [command]
  (case command
    "clone" [;selection-options jobs-option]
    "list" [;selection-options ;list-options]
    "completions" [["h" "help" nil "Show this help message."]]
    [;selection-options ;running-options]))

(defn- flags-of
  "Every spelling of the options, as they are written on the command line."
  [options]
  (mapcat (fn [option] (filter truthy? [(unless (empty? (option 0)) (string "-" (option 0)))
                                        (string "--" (option 1))]))
          options))

(def- value-flags
  "Every spelling of every option that takes a value, whichever command has it."
  (distinct (flags-of (filter (fn [option] (option 2))
                              (mapcat command-options
                                      ["clone" "list" "run" "completions"])))))

(defn- bash-script []
  (string
    ``# bash completion for herd. Source it, or save it where bash-completion
# looks, as in: herd completions bash > ~/.local/share/bash-completion/completions/herd
_herd() {
    local cur=${COMP_WORDS[COMP_CWORD]} cmd= cmd_index=0 i
    # The command is the first word that is neither an option nor its value.
    for ((i = 1; i < COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            `` (string/join value-flags "|") ``) ((i++)) ;;
            -*) ;;
            *) cmd=${COMP_WORDS[i]}; cmd_index=$i; break ;;
        esac
    done
    if [[ -z $cmd ]]; then
        COMPREPLY=($(compgen -W "$(herd completions commands 2>/dev/null | cut -f1) --help --version" -- "$cur"))
        return
    fi
    case $cmd in
``
    (string/join
      (seq [cmd :in ["clone" "list" "completions"]]
        (string "        " cmd ")\n"
                "            COMPREPLY=($(compgen -W \""
                (string/join (flags-of (command-options cmd)) " ")
                "\" -- \"$cur\")) ;;\n"))
      "")
    "        *)\n            COMPREPLY=($(compgen -W \""
    (string/join (flags-of (command-options "run")) " ")
    ``" -- "$cur")) ;;
    esac
    if [[ $cmd == completions && $COMP_CWORD -eq $((cmd_index + 1)) ]]; then
        COMPREPLY=($(compgen -W "bash fish zsh" -- "$cur"))
    fi
}
complete -F _herd herd
``))

(defn- fish-quote [text]
  (string "'" (string/replace-all "'" "\\'" text) "'"))

(defn- fish-lines [condition options]
  (seq [[short long value help] :in options]
    (string "complete -c herd -n " (fish-quote condition)
            (if (empty? short) "" (string " -s " short))
            " -l " long
            (if value " -r" "")
            " -d " (fish-quote help) "\n")))

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
    "        else if contains -- $word -C --at -f --filter -j --jobs --show-output\n"
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
    "    test -n \"$command\"; and not contains -- $command clone list completions\n"
    "end\n"
    "complete -c herd -f\n"
    "complete -c herd -n '" cond-none "' -a '(herd completions commands 2>/dev/null)'\n"
    "complete -c herd -n '" cond-none "' -s h -l help -d 'Show this help message.'\n"
    "complete -c herd -n '" cond-none "' -s V -l version -d 'Show the version and exit.'\n"
    "complete -c herd -n '__herd_command_is completions' -a '" (string/join shells " ") "'\n"
    (string/join (fish-lines "__herd_command_is clone" (command-options "clone")) "")
    (string/join (fish-lines "__herd_command_is list" (command-options "list")) "")
    (string/join (fish-lines "__herd_command_is completions" (command-options "completions")) "")
    (string/join (fish-lines "__herd_command_other" (command-options "run")) "")))

(defn- zsh-spec [[short long value help]]
  (def text (string/replace-all "]" "\\]" (string/replace-all "'" "'\\''" help)))
  (def action (if value (string ":" (string/ascii-lower value) ":") ""))
  (if (empty? short)
    (string "'--" long "[" text "]" action "'")
    (string "'(-" short " --" long ")'{-" short ",--" long "}'[" text "]" action "'")))

(defn- zsh-script []
  (def (clone list-opts run) [(command-options "clone")
                              (command-options "list")
                              (command-options "run")])
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
    "                '(-h --help)'{-h,--help}'[Show this help message.]' \\\n"
    "                '(-V --version)'{-V,--version}'[Show the version and exit.]'\n"
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
    "        *)\n            _arguments \\\n" (specs run) "                '*:command: _normal' ;;\n"
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

(defn command-lines
  "One `name TAB summary` line per command, which the scripts offer as choices."
  [commands]
  (string/join
    (seq [name :in (sort (keys commands))]
      (string name "\t" (get-in commands [name :help])))
    "\n"))
