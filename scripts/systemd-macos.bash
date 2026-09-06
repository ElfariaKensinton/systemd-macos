# Bash completion for systemd-macos.
# Install this file where bash-completion discovers it, e.g.
# /usr/local/share/bash-completion/completions/systemctl and journalctl.

_systemd_macos_units() {
    local units dir file

    if command -v systemctl >/dev/null 2>&1; then
        units=$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}')
        if [ -n "$units" ]; then
            printf '%s\n' "$units"
            return 0
        fi
    fi

    for dir in /etc/systemd/system /usr/local/lib/systemd/system; do
        for file in "$dir"/*.service; do
            [ -e "$file" ] || continue
            printf '%s\n' "${file##*/}"
        done
    done
}

_systemd_macos_unit_words() {
    local word=$1
    local units
    units=$(_systemd_macos_units)
    COMPREPLY=( $(compgen -W "$units" -- "$word") )
}

_systemctl() {
    local cur prev command i
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    command=

    for ((i=1; i<COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            start|stop|restart|reload|status|enable|disable|is-active|is-enabled|cat|show)
                command=${COMP_WORDS[i]}
                break
                ;;
        esac
    done

    case $prev in
        --system|--user|--plain|--quiet|-q|--no-legend|--no-pager|--now)
            COMPREPLY=()
            return 0
            ;;
    esac

    if [[ -n $command ]]; then
        case $command in
            start|stop|restart|reload|status|enable|disable|is-active|is-enabled|cat|show)
                _systemd_macos_unit_words "$cur"
                return 0
                ;;
        esac
    fi

    case $cur in
        -*)
            COMPREPLY=( $(compgen -W '--now --quiet --no-legend --no-pager --system --user --plain --version --help -q -h' -- "$cur") )
            return 0
            ;;
    esac

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W 'start stop restart reload status enable disable is-active is-enabled daemon-reload list-units list-unit-files cat show --now --quiet --no-legend --no-pager --system --user --plain --version --help' -- "$cur") )
        return 0
    fi

    COMPREPLY=()
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

    if [[ $prev == -- ]]; then
        _systemd_macos_unit_words "$cur"
        return 0
    fi

    case $cur in
        -*)
            COMPREPLY=( $(compgen -W '-f -u -n -x -e --follow --unit --lines --catalog --pager-end --no-pager --version --help --' -- "$cur") )
            return 0
            ;;
    esac

    # Positional unit names are accepted by this implementation too.
    _systemd_macos_unit_words "$cur"
}

complete -F _systemctl systemctl
complete -F _journalctl journalctl
