#!/usr/bin/env bash
# =============================================================================
#  mini-bowling-completion.bash — bash tab completion for mini-bowling.sh
#
#  Install:
#    sudo cp mini-bowling-completion.bash /etc/bash_completion.d/mini-bowling.sh
#    source /etc/bash_completion.d/mini-bowling.sh
# =============================================================================

_mini_bowling_complete() {
    local cur prev words cword
    _init_completion || return

    local top_cmds="status info version deploy code scoremore pi logs system install script help"

    # Word positions
    local cmd="${words[1]:-}"
    local sub="${words[2]:-}"
    local subsub="${words[3]:-}"

    # Helper: get project dir from installed script
    _mb_project_dir() {
        local sp; sp=$(command -v mini-bowling.sh 2>/dev/null)
        [[ -n "$sp" ]] || return
        grep -m1 'PROJECT_DIR=' "$sp" 2>/dev/null | \
            sed 's/.*PROJECT_DIR="\(.*\)"/\1/' | \
            sed "s|\$HOME|$HOME|g;s|~|$HOME|g"
    }

    # Helper: get sketch names as --FolderName
    _mb_sketches() {
        local pd; pd=$(_mb_project_dir)
        [[ -n "$pd" && -d "$pd" ]] || return
        find "$pd" -mindepth 1 -maxdepth 1 -type d \
            ! -name '.*' ! -name 'build' ! -name 'cache' ! -name 'libraries' \
            -printf '--%f\n' 2>/dev/null | sort
    }

    # Helper: get git branches
    _mb_branches() {
        local pd; pd=$(_mb_project_dir)
        [[ -n "$pd" && -d "$pd/.git" ]] || return
        git -C "$pd" branch -a 2>/dev/null | \
            sed 's|^\*\? *||;s|remotes/origin/||' | \
            grep -v HEAD | sort -u
    }

    # Helper: get log dates
    _mb_log_dates() {
        local sp; sp=$(command -v mini-bowling.sh 2>/dev/null)
        [[ -n "$sp" ]] || return
        local ld; ld=$(grep -m1 'LOG_DIR=' "$sp" 2>/dev/null | \
            sed 's/.*LOG_DIR="\(.*\)"/\1/' | sed "s|\$HOME|$HOME|g;s|~|$HOME|g")
        [[ -n "$ld" && -d "$ld" ]] || return
        find "$ld" -maxdepth 1 -name 'mini-bowling-*.log' -printf '%f\n' 2>/dev/null | \
            sed 's/^mini-bowling-//;s/\.log$//' | sort -r
    }

    # Helper: get ScoreMore versions
    _mb_sm_versions() {
        local sp; sp=$(command -v mini-bowling.sh 2>/dev/null)
        [[ -n "$sp" ]] || return
        local sd; sd=$(grep -m1 'SCOREMORE_DIR=' "$sp" 2>/dev/null | \
            sed 's/.*SCOREMORE_DIR="\(.*\)"/\1/' | sed "s|\$HOME|$HOME|g;s|~|$HOME|g")
        local arch; arch=$(grep -m1 'ARCH=' "$sp" 2>/dev/null | \
            sed 's/.*ARCH="\(.*\)"/\1/')
        [[ -n "$arch" ]] || arch="arm64"
        [[ -n "$sd" && -d "$sd" ]] || return
        find "$sd" -maxdepth 1 -name 'ScoreMore-*.AppImage' -printf '%f\n' 2>/dev/null | \
            sed "s/^ScoreMore-//;s/-${arch}\.AppImage$//" | sort -V -r
    }

    # ── Top level ─────────────────────────────────────────────────────────────
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$top_cmds" -- "$cur") )
        return 0
    fi

    # ── Second level ──────────────────────────────────────────────────────────
    if [[ $cword -eq 2 ]]; then
        case "$cmd" in
            status)   COMPREPLY=( $(compgen -W "--watch -w" -- "$cur") ) ;;
            deploy)   COMPREPLY=( $(compgen -W "--dry-run --no-kill --branch --sketch $(_mb_sketches) schedule unschedule history reset" -- "$cur") ) ;;
            code)     COMPREPLY=( $(compgen -W "status board sketch branch compile pull switch console config reset" -- "$cur") ) ;;
            install)  COMPREPLY=( $(compgen -W "setup create-dir cli" -- "$cur") ) ;;
            script)   COMPREPLY=( $(compgen -W "version update" -- "$cur") ) ;;
            scoremore) COMPREPLY=( $(compgen -W "start stop restart download version update check-update history rollback autostart remove-autostart logs watchdog" -- "$cur") ) ;;
            pi)       COMPREPLY=( $(compgen -W "status sysinfo cpu temp disk update reboot shutdown wifi vnc" -- "$cur") ) ;;
            logs)     COMPREPLY=( $(compgen -W "list follow dump tail clean" -- "$cur") ) ;;
            system)   COMPREPLY=( $(compgen -W "check health report support cron doctor preflight backup repair cleanup ports tail-all wait-for-network serial watchdog os-updates scoremore-update script-update" -- "$cur") ) ;;
        esac
        return 0
    fi

    # ── Third level ───────────────────────────────────────────────────────────
    if [[ $cword -eq 3 ]]; then
        case "$cmd" in
            code)
                case "$sub" in
                    pull)    COMPREPLY=( $(compgen -W "--branch $(_mb_branches)" -- "$cur") ) ;;
                    switch)  COMPREPLY=( $(compgen -W "$(_mb_branches)" -- "$cur") ) ;;
                    compile) COMPREPLY=( $(compgen -W "$(_mb_sketches)" -- "$cur") ) ;;
                    board)   COMPREPLY=( $(compgen -W "list reset" -- "$cur") ) ;;
                    sketch)
                        # If completing the sketch subcommand name itself
                        if [[ $cword -eq 3 ]]; then
                            COMPREPLY=( $(compgen -W "upload list test rollback info" -- "$cur") )
                            return 0
                        fi
                        case "${words[3]:-}" in
                            upload|test) COMPREPLY=( $(compgen -W "--no-kill --branch $(_mb_sketches)" -- "$cur") ) ;;
                            rollback)    COMPREPLY=( $(compgen -W "1 2 3" -- "$cur") ) ;;
                            info)        return 0 ;;
                        esac ;;
                    branch)
                        case "${words[3]:-}" in
                            checkout|switch) COMPREPLY=( $(compgen -W "$(_mb_branches)" -- "$cur") ) ;;
                        esac ;;
                esac ;;
            scoremore)
                case "$sub" in
                    download)  COMPREPLY=( $(compgen -W "latest $(_mb_sm_versions)" -- "$cur") ) ;;
                    update)    COMPREPLY=( $(compgen -W "--check-only" -- "$cur") ) ;;
                    history)   COMPREPLY=( $(compgen -W "list use clean" -- "$cur") ) ;;
                    logs)      COMPREPLY=( $(compgen -W "show list tail dump" -- "$cur") ) ;;
                    autostart) COMPREPLY=( $(compgen -W "enable disable status" -- "$cur") ) ;;
                    watchdog)  COMPREPLY=( $(compgen -W "run enable disable status" -- "$cur") ) ;;
                esac ;;
            pi)
                case "$sub" in
                    vnc)  COMPREPLY=( $(compgen -W "status start stop enable disable" -- "$cur") ) ;;
                    temp) COMPREPLY=( $(compgen -W "--watch" -- "$cur") ) ;;
                    cpu)  COMPREPLY=( $(compgen -W "--watch" -- "$cur") ) ;;
                esac ;;
            help)
                COMPREPLY=( $(compgen -W "deploy code scoremore pi system install logs" -- "$cur") ) ;;
            logs)
                case "$sub" in
                    dump|tail)  COMPREPLY=( $(compgen -W "--date" -- "$cur") ) ;;
                    clean)      COMPREPLY=( $(compgen -W "--keep" -- "$cur") ) ;;
                esac ;;
            system)
                case "$sub" in
                    preflight)        COMPREPLY=( $(compgen -W "--quick -q" -- "$cur") ) ;;
                    backup)           COMPREPLY=( $(compgen -W "--include-appimage" -- "$cur") ) ;;
                    tail-all)         COMPREPLY=( $(compgen -W "50 100 200" -- "$cur") ) ;;
                    wait-for-network) COMPREPLY=( $(compgen -W "30 60 120" -- "$cur") ) ;;
                    serial)           COMPREPLY=( $(compgen -W "start stop status tail console" -- "$cur") ) ;;
                    watchdog)         COMPREPLY=( $(compgen -W "run enable disable status" -- "$cur") ) ;;
                    os-updates|scoremore-update|script-update)
                        COMPREPLY=( $(compgen -W "enable disable status" -- "$cur") ) ;;
                esac ;;
            deploy)
                case "$sub" in
                    schedule)   COMPREPLY=( $(compgen -W "02:00 02:30 03:00 03:30" -- "$cur") ) ;;
                    history)    COMPREPLY=( $(compgen -W "10 20 50" -- "$cur") ) ;;
                    --branch)   COMPREPLY=( $(compgen -W "$(_mb_branches)" -- "$cur") ) ;;
                    --sketch)   COMPREPLY=( $(compgen -W "$(_mb_sketches | sed 's/^--//')" -- "$cur") ) ;;
                esac ;;
        esac
        return 0
    fi

    # ── Fourth level ──────────────────────────────────────────────────────────
    if [[ $cword -eq 4 ]]; then
        case "$cmd" in
            logs)
                # logs tail N --date  or  logs dump --date  →  suggest dates
                [[ "$sub" == "tail" || "$sub" == "dump" ]] && \
                    COMPREPLY=( $(compgen -W "$(_mb_log_dates)" -- "$cur") ) ;;
            scoremore)
                # scoremore history use <version>
                [[ "$sub" == "history" && "$subsub" == "use" ]] && \
                    COMPREPLY=( $(compgen -W "$(_mb_sm_versions)" -- "$cur") ) ;;
            system)
                if [[ "$sub" == "os-updates" || "$sub" == "scoremore-update" || "$sub" == "script-update" ]]; then
                    [[ "$subsub" == "enable" ]] && \
                        COMPREPLY=( $(compgen -W "03:00 03:30 04:00 04:30" -- "$cur") )
                fi ;;
        esac
        return 0
    fi

    return 0
}

complete -F _mini_bowling_complete mini-bowling.sh
complete -F _mini_bowling_complete mini-bowling
