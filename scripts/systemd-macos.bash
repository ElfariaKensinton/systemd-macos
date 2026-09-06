# Bash completion for systemd-macos.

_systemd_macos_units() {
    local dir file
    for dir in /etc/systemd/system /usr/local/lib/systemd/system; do
        for file in "$dir"/*.service; do
            [ -e "$file" ] || continue
            printf '%s\n' "${file##*/}"
        done
    done
}

_systemd_macos_unit_words() {
    local cur="$1"
    local unit
    COMPREPLY=()
    while IFS= read -r unit; do
        [[ $unit == "$cur"* ]] && COMPREPLY+=("$unit")
    done < <(_systemd_macos_units)
}

_systemctl() {
    local cur command i word
    cur=${COMP_WORDS[COMP_CWORD]}
    command=

    for ((i=1; i<COMP_CWORD; i++)); do
        word=${COMP_WORDS[i]}
        case $word in
            start|stop|restart|reload|status|enable|disable|is-active|is-enabled|cat|show)
                command=$word
                break
                ;;
        esac
    done

    if [[ -n $command ]]; then
        _systemd_macos_unit_words "$cur"
        return 0
    fi

    case $cur in
        -*)
            COMPREPLY=( $(compgen -W '--now --quiet --no-legend --no-pager --system --user --plain --version --help -q -h' -- "$cur") )
            return 0
            ;;
    esac

    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W 'start stop restart reload status enable disable is-active is-enabled daemon-reload list-units list-unit-files cat show' -- "$cur") )
    else
        COMPREPLY=()
    fi
}

_journalctl() {
    local cur prev
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    case $prev in
        -u|--unit)
            _systemd_macos_unit_words "$cur"
            return 0
            ;;
        -n|--lines)
            COMPREPLY=( $(compgen -W '0 10 20 50 100 200 500 1000' -- "$cur") )
            return 0
            ;;
    esac

    case $cur in
        -*)
            COMPREPLY=( $(compgen -W '-f -u -n -x -e --follow --unit --lines --catalog --pager-end --no-pager --version --help --' -- "$cur") )
            ;;
        *)
            _systemd_macos_unit_words "$cur"
            ;;
    esac
}

complete -F _systemctl systemctl
complete -F _journalctl journalctl
