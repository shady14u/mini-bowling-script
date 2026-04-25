#!/usr/bin/env bash
#
# mini-bowling - Helper script for Arduino + ScoreMore development workflow
# https://github.com/glenpekarcsik/mini-bowling-script
#
# Usage examples:
#   mini-bowling.sh code branch update
#   mini-bowling.sh code sketch upload --Master_Test
#   mini-bowling.sh code sketch list
#   mini-bowling.sh deploy --no-kill
#   mini-bowling.sh scoremore download latest
#

set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------
#  Configuration
# ------------------------------------------------

readonly DEFAULT_GIT_BRANCH="main"
readonly SCRIPT_VERSION="5.4.2"
readonly SCRIPT_REPO="https://github.com/glenpekarcsik/mini-bowling-script.git"
readonly PROJECT_REPO="https://github.com/mini-bowling/mini-bowling.git"
readonly PROJECT_DIR="${MINI_BOWLING_DIR:-$HOME/Documents/Bowling/Arduino/mini-bowling}"
readonly DEFAULT_PORT="/dev/ttyACM0"
readonly BOARD="arduino:avr:mega"
readonly ARDUINO_CORE="arduino:avr"
readonly ARDUINO_LIBS=(
    "Adafruit NeoPixel"
    "AccelStepper"
    "Servo"
    "Accessories"
    "Servo Hardware PWM"
)

readonly SCOREMORE_DIR="$HOME/Documents/Bowling/ScoreMore"
readonly BASE_URL="https://scoremorebowling.b-cdn.net/downloads"
readonly APP_NAME="ScoreMore"
readonly ARCH="arm64"
readonly EXTENSION="AppImage"

readonly SYMLINK_PATH="$HOME/Desktop/ScoreMore.AppImage"
readonly BAUD_RATE="9600"

readonly LOG_DIR="$HOME/Documents/Bowling/logs"
readonly DEPLOY_STATUS_FILE="$LOG_DIR/.last-deploy-status"
readonly ARDUINO_STATUS_FILE="$LOG_DIR/.last-arduino-upload"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ------------------------------------------------
#  Helpers
# ------------------------------------------------

die() {
    echo -e "${RED}Error:${NC} $*" >&2
    exit 1
}

setup_logging() {
    mkdir -p "$LOG_DIR" || { echo "Warning: cannot create log dir $LOG_DIR" >&2; return; }

    local log_file="$LOG_DIR/mini-bowling-$(date '+%Y-%m-%d').log"

    {
        echo "----------------------------------------"
        echo "$(date '+%Y-%m-%d %H:%M:%S')  mini-bowling.sh $*"
        echo "----------------------------------------"
    } >> "$log_file"

    # Store log path for use by log_cmd wrapper - avoid exec redirects
    # which are unreliable with some shells/Pi configurations
    export MINI_BOWLING_LOG="$log_file"
}

prune_logs() {
    [[ -d "$LOG_DIR" ]] || return 0
    # Skip if already pruned today — avoids a `find` on every logged command
    local stamp="$LOG_DIR/.last-pruned"
    if [[ -f "$stamp" ]] && [[ "$(date +%Y-%m-%d)" == "$(cat "$stamp" 2>/dev/null)" ]]; then
        return 0
    fi
    local pruned=0
    while IFS= read -r -d '' f; do
        rm -f -- "$f"
        pruned=$((pruned + 1))
    done < <(find "$LOG_DIR" -maxdepth 1 -name "mini-bowling-*.log" \
                  -mtime +30 -print0 2>/dev/null)
    [[ $pruned -gt 0 ]] && echo "→ Pruned $pruned log file(s) older than 30 days" || true
    date +%Y-%m-%d > "$stamp" 2>/dev/null || true
}

show_logs() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true

    # Resolve today's log path
    local today_log="$LOG_DIR/mini-bowling-$(date '+%Y-%m-%d').log"

    case "$subcmd" in
        list)
            if [[ ! -d "$LOG_DIR" ]]; then
                echo "Log directory not found: $LOG_DIR"
                return 0
            fi

            local files
            mapfile -t files < <(find "$LOG_DIR" -maxdepth 1 -name "mini-bowling-*.log" \
                                      2>/dev/null | sort -r | head -30)

            if [[ ${#files[@]} -eq 0 ]]; then
                echo "No log files found in $LOG_DIR"
                return 0
            fi

            echo "Log files in $LOG_DIR (most recent first):"
            for f in "${files[@]}"; do
                printf "  %-45s  %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
            done
            echo
            echo "Commands:"
            echo "  mini-bowling.sh logs follow              live follow today's log"
            echo "  mini-bowling.sh logs dump                full output of today's log"
            echo "  mini-bowling.sh logs dump --date YYYY-MM-DD   full output of a specific day"
            echo "  mini-bowling.sh logs tail [N]            last N lines of today's log (default: 50)"
            echo "  mini-bowling.sh logs tail [N] --date YYYY-MM-DD  last N lines of a specific day"
            echo "  mini-bowling.sh logs clean               delete all log files"
            echo "  mini-bowling.sh logs clean --keep 7      delete all but the last 7 days"
            ;;

        follow)
            [[ -f "$today_log" ]] || die "No log file for today: $today_log"
            # Warn if today's log is empty - likely just past midnight
            if [[ ! -s "$today_log" ]]; then
                local yesterday_log
                yesterday_log="$LOG_DIR/mini-bowling-$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || \
                    date -v-1d '+%Y-%m-%d' 2>/dev/null).log"
                if [[ -f "$yesterday_log" ]]; then
                    echo -e "${YELLOW}Note: today's log is empty — recent entries may be in yesterday's log:${NC}"
                    echo "  mini-bowling.sh logs dump --date $(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || date -v-1d '+%Y-%m-%d' 2>/dev/null)"
                    echo
                fi
            fi
            echo "Following $today_log  (Ctrl+C to exit)"
            echo "----------------------------------------"
            tail -f "$today_log"
            ;;

        dump)
            # Parse optional --date YYYY-MM-DD
            local target_log="$today_log"
            if [[ "${1:-}" == "--date" ]]; then
                local date_arg="${2:?Missing date after --date (format: YYYY-MM-DD)}"
                [[ "$date_arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || \
                    die "Invalid date format: '$date_arg' — expected YYYY-MM-DD"
                target_log="$LOG_DIR/mini-bowling-${date_arg}.log"
            fi
            [[ -f "$target_log" ]] || die "No log file found: $target_log"
            echo "=== $target_log ==="
            echo
            cat "$target_log"
            ;;

        tail)
            # Parse: tail [N] [--date YYYY-MM-DD]  (in any order)
            local n=50
            local target_log="$today_log"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --date)
                        local date_arg="${2:?Missing date after --date (format: YYYY-MM-DD)}"
                        [[ "$date_arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || \
                            die "Invalid date format: '$date_arg' — expected YYYY-MM-DD"
                        target_log="$LOG_DIR/mini-bowling-${date_arg}.log"
                        shift 2
                        ;;
                    [0-9]*)
                        n="$1"
                        shift
                        ;;
                    *)
                        die "Unexpected argument for logs tail: '$1'"
                        ;;
                esac
            done
            [[ -f "$target_log" ]] || die "No log file found: $target_log"
            echo "=== Last $n lines of $target_log ==="
            echo
            tail -n "$n" "$target_log"
            ;;

        clean)
            if [[ ! -d "$LOG_DIR" ]]; then
                echo "Log directory not found: $LOG_DIR"
                return 0
            fi

            # Parse optional --keep N argument
            local keep=0
            if [[ "${1:-}" == "--keep" ]]; then
                keep="${2:?Missing number after --keep}"
                [[ "$keep" =~ ^[0-9]+$ ]] || die "Invalid --keep value: '$keep' — must be a number"
            elif [[ "${1:-}" == --keep=* ]]; then
                keep="${1#--keep=}"
                [[ "$keep" =~ ^[0-9]+$ ]] || die "Invalid --keep value: '$keep' — must be a number"
            fi

            local all_files
            mapfile -t all_files < <(find "$LOG_DIR" -maxdepth 1 -name "mini-bowling-*.log" 2>/dev/null | sort -r)

            if [[ ${#all_files[@]} -eq 0 ]]; then
                echo "No log files to remove."
                return 0
            fi

            # Determine which files to delete
            local log_files=()
            if [[ "$keep" -gt 0 ]]; then
                # Skip the first $keep files (most recent), delete the rest
                log_files=("${all_files[@]:$keep}")
                if [[ ${#log_files[@]} -eq 0 ]]; then
                    echo "Nothing to remove — only ${#all_files[@]} log file(s) exist, keeping all $keep."
                    return 0
                fi
                echo "Keeping $keep most recent log file(s), removing ${#log_files[@]}:"
            else
                log_files=("${all_files[@]}")
                echo "This will remove all ${#log_files[@]} log file(s):"
            fi

            local total_kb=0
            for f in "${log_files[@]}"; do
                local kb
                kb=$(du -k "$f" | cut -f1)
                total_kb=$(( total_kb + kb ))
                echo "  $(basename "$f")  ($(du -h "$f" | cut -f1))"
            done
            echo "Total: $(( total_kb / 1024 ))MB"
            echo -n "Are you sure? [y/N]: "
            read -r confirm
            if [[ "${confirm,,}" != "y" ]]; then
                echo "Cancelled."
                return 0
            fi
            for f in "${log_files[@]}"; do
                rm -f -- "$f"
            done
            # Only remove deploy status when doing a full clean (keep=0)
            if [[ "$keep" -eq 0 ]]; then
                rm -f "$DEPLOY_STATUS_FILE" 2>/dev/null || true
                echo -e "${GREEN}✓ Removed ${#log_files[@]} log file(s) and deploy status record${NC}"
            else
                echo -e "${GREEN}✓ Removed ${#log_files[@]} log file(s)${NC}"
            fi
            ;;

        *)
            die "Unknown logs subcommand: '$subcmd' — use list, follow, dump [--date YYYY-MM-DD], tail [N] [--date YYYY-MM-DD], or clean"
            ;;
    esac
}

deploy_history() {
    local limit=20
    [[ "${1:-}" =~ ^[0-9]+$ ]] && { limit="$1"; shift; }

    echo "=== Deploy History (last $limit) ==="
    echo

    if [[ ! -d "$LOG_DIR" ]]; then
        echo "Log directory not found: $LOG_DIR"
        return 0
    fi

    # Collect all log files sorted newest-first
    local log_files=()
    mapfile -t log_files < <(find "$LOG_DIR" -maxdepth 1 -name "mini-bowling-*.log" \
        2>/dev/null | sort -r)

    if [[ ${#log_files[@]} -eq 0 ]]; then
        echo "No log files found — run a deploy first."
        return 0
    fi

    # Extract deploy header lines: lines starting with a timestamp followed by deploy command
    # Log format: "YYYY-MM-DD HH:MM:SS  mini-bowling.sh deploy ..."
    local count=0
    local found_any=false
    for log in "${log_files[@]}"; do
        while IFS= read -r line; do
            [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ +mini-bowling\.sh\ (deploy.*)$ ]] || continue
            local ts="${BASH_REMATCH[1]}"
            local args="${BASH_REMATCH[2]}"
            printf "  %-22s  %s\n" "$ts" "$args"
            (( ++count ))
            found_any=true
            [[ $count -ge $limit ]] && break 2
        done < "$log"
    done

    if ! $found_any; then
        echo "No deploy entries found in logs."
        echo "  (Logs only capture commands run after logging was introduced.)"
    else
        echo
        echo "  $count deploy(s) shown  |  full logs: mini-bowling.sh logs"
    fi
}

require_project_dir() {
    [[ -d "$PROJECT_DIR" ]] || die "Project directory not found: $PROJECT_DIR
  Run: mini-bowling.sh install setup"
}

require_git_repo() {
    require_project_dir
    [[ -d "$PROJECT_DIR/.git" ]] || die "Project directory is not a git repository: $PROJECT_DIR
  If you haven't cloned the repo yet, run: mini-bowling.sh install
  Or clone manually: git clone <repo-url> \"$PROJECT_DIR\""
}

# Add ~/.local/bin to PATH for current session if arduino-cli lives there
_ensure_local_bin_path() {
    if [[ ":$PATH:" != *":${HOME}/.local/bin:"* ]] && [[ -x "${HOME}/.local/bin/arduino-cli" ]]; then
        export PATH="${HOME}/.local/bin:$PATH"
    fi
}

# Ensure arduino-cli is available before commands that need it
require_arduino_cli() {
    _ensure_local_bin_path
    command -v arduino-cli >/dev/null 2>&1 || \
        die "arduino-cli not found. Run: mini-bowling.sh install cli"
}

arduino_core_installed() {
    _ensure_local_bin_path
    command -v arduino-cli >/dev/null 2>&1 || return 1
    arduino-cli core list 2>/dev/null | awk '{print $1}' | grep -qx "$ARDUINO_CORE"
}

require_arduino_core() {
    arduino_core_installed || \
        die "Arduino core missing: $ARDUINO_CORE. Run: arduino-cli core install $ARDUINO_CORE"
}

require_arduino_libs() {
    _ensure_local_bin_path
    command -v arduino-cli >/dev/null 2>&1 || \
        die "arduino-cli not found. Run: mini-bowling.sh install cli"
    local _ral_list _ral_missing=()
    _ral_list=$(arduino-cli lib list 2>/dev/null)
    local _ral_lib
    for _ral_lib in "${ARDUINO_LIBS[@]}"; do
        echo "$_ral_list" | grep -qF "$_ral_lib" || _ral_missing+=("$_ral_lib")
    done
    (( ${#_ral_missing[@]} == 0 )) || \
        die "Missing Arduino libraries: ${_ral_missing[*]} — run: mini-bowling.sh install cli"
}

install_arduino_core() {
    require_arduino_cli

    if arduino_core_installed; then
        echo -e "${GREEN}→ Arduino core already installed:${NC} $ARDUINO_CORE"
        return 0
    fi

    echo "→ Installing Arduino core: $ARDUINO_CORE"
    arduino-cli core install "$ARDUINO_CORE" || \
        die "Failed to install Arduino core: $ARDUINO_CORE"
    echo -e "${GREEN}✓ Arduino core installed:${NC} $ARDUINO_CORE"
}

arduino_lib_installed() {
    local lib="$1"
    command -v arduino-cli >/dev/null 2>&1 || return 1
    arduino-cli lib list 2>/dev/null | grep -qF "$lib"
}

install_arduino_libs() {
    require_arduino_cli

    echo "→ Updating arduino-cli package index..."
    arduino-cli update 2>/dev/null || echo -e "${YELLOW}Warning: arduino-cli update failed${NC}"

    local lib failed=0
    for lib in "${ARDUINO_LIBS[@]}"; do
        if arduino_lib_installed "$lib"; then
            echo -e "${GREEN}→ Library already installed:${NC} $lib"
        else
            echo "→ Installing library: $lib"
            if arduino-cli lib install "$lib" 2>/dev/null; then
                echo -e "${GREEN}✓ Installed:${NC} $lib"
            else
                echo -e "${RED}✗ Failed to install:${NC} $lib"
                (( ++failed ))
            fi
        fi
    done

    if (( failed == 0 )); then
        echo -e "${GREEN}✓ All required Arduino libraries installed${NC}"
    else
        echo -e "${YELLOW}Warning: $failed library install(s) failed — run manually: arduino-cli lib install \"<name>\"${NC}"
    fi
}

upgrade_arduino_components() {
    require_arduino_cli

    echo "→ Updating arduino-cli index..."
    arduino-cli update || echo -e "${YELLOW}Warning: arduino-cli update failed${NC}"
    echo "→ Upgrading installed cores and libraries..."
    arduino-cli upgrade || echo -e "${YELLOW}Warning: arduino-cli upgrade failed${NC}"
    echo -e "${GREEN}✓ Arduino components up to date${NC}"
}

find_arduino_port() {
    local port="${PORT:-$DEFAULT_PORT}"

    if [[ -c "$port" ]]; then
        echo "$port"
        return 0
    fi

    # Simple fallback detection
    for candidate in /dev/ttyACM* /dev/ttyUSB* /dev/cu.usbmodem* /dev/serial/by-id/*; do
        if [[ -c "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    # Return empty and non-zero - callers using $() must check the result
    return 1
}

# Confirm arduino-cli can actually see the board on the given port
verify_arduino_port() {
    local port="$1"

    # Guard against empty port - means find_arduino_port failed inside $()
    [[ -z "$port" ]] && die "No Arduino serial port found — is the Arduino connected?"

    echo "→ Verifying Arduino on $port..."

    # Check the port device actually exists - that's all we need to proceed.
    # arduino-cli board list often fails to identify the board type even when
    # the port is perfectly usable (e.g. unrecognised VID/PID, missing index).
    if [[ ! -c "$port" ]]; then
        die "Port $port does not exist — is the Arduino connected and the cable data-capable?"
    fi

    echo -e "${GREEN}→ Arduino detected on $port${NC}"
}

resolve_display() {
    local display="${DISPLAY:-}"

    # When running over SSH, $DISPLAY may be set to an X11-forwarded address
    # (e.g. localhost:10.0) pointing back to the SSH client.  ScoreMore must
    # open on the Pi's own local display, so ignore any forwarded value.
    if [[ -n "${SSH_CLIENT:-}${SSH_TTY:-}" && -n "$display" ]]; then
        display=""
    fi

    if [[ -z "$display" ]]; then
        # Try to find a display from any logged-in X session without relying on grep -P.
        display=$(who 2>/dev/null | awk '
            {
                if (match($NF, /:[0-9]+/)) {
                    print substr($NF, RSTART, RLENGTH)
                    exit
                }
            }
        ' || true)
    fi

    if [[ -z "$display" ]]; then
        display="localhost:0.0"
        echo -e "${YELLOW}Warning: DISPLAY not set — defaulting to localhost:0.0. If ScoreMore doesn't appear, set DISPLAY manually.${NC}" >&2
    fi

    echo "$display"
}

detected_platform_summary() {
    local arch_dpkg arch_kernel bits
    arch_dpkg=$(dpkg --print-architecture 2>/dev/null || echo "unknown")
    arch_kernel=$(uname -m 2>/dev/null || echo "unknown")
    bits=$(getconf LONG_BIT 2>/dev/null || echo "unknown")
    printf "%s / %s / %s-bit" "$arch_dpkg" "$arch_kernel" "$bits"
}

scoremore_platform_supported() {
    local arch_dpkg arch_kernel bits
    arch_dpkg=$(dpkg --print-architecture 2>/dev/null || echo "")
    arch_kernel=$(uname -m 2>/dev/null || echo "")
    bits=$(getconf LONG_BIT 2>/dev/null || echo "")

    [[ "$bits" == "64" ]] || return 1
    [[ "$arch_dpkg" == "arm64" || "$arch_kernel" == "aarch64" || "$arch_kernel" == "arm64" ]]
}

appimage_runtime_ready() {
    [[ "${APPIMAGE_EXTRACT_AND_RUN:-}" == "1" ]] && return 0
    command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2' && return 0
    return 1
}

configure_appimage_runtime() {
    if appimage_runtime_ready; then
        return 0
    fi

    # Raspberry Pi OS Bookworm and other newer distros may not ship libfuse2 by
    # default. AppImage supports extract-and-run as a fallback.
    export APPIMAGE_EXTRACT_AND_RUN=1
}

prepare_scoremore_launch_env() {
    local runtime_dir="${XDG_RUNTIME_DIR:-}"
    local wayland_display="${WAYLAND_DISPLAY:-}"
    local display="${DISPLAY:-}"

    if [[ -z "$runtime_dir" ]]; then
        local candidate="/run/user/$(id -u)"
        [[ -d "$candidate" ]] && runtime_dir="$candidate"
    fi

    if [[ -z "$wayland_display" && -n "$runtime_dir" ]]; then
        for sock in wayland-0 wayland-1; do
            if [[ -S "$runtime_dir/$sock" ]]; then
                wayland_display="$sock"
                break
            fi
        done
    fi

    # resolve_display handles SSH forwarding override; always call it so the
    # SSH case clears a forwarded $DISPLAY and falls back to the local display.
    display=$(resolve_display)

    [[ -n "$runtime_dir" ]] && export XDG_RUNTIME_DIR="$runtime_dir"
    [[ -n "$wayland_display" ]] && export WAYLAND_DISPLAY="$wayland_display"
    [[ -n "$display" ]] && export DISPLAY="$display"

    configure_appimage_runtime
}

extract_scoremore_version() {
    local page="${1:-}"
    local version=""

    version=$(printf '%s\n' "$page" | \
        sed -n "s/.*ScoreMore-\\([0-9][0-9.]*\\)-${ARCH}\\.${EXTENSION}.*/\\1/p" | \
        head -1)

    if [[ -z "$version" ]]; then
        version=$(printf '%s\n' "$page" | \
            sed -n 's/.*ScoreMore \([0-9][0-9.]*\),\{0,1\} Latest.*/\1/p' | \
            head -1)
    fi

    echo "$version"
}

# Returns the version string of the currently installed ScoreMore AppImage
# (resolved via the Desktop symlink). Prints nothing if not installed.
get_installed_scoremore_version() {
    [[ -L "$SYMLINK_PATH" ]] || return 0
    basename "$(readlink -f "$SYMLINK_PATH" 2>/dev/null)" | \
        sed -n "s/^ScoreMore-\\(.*\\)-${ARCH}\\.${EXTENSION}$/\\1/p"
}

# ------------------------------------------------
#  Shared micro-helpers (used throughout the script)
# ------------------------------------------------

# Returns the normalized current branch name for $PROJECT_DIR.
# Strips refs/heads/ and heads/ prefixes; maps detached HEAD to DEFAULT_GIT_BRANCH.
_current_branch() {
    local b
    b=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$DEFAULT_GIT_BRANCH")
    b="${b#refs/heads/}"
    b="${b#heads/}"
    [[ "$b" == "HEAD" ]] && b="$DEFAULT_GIT_BRANCH"
    echo "$b"
}

# Returns the PID of the running ScoreMore process, or empty if not running.
_scoremore_pid() {
    pgrep -f "ScoreMore.*AppImage" 2>/dev/null | head -1 || true
}

# Prints the current crontab, or nothing if no crontab exists.
_read_crontab() {
    crontab -l 2>/dev/null || true
}

# Fetches the latest ScoreMore version string from scoremorebowling.com.
# Returns empty string on any failure (network down, parse error).
# Callers that need a hard failure should check the return and die themselves.
_fetch_latest_scoremore_version() {
    local page
    page=$(curl --silent --fail --max-time 10 \
        "https://www.scoremorebowling.com/download" 2>/dev/null) || true
    [[ -n "$page" ]] || { echo ""; return 0; }
    extract_scoremore_version "$page"
}

# Generic cron-job manager.  Handles the enable/disable/status plumbing that is
# identical across all four scheduled-task helpers.
#
#   _cron_manage enable  <marker> <label> <full-cron-line>
#   _cron_manage disable <marker> <label>
#   _cron_manage status  <marker> <label>
_cron_manage() {
    local subcmd="$1" marker="$2" label="$3"
    local existing; existing=$(_read_crontab)
    case "$subcmd" in
        enable)
            local cron_job="${4?_cron_manage: cron job line required as \$4}"
            if echo "$existing" | grep -q "$marker"; then
                echo "$label already enabled — removing old entry first."
                existing=$(echo "$existing" | grep -v "$marker" || true)
            fi
            { [[ -n "$existing" ]] && echo "$existing"; echo "$cron_job"; } \
                | crontab - || die "Failed to update crontab"
            ;;
        disable)
            if ! echo "$existing" | grep -q "$marker"; then
                echo "$label cron job not found — nothing to remove."
                return 0
            fi
            echo "$existing" | { grep -v "$marker" || true; } | crontab - \
                || die "Failed to update crontab"
            echo -e "${GREEN}✓ $label cron job removed.${NC}"
            ;;
        status)
            local entry; entry=$(echo "$existing" | { grep "$marker" || true; })
            if [[ -n "$entry" ]]; then
                local min hr
                min=$(echo "$entry" | awk '{print $1}')
                hr=$(echo "$entry"  | awk '{print $2}')
                if [[ "$min" == *"/"* ]]; then
                    echo -e "$label : ${GREEN}enabled${NC} — every ${min#*/} minutes"
                else
                    echo -e "$label : ${GREEN}enabled${NC} — daily at $(printf '%02d:%02d' "$hr" "$min")"
                fi
            else
                echo "$label : disabled"
            fi
            ;;
    esac
}

# Reads $ARDUINO_STATUS_FILE and populates _ard_sketch, _ard_time,
# _ard_commit, _ard_msg, _ard_branch.
# Returns 1 (and clears the vars) if the file does not exist.
_read_arduino_status() {
    _ard_sketch="" _ard_time="" _ard_commit="" _ard_msg="" _ard_branch=""
    [[ -f "$ARDUINO_STATUS_FILE" ]] || return 1
    local _ard_lines
    mapfile -t _ard_lines < "$ARDUINO_STATUS_FILE"
    _ard_sketch="${_ard_lines[0]:-}"
    _ard_time="${_ard_lines[1]:-}"
    _ard_commit="${_ard_lines[2]:-}"
    _ard_msg="${_ard_lines[3]:-}"
    _ard_branch="${_ard_lines[4]:-}"
}

kill_scoremore_gracefully() {
    # Target the AppImage launcher by full path - killing the parent brings down
    # the entire Electron process tree that spawns under /tmp/.mount_ScoreM*/
    local pid
    pid=$(_scoremore_pid)
    [[ -z "$pid" ]] && return 0

    echo "Found ScoreMore AppImage (pid $pid) — sending SIGTERM..."
    kill -- "$pid" 2>/dev/null || true

    local timeout=10
    while kill -0 -- "$pid" 2>/dev/null && [[ $timeout -gt 0 ]]; do
        sleep 1
        timeout=$(( timeout - 1 ))
    done

    if kill -0 -- "$pid" 2>/dev/null; then
        echo "→ still running after timeout → sending SIGKILL"
        kill -9 -- "$pid" 2>/dev/null || true
        echo "→ killed (forced)"
    else
        echo "→ stopped gracefully"
    fi

    # Safety net: catch any orphaned scoremore processes that didn't die with the parent
    if pgrep -f "scoremore" >/dev/null 2>&1; then
        echo "→ cleaning up orphaned scoremore processes..."
        pkill -f "scoremore" 2>/dev/null || true
        sleep 1
        pkill -9 -f "scoremore" 2>/dev/null || true
    fi
}

# Pure launcher - callers are responsible for killing ScoreMore first if needed
start_scoremore() {
    prepare_scoremore_launch_env
    # Redirect output to avoid nohup.out clutter; disown so it survives terminal close
    nohup "$HOME/Desktop/ScoreMore.AppImage" > /dev/null 2>&1 &
    disown
    local session_bits=()
    [[ -n "${DISPLAY:-}" ]] && session_bits+=("DISPLAY=${DISPLAY}")
    [[ -n "${WAYLAND_DISPLAY:-}" ]] && session_bits+=("WAYLAND_DISPLAY=${WAYLAND_DISPLAY}")
    [[ "${APPIMAGE_EXTRACT_AND_RUN:-}" == "1" ]] && session_bits+=("APPIMAGE_EXTRACT_AND_RUN=1")
    echo -e "${GREEN}→ ScoreMore launched${NC}${session_bits:+  (${session_bits[*]})}"
}

scoremore_is_running() {
    [[ -n "$(_scoremore_pid)" ]]
}

print_status() {
    local port
    port=$(find_arduino_port 2>/dev/null || echo "not found")

    echo "Project dir : $PROJECT_DIR"
    echo "Port        : $port"
    [[ -c "$port" ]] && echo "Arduino     : detected" || echo "Arduino     : NOT detected"

    if _read_arduino_status; then
        if [[ -n "$_ard_msg" ]]; then
            echo "Sketch      : $_ard_sketch  ($_ard_commit — $_ard_msg)  @ $_ard_time"
        else
            echo "Sketch      : $_ard_sketch  ($_ard_commit)  @ $_ard_time"
        fi
    else
        echo "Sketch      : unknown (no upload recorded)"
    fi

    # Git repo state
    if [[ -d "$PROJECT_DIR/.git" ]]; then
        local git_branch git_commit git_subject git_behind git_dirty
        git_branch=$(_current_branch)
        git_commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        git_subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo "")
        git -C "$PROJECT_DIR" fetch --quiet origin "$git_branch" 2>/dev/null || true
        git_behind=$(git -C "$PROJECT_DIR" rev-list "HEAD..origin/${git_branch}" --count 2>/dev/null || echo "?")
        if git -C "$PROJECT_DIR" diff --quiet 2>/dev/null && \
           git -C "$PROJECT_DIR" diff --cached --quiet 2>/dev/null; then
            git_dirty=""
        else
            git_dirty="  (uncommitted changes)"
        fi
        local git_behind_label=""
        if [[ "$git_behind" != "0" && "$git_behind" != "?" ]]; then
            git_behind_label="  ${YELLOW}↓ $git_behind commit(s) behind remote${NC}"
        elif [[ "$git_behind" == "0" ]]; then
            git_behind_label="  (up to date)"
        fi
        echo -e "Git branch  : $git_branch  [$git_commit] $git_subject${git_dirty}${git_behind_label}"
    else
        echo "Git branch  : not a git repo"
    fi

    local sm_pid
    sm_pid=$(_scoremore_pid)
    local sm_ver; sm_ver=$(get_installed_scoremore_version)
    local sm_autostart="no autostart"
    [[ -f "$HOME/.config/autostart/scoremore.desktop" ]] && sm_autostart="autostart enabled"

    if [[ -n "$sm_pid" ]]; then
        local sm_label="running"
        [[ -n "$sm_ver" ]] && sm_label="running v${sm_ver}"
        echo "ScoreMore   : $sm_label  (pid $sm_pid, $sm_autostart)"
    else
        echo "ScoreMore   : not running  ($sm_autostart)"
    fi

    local cron_marker_sched="# mini-bowling scheduled deploy"
    local cron_entry
    cron_entry=$(_read_crontab | grep "$cron_marker_sched" || true)
    if [[ -n "$cron_entry" ]]; then
        local cron_min cron_hour
        cron_min=$(echo "$cron_entry" | awk '{print $1}')
        cron_hour=$(echo "$cron_entry" | awk '{print $2}')
        printf "Deploy sched: daily at %02d:%02d  (Everything)\n" "$cron_hour" "$cron_min"
    else
        echo "Deploy sched: not set"
    fi

    local cron_marker_wd="# mini-bowling watchdog"
    local wd_entry
    wd_entry=$(_read_crontab | grep "$cron_marker_wd" || true)
    if [[ -n "$wd_entry" ]]; then
        echo "Watchdog    : enabled (every 5 min)"
    else
        echo "Watchdog    : disabled"
    fi

    local pid_file="/tmp/mini-bowling-serial.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        echo "Serial log  : running (pid $(cat "$pid_file"))"
    else
        echo "Serial log  : not running"
    fi

    # VNC status - single line summary
    local vnc_line="not installed"
    if command -v vncserver >/dev/null 2>&1 || command -v x11vnc >/dev/null 2>&1; then
        local vnc_svc_running=false
        for svc in vncserver-x11-serviced vncserver-virtuald tigervnc x11vnc vncserver; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                vnc_svc_running=true; break
            fi
        done
        local vnc_proc_running=false
        pgrep -f "Xvnc\|vncserver\|x11vnc" >/dev/null 2>&1 && vnc_proc_running=true

        local vnc_autostart="no autostart"
        for svc in vncserver-x11-serviced vncserver-virtuald tigervnc x11vnc; do
            if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                vnc_autostart="autostart enabled"; break
            fi
        done

        if $vnc_svc_running || $vnc_proc_running; then
            local lan_ip
            lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
            vnc_line="running — ${lan_ip:-<Pi IP>}:5900  ($vnc_autostart)"
        else
            vnc_line="installed, not running  ($vnc_autostart)"
        fi
    fi
    echo "VNC         : $vnc_line"

    # OS package update check (uses local apt cache — no sudo, no network)
    if command -v apt-get >/dev/null 2>&1; then
        local pkg_count
        pkg_count=$(apt-get -s upgrade 2>/dev/null | { grep "^Inst " || true; } | wc -l)
        if [[ -f /var/run/reboot-required ]]; then
            echo -e "OS updates  : ${YELLOW}reboot required to apply pending updates${NC}"
        elif [[ "$pkg_count" -gt 0 ]]; then
            echo -e "OS updates  : ${YELLOW}${pkg_count} package(s) available — run: mini-bowling.sh pi update${NC}"
        else
            echo -e "OS updates  : ${GREEN}up to date${NC}"
        fi
    fi

    # Item 5: show last deploy result
    if [[ -f "$DEPLOY_STATUS_FILE" ]]; then
        local started finished result dep_commit dep_subject
        started=$(sed -n '1p'    "$DEPLOY_STATUS_FILE")
        finished=$(sed -n '2p'   "$DEPLOY_STATUS_FILE")
        result=$(sed -n '3p'     "$DEPLOY_STATUS_FILE")
        dep_commit=$(sed -n '4p' "$DEPLOY_STATUS_FILE")
        dep_subject=$(sed -n '5p' "$DEPLOY_STATUS_FILE")
        local dep_label=""
        [[ -n "$dep_commit" ]] && dep_label=" — $dep_commit"
        [[ -n "$dep_subject" ]] && dep_label="$dep_label: $dep_subject"
        if [[ "$result" == "OK" ]]; then
            echo -e "Last deploy : ${GREEN}OK${NC} at $finished${dep_label}"
        else
            echo -e "Last deploy : ${RED}FAILED${NC} (started $started)${dep_label}"
        fi
    else
        echo "Last deploy : no record"
    fi
}

extract_folder_version() {
    local ver="$1"
    # Pure bash: strip the last .patch segment (works for x.y.z and x.y)
    echo "${ver%.*}"
}

create_or_update_symlink() {
    local target="$1"
    local symlink="$SYMLINK_PATH"

    local real_target
    real_target=$(realpath -- "$target" 2>/dev/null) || die "Cannot resolve realpath of $target"

    if [[ -L "$symlink" ]] && [[ "$(readlink -f -- "$symlink")" = "$real_target" ]]; then
        echo -e "${GREEN}Symlink already correct:${NC} $symlink"
        return 0
    fi

    [[ -e "$symlink" || -L "$symlink" ]] && rm -f -- "$symlink" && echo -e "${YELLOW}Removed old symlink${NC}"

    ln -sf -- "$real_target" "$symlink" && {
        echo -e "${GREEN}✓ Desktop symlink updated:${NC} $symlink → $target"
    } || echo -e "${YELLOW}Warning:${NC} Could not create symlink (permissions?)"
}

download_scoremore_version() {
    local full_ver="$1"

    # Basic semver-like validation
    [[ "$full_ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?$ ]] || die "Version format looks invalid: $full_ver"

    local folder_ver
    folder_ver=$(extract_folder_version "$full_ver")

    local filename="${APP_NAME}-${full_ver}-${ARCH}.${EXTENSION}"
    local url="${BASE_URL}/${folder_ver}/${filename}"

    # Ensure directory exists
    mkdir -p "$SCOREMORE_DIR" || die "Cannot create $SCOREMORE_DIR"

    local filepath="$SCOREMORE_DIR/$filename"

    # Item 2: check available disk space (require at least 300MB free)
    local avail_kb
    avail_kb=$(df -k "$SCOREMORE_DIR" | awk 'NR==2 {print $4}')
    local required_kb=$(( 300 * 1024 ))
    if (( avail_kb < required_kb )); then
        local avail_mb=$(( avail_kb / 1024 ))
        die "Insufficient disk space: ${avail_mb}MB free, 300MB required. Free up space and try again."
    fi

    if [[ -e "$filepath" ]]; then
        echo "\"$filename\" exists, removing the file"
        rm -- "$filepath"
    fi

    echo -e "${YELLOW}Downloading:${NC} $filename"
    echo "  → $url"

    # Capture curl exit code properly
    local curl_exit=0
    curl --fail --location --progress-bar --continue-at - \
         --output "$filepath" "$url" || curl_exit=$?

    if (( curl_exit != 0 )); then
        echo -e "${RED}Download failed${NC} (curl code $curl_exit)"
        [[ $curl_exit -eq 22 ]] && echo -e "${YELLOW}→ Likely 404 — check version${NC}" || true
        return 1
    fi

    echo -e "\n${GREEN}✓ Downloaded:${NC} $filename"
    ls -lh -- "$filepath" 2>/dev/null
    chmod +x -- "$filepath" && echo -e "${GREEN}→ Made executable${NC}"

    # Item 6: verify file is not empty or truncated
    local file_size
    file_size=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo 0)
    if (( file_size < 1048576 )); then
        die "Downloaded file is suspiciously small (${file_size} bytes) — download may be corrupt"
    fi

    # Show hash for manual verification
    echo "SHA256:"
    command -v sha256sum >/dev/null && sha256sum -- "$filepath" || \
    command -v shasum    >/dev/null && shasum -a 256 -- "$filepath" || \
        echo "  (no sha256 tool available)"

    # Verify the AppImage is executable before switching the symlink
    echo "Verifying AppImage..."
    local appimage_path="$filepath"
    configure_appimage_runtime
    if ! timeout 10 "$appimage_path" --version >/dev/null 2>&1 && \
       ! timeout 10 "$appimage_path" --appimage-version >/dev/null 2>&1; then
        # AppImage may not support --version but should at least be executable
        # A corrupt download typically fails immediately; a valid one exits quickly
        if ! timeout 5 bash -c "\"$appimage_path\" --help >/dev/null 2>&1"; then
            echo -e "${YELLOW}Warning: could not verify AppImage launches — it may be corrupt.${NC}"
            echo "  The old symlink will NOT be updated. Check the file and retry."
            echo "  File: $appimage_path"
            return 1
        fi
    fi
    echo -e "${GREEN}✓ AppImage verified${NC}"

    local was_running=false
    if scoremore_is_running; then
        was_running=true
        kill_scoremore_gracefully
        sleep 5
    fi

    create_or_update_symlink "$filepath"
    if $was_running; then
        start_scoremore
    else
        echo "ScoreMore was not running — symlink updated without launching it."
    fi
}

list_branches() {
    require_git_repo

    echo "Fetching branch list from remote..."
    git -C "$PROJECT_DIR" fetch --quiet origin 2>/dev/null || echo -e "${YELLOW}Warning: fetch failed — showing local branches only${NC}"

    local current
    current=$(_current_branch)

    echo
    echo "Branches in $PROJECT_DIR:"
    echo "----------------------------------------------"

    # Collect all local and remote branches, deduplicated
    local branches
    branches=$(git -C "$PROJECT_DIR" branch -a 2>/dev/null | \
        sed 's|^\*\? *||;s|remotes/origin/||' | \
        grep -v '^HEAD' | sort -u)

    while IFS= read -r b; do
        local marker="  "
        [[ "$b" == "$current" ]] && marker="${GREEN}→ ${NC}"
        local commit subject
        commit=$(git -C "$PROJECT_DIR" log -1 --format='%h' "origin/$b" 2>/dev/null || \
                 git -C "$PROJECT_DIR" log -1 --format='%h' "$b" 2>/dev/null || echo "?")
        subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' "origin/$b" 2>/dev/null || \
                  git -C "$PROJECT_DIR" log -1 --format='%s' "$b" 2>/dev/null || echo "")
        printf "${marker}  %-30s  [%s] %s\n" "$b" "$commit" "$subject"
    done <<< "$branches"

    echo
    echo "Usage:"
    echo "  mini-bowling.sh code sketch upload --Master_Test --branch feature/new-sensor"
    echo "  mini-bowling.sh code branch switch feature/new-sensor"
}

switch_branch() {
    local branch="${1:?Missing branch name — usage: mini-bowling.sh code branch switch <branch>}"

    require_git_repo

    local current
    current=$(_current_branch)

    if [[ "$current" == "$branch" ]]; then
        echo "Already on branch: $branch"
        echo "→ Pulling latest..."
        git -C "$PROJECT_DIR" pull --quiet origin "$branch" 2>/dev/null || \
            echo -e "${YELLOW}Warning: git pull failed${NC}"
        local commit subject
        commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo "")
        echo -e "${GREEN}✓ $branch is up to date:${NC} [$commit] $subject"
        return 0
    fi

    # Stash if dirty
    local was_dirty=false
    if ! git -C "$PROJECT_DIR" diff --quiet || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
        was_dirty=true
        local stash_name="mini-bowling-$(date '+%Y%m%d-%H%M%S')"
        echo -e "${YELLOW}Stashing local changes as:${NC} $stash_name"
        git -C "$PROJECT_DIR" stash push -m "$stash_name" || die "Stash failed"
        echo -e "  (restore with: git stash pop)"
    fi

    echo "→ Fetching latest from remote..."
    git -C "$PROJECT_DIR" fetch --quiet origin 2>/dev/null || echo -e "${YELLOW}Warning: fetch failed${NC}"

    echo -e "${YELLOW}Switching to branch:${NC} $branch"
    if git -C "$PROJECT_DIR" checkout --quiet "$branch" 2>/dev/null; then
        : # local branch
    elif git -C "$PROJECT_DIR" checkout --quiet -b "$branch" --track "origin/$branch" 2>/dev/null; then
        echo "  (created local tracking branch from origin/$branch)"
    else
        $was_dirty && git -C "$PROJECT_DIR" stash pop --quiet 2>/dev/null || true
        die "Cannot checkout '$branch' — run: mini-bowling.sh code branch list"
    fi

    echo "→ Pulling latest commits for $branch..."
    git -C "$PROJECT_DIR" pull --quiet origin "$branch" 2>/dev/null || \
        echo -e "${YELLOW}Warning: git pull failed — on local state of $branch${NC}"

    local commit subject
    commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo "")
    echo -e "${GREEN}✓ Switched to $branch:${NC} [$commit] $subject"
    echo
    echo -e "${YELLOW}Note:${NC} you are now permanently on branch '$branch'."
    echo "  To switch back: mini-bowling.sh code branch switch $DEFAULT_GIT_BRANCH"

    if $was_dirty; then
        echo
        echo -e "${YELLOW}Stashed changes were left behind — restore with: git stash pop${NC}"
    fi
}

list_available_sketches() {
    require_project_dir

    echo "Scanning for Arduino sketches in:"
    echo "  $PROJECT_DIR"
    echo "----------------------------------------------"

    # Load last-upload record if available
    local last_sketch="" last_time=""
    if _read_arduino_status; then
        last_sketch="$_ard_sketch"
        last_time="$_ard_time"
    fi

    local count=0
    local found=false

    while IFS= read -r -d '' dir; do
        local sketch_name
        sketch_name=$(basename "$dir")

        # Skip junk folders
        [[ $sketch_name == .* ]] && continue
        [[ $sketch_name =~ ^(build|cache|dist|tmp|node_modules|__.*|libraries|.claude)$ ]] && continue

        # Any .ino file in the folder?
        if find "$dir" -maxdepth 1 -type f -iname "*.ino" -print -quit 2>/dev/null | grep -q .; then
            count=$((count + 1))
            found=true
            local ino_file
            ino_file=$(find "$dir" -maxdepth 1 -type f -iname "*.ino" | head -n 1 2>/dev/null)
            local ino_name="<no .ino found>"
            [[ -n "$ino_file" ]] && ino_name=$(basename "$ino_file")

            if [[ -n "$last_sketch" && "$sketch_name" == "$last_sketch" ]]; then
                printf "  %2d)  %-24s   →  %-30s  ${GREEN}← last uploaded %s${NC}\n" \
                    "$count" "$sketch_name" "$ino_name" "$last_time"
            else
                printf "  %2d)  %-24s   →  %s\n" "$count" "$sketch_name" "$ino_name"
            fi
        fi
    done < <(find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

    if ! $found; then
        echo "→ No sketch folders containing .ino files were found."
        echo
        echo "Quick diagnostic commands:"
        echo "  cd \"$PROJECT_DIR\""
        echo "  ls -ld */"
        echo "  find . -maxdepth 2 -iname \"*.ino\""
        echo
        echo "Expected structure example:"
        echo "  Master_Test/Master_Test.ino"
        echo "  Everything/Everything.ino"
        exit 1
    fi

    echo "Found $count sketch folder(s)."
    echo
    echo "Usage:"
    echo "  mini-bowling.sh code sketch upload --Everything"
    echo "  mini-bowling.sh code sketch upload --Master_Test"
    echo "  mini-bowling.sh code sketch upload --YourFolderName"
}

cmd_sketch_info() {
    echo "=== Arduino Sketch Info ==="
    echo

    if ! _read_arduino_status; then
        echo "No upload recorded yet."
        echo "  Run: mini-bowling.sh code sketch upload --Everything"
        return 0
    fi

    local sketch="$_ard_sketch" time="$_ard_time" commit="$_ard_commit" \
          subject="$_ard_msg" branch="$_ard_branch"

    echo "Sketch      : $sketch"
    echo "Uploaded at : $time"
    echo "Commit      : $commit${subject:+  — $subject}"
    echo "Branch      : ${branch:-unknown}"

    # Compare recorded state to current repo HEAD
    if [[ -d "$PROJECT_DIR/.git" ]]; then
        local current_branch head_commit head_subject
        current_branch=$(_current_branch)
        head_commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "")
        head_subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo "")

        echo
        echo "Repo HEAD   : ${head_commit}${head_subject:+  — $head_subject}  (branch: $current_branch)"

        if [[ -n "$branch" && "$branch" != "unknown" && "$branch" != "$current_branch" ]]; then
            echo -e "${YELLOW}Branch mismatch:${NC} Arduino is on '$branch', repo is on '$current_branch'."
            echo "  Run: mini-bowling.sh code switch $branch  (to match Arduino)"
            echo "   or: mini-bowling.sh code sketch upload    (to deploy current branch)"
        elif [[ -n "$head_commit" && -n "$commit" && "$head_commit" != "$commit" ]]; then
            local ahead
            ahead=$(git -C "$PROJECT_DIR" rev-list "${commit}..HEAD" --count 2>/dev/null || echo "?")
            echo -e "${YELLOW}Deploy needed:${NC} Arduino has $commit, repo HEAD is $head_commit (+${ahead} commit(s))."
            echo "  Run: mini-bowling.sh deploy"
        else
            echo -e "${GREEN}✓ Arduino is up to date with repo HEAD${NC}"
        fi
    fi
}

cmd_config_tool() {
    local config_file="$PROJECT_DIR/config-tool/index.html"

    if [[ ! -f "$config_file" ]]; then
        die "Config tool not found: $config_file
  Is the Arduino project cloned? Run: mini-bowling.sh code branch update"
    fi

    local display
    display=$(resolve_display)
    export DISPLAY="$display"

    # Find a browser — prefer chromium for kiosk-style Pi use
    local browser=""
    for _b in chromium-browser chromium firefox epiphany xdg-open; do
        if command -v "$_b" >/dev/null 2>&1; then
            browser="$_b"
            break
        fi
    done

    [[ -z "$browser" ]] && die "No browser found — install chromium-browser or firefox"

    echo "Opening config tool: $config_file"
    echo "Browser: $browser  (DISPLAY=$display)"
    nohup "$browser" "$config_file" >/dev/null 2>&1 &
    disown
    echo -e "${GREEN}✓ Config tool opened${NC}"
}

_repo_summary() {
    local label="$1" dir="$2"
    if [[ ! -d "$dir/.git" ]]; then
        echo -e "  ${label}: ${YELLOW}not a git repo${NC}  ($dir)"
        return
    fi

    local branch dirty_flag remote_status
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    local head
    head=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "?")
    local subject
    subject=$(git -C "$dir" log -1 --format='%s' 2>/dev/null || echo "")

    if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
        dirty_flag="${YELLOW} (dirty)${NC}"
    else
        dirty_flag=""
    fi

    # Sync with remote
    git -C "$dir" fetch --quiet 2>/dev/null || true
    local ahead behind
    ahead=$(git -C "$dir" rev-list "origin/${branch}..HEAD" --count 2>/dev/null || echo "?")
    behind=$(git -C "$dir" rev-list "HEAD..origin/${branch}" --count 2>/dev/null || echo "?")

    if [[ "$ahead" == "0" && "$behind" == "0" ]]; then
        remote_status="${GREEN}✓ up to date${NC}"
    elif [[ "$ahead" != "0" && "$behind" == "0" ]]; then
        remote_status="${YELLOW}${ahead} commit(s) ahead of origin${NC}"
    elif [[ "$ahead" == "0" && "$behind" != "0" ]]; then
        remote_status="${YELLOW}${behind} commit(s) behind origin${NC} — run: pull"
    else
        remote_status="${RED}diverged (${ahead} ahead / ${behind} behind)${NC}"
    fi

    echo -e "  ${label}"
    echo -e "    Branch : $branch${dirty_flag}"
    echo    "    HEAD   : $head${subject:+  — $subject}"
    echo -e "    Remote : $remote_status"
}

cmd_code_status() {
    echo "=== Code Repository Status ==="
    echo

    # Script repo (if installed as git clone)
    local script_dir
    script_dir=$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")")
    if [[ -d "$script_dir/.git" ]]; then
        _repo_summary "Script repo  ($script_dir)" "$script_dir"
    else
        echo "  Script repo: not a git clone (installed as single file)"
    fi
    echo

    # Arduino project repo
    _repo_summary "Arduino repo ($PROJECT_DIR)" "$PROJECT_DIR"
    echo

    # Arduino sketch info
    if _read_arduino_status; then
        local sketch="$_ard_sketch" time="$_ard_time" commit="$_ard_commit" branch="$_ard_branch"
        local current_branch head_commit
        current_branch=$(_current_branch)
        head_commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "")
        echo "  Arduino board"
        echo "    Sketch  : $sketch  (uploaded $time)"
        echo "    Commit  : $commit  (branch: ${branch:-unknown})"
        if [[ -n "$head_commit" && "$head_commit" == "$commit" && "$branch" == "$current_branch" ]]; then
            echo -e "    Status  : ${GREEN}✓ up to date${NC}"
        else
            echo -e "    Status  : ${YELLOW}behind repo HEAD — run: mini-bowling.sh deploy${NC}"
        fi
    else
        echo "  Arduino board: no upload on record yet"
    fi

    echo

    # Arduino-cli and library status
    echo "  Arduino dependencies"
    if ! command -v arduino-cli >/dev/null 2>&1; then
        echo -e "    arduino-cli : ${RED}not installed — run: install cli${NC}"
    else
        local cs_cli_ver
        cs_cli_ver=$(arduino-cli version 2>/dev/null | awk '{print $3}' || echo "?")
        echo "    arduino-cli : v${cs_cli_ver}"
        if arduino_core_installed; then
            echo -e "    Core        : ${GREEN}✓ ${ARDUINO_CORE}${NC}"
        else
            echo -e "    Core        : ${RED}✗ ${ARDUINO_CORE} missing — run: install cli${NC}"
        fi
        local cs_lib_list cs_missing=()
        cs_lib_list=$(arduino-cli lib list 2>/dev/null)
        local cs_lib
        for cs_lib in "${ARDUINO_LIBS[@]}"; do
            echo "$cs_lib_list" | grep -qF "$cs_lib" || cs_missing+=("$cs_lib")
        done
        if (( ${#cs_missing[@]} == 0 )); then
            echo -e "    Libraries   : ${GREEN}✓ all ${#ARDUINO_LIBS[@]} required libraries installed${NC}"
        else
            echo -e "    Libraries   : ${RED}✗ missing: ${cs_missing[*]} — run: install cli${NC}"
        fi
    fi
}

cmd_code_board() {
    require_arduino_cli

    echo "=== Detected Arduino Boards ==="
    echo

    local board_list
    board_list=$(arduino-cli board list 2>/dev/null) || \
        die "arduino-cli board list failed — is arduino-cli installed?"

    echo "$board_list"
    echo

    # Highlight whether the expected port/board is found
    local port; port=$(find_arduino_port 2>/dev/null || echo "")

    if [[ -z "$port" ]]; then
        echo -e "${YELLOW}!${NC}  Expected port ($DEFAULT_PORT) not detected"
        echo "   Check USB cable or run: system ports"
    else
        # Check if the expected board FQBN appears on that port
        if echo "$board_list" | grep -q "$port"; then
            local board_line; board_line=$(echo "$board_list" | grep "$port")
            if echo "$board_line" | grep -qi "mega\|avr\|arduino"; then
                echo -e "${GREEN}✓${NC}  Arduino detected on $port"
            else
                echo -e "${YELLOW}!${NC}  Device on $port — board type not recognized as Arduino Mega"
                echo "   Expected FQBN: $BOARD"
            fi
        else
            echo -e "${YELLOW}!${NC}  Port $port found but not listed by arduino-cli"
            echo "   Try: system ports"
        fi
    fi

    echo
    echo "Expected board : $BOARD"
    echo "Expected port  : ${port:-$DEFAULT_PORT}"
}

cmd_code_reset() {
    local force=false apply_downloads=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)            force=true; shift ;;
            --apply-downloads)     apply_downloads=true; shift ;;
            *) die "Unexpected argument: $1" ;;
        esac
    done

    # Files to preserve across the reset
    local _cfg_sketch_dir="$PROJECT_DIR/Everything"
    local -a _user_cfg_files=(general_config.user.h pin_config.user.h)
    local _cfg_backup_dir
    _cfg_backup_dir=$(mktemp -d /tmp/mb-code-reset-cfg-XXXXXX)

    echo "=== Arduino Code Reset ==="
    echo
    echo -e "${YELLOW}This will permanently delete the local Arduino project directory:${NC}"
    echo "  $PROJECT_DIR"
    echo "and clone a fresh copy from:"
    echo "  $PROJECT_REPO"
    echo

    if ! $force; then
        read -r -p "Are you sure? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || { echo "Aborted."; rm -rf "$_cfg_backup_dir"; return 0; }
    fi

    # Save user config files before wiping the directory
    local _saved_any=false
    for _f in "${_user_cfg_files[@]}"; do
        local _src="$_cfg_sketch_dir/$_f"
        if [[ -f "$_src" ]]; then
            cp "$_src" "$_cfg_backup_dir/$_f" && _saved_any=true
            echo "→ Saved: $_f"
        fi
    done

    if [[ -d "$PROJECT_DIR" ]]; then
        echo "→ Removing $PROJECT_DIR..."
        rm -rf "$PROJECT_DIR" || { rm -rf "$_cfg_backup_dir"; die "Failed to remove $PROJECT_DIR"; }
        echo -e "${GREEN}✓ Removed local Arduino project directory${NC}"
    else
        echo "  (directory does not exist — skipping removal)"
    fi

    echo "→ Cloning from $PROJECT_REPO..."
    if ! git ls-remote --quiet "$PROJECT_REPO" HEAD >/dev/null 2>&1; then
        rm -rf "$_cfg_backup_dir"
        die "Cannot reach repo: $PROJECT_REPO — check network and try again"
    fi
    git clone "$PROJECT_REPO" "$PROJECT_DIR" || { rm -rf "$_cfg_backup_dir"; die "git clone failed"; }
    echo -e "${GREEN}✓ Arduino project cloned to $PROJECT_DIR${NC}"

    # Restore saved user config files into the fresh clone
    if $_saved_any; then
        echo "→ Restoring user config files..."
        mkdir -p "$_cfg_sketch_dir"
        for _f in "${_user_cfg_files[@]}"; do
            if [[ -f "$_cfg_backup_dir/$_f" ]]; then
                cp "$_cfg_backup_dir/$_f" "$_cfg_sketch_dir/$_f"
                echo -e "  ${GREEN}✓ Restored:${NC} $_f"
            fi
        done
    fi

    rm -rf "$_cfg_backup_dir"

    # Optionally apply config files from ~/Downloads (overwrite restored files)
    if ! $apply_downloads && ! $force; then
        local _dl_available=false
        for _f in "${_user_cfg_files[@]}"; do
            [[ -f "$HOME/Downloads/$_f" ]] && _dl_available=true && break
        done
        if $_dl_available; then
            echo
            echo "User config files found in ~/Downloads:"
            for _f in "${_user_cfg_files[@]}"; do
                [[ -f "$HOME/Downloads/$_f" ]] && echo "  $HOME/Downloads/$_f"
            done
            read -r -p "Apply these to Everything/ now? [y/N] " _apply_confirm
            [[ "${_apply_confirm,,}" == "y" ]] && apply_downloads=true
        fi
    fi

    if $apply_downloads; then
        _code_reset_apply_downloads "${_user_cfg_files[@]}"
    fi

    local commit subject
    commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo "")
    echo -e "  HEAD: [$commit] $subject"
}

# Copy user config files from ~/Downloads into Everything/, backing up existing files first.
_code_reset_apply_downloads() {
    local -a _files=("$@")
    local _dst_dir="$PROJECT_DIR/Everything"
    local _dl_dir="$HOME/Downloads"
    local _copied=false

    mkdir -p "$_dst_dir"
    for _f in "${_files[@]}"; do
        local _src="$_dl_dir/$_f"
        local _dst="$_dst_dir/$_f"
        if [[ -f "$_src" ]]; then
            # Backup existing file before overwriting
            if [[ -f "$_dst" ]]; then
                cp "$_dst" "${_dst}.bak"
                echo "  Backed up existing → ${_f}.bak"
            fi
            cp "$_src" "$_dst"
            echo -e "  ${GREEN}✓ Applied from Downloads:${NC} $_f"
            _copied=true
        else
            echo -e "  ${YELLOW}Not found in ~/Downloads:${NC} $_f — skipped"
        fi
    done
    if ! $_copied; then
        echo -e "  ${YELLOW}No config files found in ~/Downloads — nothing applied${NC}"
    fi
    echo
    echo "Tip: to restore the previous config, rename the .bak files:"
    for _f in "${_files[@]}"; do
        [[ -f "$_dst_dir/${_f}.bak" ]] && echo "  mv $_dst_dir/${_f}.bak $_dst_dir/$_f"
    done
}

# Upload a minimal blank sketch to reset the Arduino board firmware.
# This does NOT touch the git repo — it only flashes "void setup(){} void loop(){}"
# so the board is silent and idle. Use 'deploy' afterwards to restore normal operation.
# Restart the Arduino board by briefly toggling DTR on its serial port.
# Opening the port at 1200 baud and closing it asserts then releases DTR,
# which is wired to the ATmega16U2 reset line on the Mega 2560.
# No sketch upload required — the board just power-cycles its firmware.
cmd_board_restart() {
    local port
    port=$(find_arduino_port) || true
    verify_arduino_port "$port"

    echo "=== Arduino Board Restart ==="
    echo
    echo "→ Restarting Arduino on $port via DTR toggle..."

    # Stop serial logging if it owns the port — we need exclusive access
    local pid_file="/tmp/mini-bowling-serial.pid"
    local serial_was_running=false
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        serial_was_running=true
        echo "  Stopping background serial logging before restart..."
        serial_log stop
    fi

    # Save current stty settings so we can restore them after
    local saved_stty
    saved_stty=$(stty -F "$port" -g 2>/dev/null || stty -f "$port" -g 2>/dev/null || true)

    # 1200-baud open/close triggers the DTR pulse the bootloader listens for
    if stty -F "$port" 1200 2>/dev/null || stty -f "$port" 1200 2>/dev/null; then
        sleep 0.3
        # Restore original baud so the port is usable immediately after
        if [[ -n "$saved_stty" ]]; then
            stty -F "$port" "$saved_stty" 2>/dev/null || \
            stty -f  "$port" "$saved_stty" 2>/dev/null || true
        else
            stty -F "$port" "$BAUD_RATE" 2>/dev/null || \
            stty -f  "$port" "$BAUD_RATE" 2>/dev/null || true
        fi
    else
        die "stty failed — is $port accessible? Check: ls -l $port  and: groups"
    fi

    echo -e "${GREEN}✓ Arduino restart signal sent${NC}"
    echo "  The board is rebooting — allow ~2 seconds before sending serial commands."

    if $serial_was_running; then
        echo "  Waiting for board to come back up..."
        sleep 2
        echo "  Restarting serial logging..."
        serial_log start
    fi
}

cmd_board_reset() {
    local force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            *) die "Unexpected argument: $1" ;;
        esac
    done

    require_arduino_cli
    require_arduino_core

    local port
    port=$(find_arduino_port) || true
    verify_arduino_port "$port"

    echo "=== Arduino Board Reset ==="
    echo
    echo -e "${YELLOW}This will upload a blank sketch to the Arduino board at:${NC} $port"
    echo "  The board will run an empty program (no sensors, no scoring, no serial output)."
    echo "  Run 'mini-bowling.sh deploy' afterwards to restore normal operation."
    echo

    if ! $force; then
        read -r -p "Reset the Arduino board? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || { echo "Aborted."; return 0; }
    fi

    # arduino-cli requires the .ino filename to match the folder name
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/mb-board-reset-XXXXXX)
    local sketch_name="board_reset"
    local sketch_dir="$tmp_dir/$sketch_name"
    mkdir -p "$sketch_dir"
    printf 'void setup() {}\nvoid loop() {}\n' > "$sketch_dir/${sketch_name}.ino"

    trap 'rm -rf "$tmp_dir"' EXIT

    echo "→ Compiling and uploading blank sketch to $port..."

    local -a timeout_cmd=()
    command -v timeout >/dev/null 2>&1 && timeout_cmd=(timeout 60)

    "${timeout_cmd[@]}" arduino-cli compile --upload \
        --port "$port" \
        --fqbn "$BOARD" \
        "$sketch_dir" || {
        local exit_code=$?
        trap - EXIT; rm -rf "$tmp_dir"
        [[ $exit_code -eq 124 ]] && die "arduino-cli timed out after 60s — is the Arduino locked up?"
        die "Board reset failed (exit $exit_code)"
    }

    trap - EXIT
    rm -rf "$tmp_dir"

    echo -e "${GREEN}✓ Arduino board reset complete${NC}"
    echo "  Board is now running: void setup() {} void loop() {}"
    echo "  Run 'mini-bowling.sh deploy' to restore the bowling program."
}

cmd_update() {
    local target_branch="${1:-}"
    require_git_repo

    local _pull_branch
    _pull_branch=$(_current_branch)

    # If a target branch is required and we're on a different one, switch first
    if [[ -n "$target_branch" && "$_pull_branch" != "$target_branch" ]]; then
        echo -e "${YELLOW}Note:${NC} repo is on '$_pull_branch' — switching to '$target_branch' for deploy"
        switch_branch "$target_branch"
        return 0
    fi

    # Item 3: warn if repo is dirty before pulling
    if ! git -C "$PROJECT_DIR" diff --quiet || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
        echo -e "${YELLOW}Warning:${NC} You have local uncommitted changes in $PROJECT_DIR"
        echo "  Pulling with local changes may cause conflicts; consider committing or stashing first."
        echo "  Run 'git status' in $PROJECT_DIR to review."
        echo
    fi

    echo "Pulling latest changes..."
    local pull_rc=0
    git -C "$PROJECT_DIR" pull origin "$_pull_branch" || pull_rc=$?
    if [[ $pull_rc -ne 0 ]]; then
        if [[ "$_pull_branch" != "$DEFAULT_GIT_BRANCH" ]]; then
            echo -e "${YELLOW}Warning:${NC} branch '$_pull_branch' not found on remote — switching to $DEFAULT_GIT_BRANCH"
            switch_branch "$DEFAULT_GIT_BRANCH"
        else
            die "git pull failed — check network and try again"
        fi
    fi
}

# Args: sketch_dir [kill_app]
cmd_compile_and_upload() {
    local sketch_dir="${1:-Everything}"
    local kill_app="${2:-true}"

    require_project_dir
    require_arduino_cli
    require_arduino_core

    # Verify port and board BEFORE killing ScoreMore - no point killing the app
    # if the Arduino isn't reachable
    local port
    port=$(find_arduino_port) || true
    verify_arduino_port "$port"

    local sketch_path="${PROJECT_DIR}/${sketch_dir}"

    if [[ ! -d "$sketch_path" ]]; then
        echo -e "${YELLOW}Folder not found:${NC} $sketch_dir"
        echo "Run:   mini-bowling.sh code sketch list"
        die "Sketch folder missing: $sketch_dir"
    fi

    if ! find "$sketch_path" -maxdepth 1 -type f -iname "*.ino" -print -quit 2>/dev/null | grep -q .; then
        die "No .ino file found in $sketch_dir — cannot upload"
    fi

    # Item 2: note whether serial logging was active before upload - the upload
    # disconnects the serial port, which kills the background monitor
    local pid_file="/tmp/mini-bowling-serial.pid"
    local serial_was_running=false
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        serial_was_running=true
        echo "→ Stopping serial logging before upload..."
        serial_log stop
    fi

    if [[ "$kill_app" == "true" ]]; then
        echo "Terminating ScoreMore before upload..."
        kill_scoremore_gracefully
    else
        echo "Skipping ScoreMore kill (--no-kill)"
    fi

    echo "→ Compiling + uploading: $sketch_dir"
    echo "  Path: $sketch_path"
    echo "  Port: $port"

    local -a timeout_cmd=()
    command -v timeout >/dev/null 2>&1 && timeout_cmd=(timeout 120)

    "${timeout_cmd[@]}" arduino-cli compile --upload \
        --port "$port" \
        --fqbn "$BOARD" \
        "$sketch_path" || {
        local exit_code=$?
        [[ $exit_code -eq 124 ]] && die "arduino-cli timed out after 120s — Arduino may be locked up"
        die "arduino-cli failed (exit $exit_code)"
    }

    # Record what was just uploaded so 'status' can report it
    mkdir -p "$LOG_DIR"
    {
        echo "$sketch_dir"
        echo "$(date '+%Y-%m-%d %H:%M:%S')"
        echo "$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
        echo "$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo '')"
        echo "$(_current_branch)"
    } > "$ARDUINO_STATUS_FILE"

    # Item 2: restart serial logging if it was running before the upload
    if [[ "${serial_was_running:-false}" == "true" ]]; then
        echo "→ Restarting serial logging..."
        serial_log start || echo -e "${YELLOW}Warning: could not restart serial logging${NC}"
    fi
}

compile_sketch_only() {
    local sketch_dir="${1:-Everything}"
    local heading="${2:-Compile}"
    local failure_msg="${3:-Compile failed}"

    require_project_dir
    require_arduino_cli
    require_arduino_core
    require_arduino_libs

    local sketch_path="${PROJECT_DIR}/${sketch_dir}"
    if [[ ! -d "$sketch_path" ]]; then
        echo -e "${YELLOW}Folder not found:${NC} $sketch_dir"
        echo "Run: mini-bowling.sh code sketch list"
        die "Sketch folder missing: $sketch_dir"
    fi

    if ! find "$sketch_path" -maxdepth 1 -type f -iname "*.ino" -print -quit 2>/dev/null | grep -q .; then
        die "No .ino file found in $sketch_dir"
    fi

    echo "=== ${heading}: $sketch_dir ==="
    echo "  Path  : $sketch_path"
    echo "  Board : $BOARD"
    echo

    local -a timeout_cmd=()
    command -v timeout >/dev/null 2>&1 && timeout_cmd=(timeout 120)

    "${timeout_cmd[@]}" arduino-cli compile \
        --fqbn "$BOARD" \
        "$sketch_path" && \
        echo -e "\n${GREEN}✓ Compile OK — $sketch_dir builds cleanly${NC}" || {
        local exit_code=$?
        [[ $exit_code -eq 124 ]] && die "${heading} timed out after 120s"
        die "${failure_msg} (exit $exit_code)"
    }
}

_write_deploy_status() {
    local result="$1" deploy_start="$2" deploy_commit="$3" deploy_subject="$4"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf "%s\n%s\n%s\n%s\n%s\n" \
        "$deploy_start" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$result" \
        "$deploy_commit" \
        "$deploy_subject" \
        > "$DEPLOY_STATUS_FILE"
}

_notify_deploy() {
    local result="$1" deploy_commit="$2" deploy_subject="$3"
    if command -v notify-send >/dev/null 2>&1; then
        local short_commit="${deploy_commit:-unknown}"
        local short_subject="${deploy_subject:-}"
        local label="${short_commit}${short_subject:+: $short_subject}"
        if [[ "$result" == "OK" ]]; then
            DISPLAY="${DISPLAY:-:0}" notify-send \
                --icon=emblem-default \
                "mini-bowling: Deploy OK" \
                "$label" 2>/dev/null || true
        else
            DISPLAY="${DISPLAY:-:0}" notify-send \
                --urgency=critical \
                --icon=dialog-error \
                "mini-bowling: Deploy FAILED" \
                "$label" 2>/dev/null || true
        fi
    fi
}

cmd_deploy() {
    require_git_repo

    local kill_app=true
    local branch=""
    local dry_run=false
    local sketch="Everything"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-kill|-k)   kill_app=false; shift ;;
            --branch=*)     branch="${1#--branch=}"; shift ;;
            --branch)       shift; branch="${1?Missing branch name}"; shift ;;
            --dry-run)      dry_run=true; shift ;;
            --sketch=*)     sketch="${1#--sketch=}"; shift ;;
            --sketch)       shift; sketch="${1?Missing sketch name after --sketch}"; shift ;;
            --*)            sketch="${1#--}"; shift ;;   # --Master_Test / --Everything style
            *)              break ;;
        esac
    done

    # Only deploy Everything restarts ScoreMore; other sketches leave it as-is
    if [[ "$sketch" != "Everything" ]]; then
        kill_app=false
    fi

    if [[ -z "$branch" ]]; then
        branch="$DEFAULT_GIT_BRANCH"
        echo -e "${GREEN}Deploying sketch '${sketch}' from default branch:${NC} $branch"
    else
        echo -e "${YELLOW}Deploying sketch '${sketch}' from branch:${NC} $branch"
    fi

    if $dry_run; then
        echo -e "${YELLOW}--- DRY RUN — no changes will be made ---${NC}"
        echo

        # Network check
        if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC}  Network reachable"
        else
            echo -e "  ${RED}✗${NC}  No network connection"
        fi

        # Git status
        if [[ -d "$PROJECT_DIR/.git" ]]; then
            git -C "$PROJECT_DIR" fetch --quiet origin "$branch" 2>/dev/null || true
            local behind dirty
            behind=$(git -C "$PROJECT_DIR" rev-list HEAD..origin/"$branch" --count 2>/dev/null || echo "?")
            if git -C "$PROJECT_DIR" diff --quiet && git -C "$PROJECT_DIR" diff --cached --quiet; then
                dirty="clean"
            else
                dirty="uncommitted local changes"
            fi
            echo "  ✎  Local commit : $(git -C "$PROJECT_DIR" log --oneline -1 HEAD)"
            echo "  ✎  Remote ahead : $behind commit(s)"
            echo "  ✎  Repo state   : $dirty"
        else
            echo -e "  ${YELLOW}!${NC}  Project directory is not a git repo: $PROJECT_DIR"
        fi

        # Arduino port
        local port
        port=$(find_arduino_port 2>/dev/null || true)
        if [[ -n "$port" ]] && [[ -c "$port" ]]; then
            echo -e "  ${GREEN}✓${NC}  Arduino port: $port"
        else
            echo -e "  ${RED}✗${NC}  No Arduino port found"
        fi

        # ScoreMore state
        local sm_pid
        sm_pid=$(_scoremore_pid)
        if [[ -n "$sm_pid" ]]; then
            echo "  ✎  ScoreMore is running (pid $sm_pid) — will be killed before upload"
        else
            echo "  ✎  ScoreMore is not running"
        fi

        # Sketch
        local sketch_path="$PROJECT_DIR/$sketch"
        if [[ -d "$sketch_path" ]] && find "$sketch_path" -maxdepth 1 -iname "*.ino" -print -quit 2>/dev/null | grep -q .; then
            echo -e "  ${GREEN}✓${NC}  Sketch found: $sketch"
        else
            echo -e "  ${RED}✗${NC}  Sketch not found: $sketch_path"
            echo "         Run: mini-bowling.sh code sketch list"
        fi

        # Disk space
        local avail_kb avail_mb
        avail_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
        avail_mb=$(( avail_kb / 1024 ))
        if (( avail_kb >= 512000 )); then
            echo -e "  ${GREEN}✓${NC}  Disk space: ${avail_mb}MB free"
        else
            echo -e "  ${RED}✗${NC}  Low disk space: ${avail_mb}MB free"
        fi

        echo
        echo -e "  Sketch  : $sketch"
        echo -e "  Branch  : $branch"
        echo -e "  ScoreMore restart: $([[ "$sketch" == "Everything" ]] && echo "yes" || echo "no (non-Everything sketch)")"
        echo
        echo -e "${YELLOW}Dry run complete — no changes made. Run without --dry-run to deploy.${NC}"
        return 0
    fi

    # Validate sketch exists before doing any destructive work
    local sketch_path="$PROJECT_DIR/$sketch"
    if [[ ! -d "$sketch_path" ]]; then
        echo -e "${YELLOW}Sketch folder not found:${NC} $sketch"
        echo "  Run: mini-bowling.sh code sketch list"
        die "Sketch missing: $sketch_path"
    fi

    # Item 5: write status file on exit (success or failure)
    local deploy_start
    deploy_start=$(date '+%Y-%m-%d %H:%M:%S')
    local deploy_commit deploy_subject deploy_ok=false
    # Initialise to pre-pull values; re-read after pull so status reflects the
    # commit that was actually uploaded.
    deploy_commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')
    deploy_subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo '')

    # Write a deploy lock so watchdog knows not to restart ScoreMore mid-deploy
    local deploy_lock="/tmp/mini-bowling-deploy.lock"
    echo "$$" > "$deploy_lock"

    # Use EXIT trap (not ERR) so cleanup fires regardless of how we exit — via
    # die(), set -e, or any other path.  _with_git_branch_restore chains to this
    # via _DEPLOY_EXIT_HANDLER so the lock and status file are handled even when
    # die() is called deep inside with_git_branch.
    _cmd_deploy_on_exit() {
        if ! $deploy_ok; then
            _write_deploy_status "FAILED" "$deploy_start" "$deploy_commit" "$deploy_subject"
            _notify_deploy "FAILED" "$deploy_commit" "$deploy_subject"
        fi
        rm -f "$deploy_lock"
    }
    _DEPLOY_EXIT_HANDLER="_cmd_deploy_on_exit"
    trap '_cmd_deploy_on_exit' EXIT

    if [[ "$branch" == "$DEFAULT_GIT_BRANCH" ]]; then
        echo "→ Checking network connectivity..."
        wait_for_network 60
        echo "→ Pulling latest git changes"
        cmd_update "$DEFAULT_GIT_BRANCH"
        # Re-read after pull so status/notification reflect what was actually deployed
        deploy_commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')
        deploy_subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo '')
        echo "→ Uploading $sketch sketch"
        cmd_compile_and_upload "$sketch" "$kill_app"
    else
        # Temporarily switch to the requested branch, then restore
        with_git_branch "$branch" cmd_compile_and_upload "$sketch" "$kill_app"
        # Re-read after branch deploy so status reflects what was actually deployed
        deploy_commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')
        deploy_subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo '')
    fi

    if [[ "$sketch" == "Everything" && "$kill_app" == "true" ]]; then
        start_scoremore
    elif [[ "$sketch" != "Everything" ]]; then
        echo "ScoreMore left as-is (non-Everything sketch: '$sketch')."
    else
        echo "ScoreMore left as-is (--no-kill)."
    fi
    deploy_ok=true
    trap - EXIT
    _DEPLOY_EXIT_HANDLER=""
    rm -f "$deploy_lock"
    _write_deploy_status "OK" "$deploy_start" "$deploy_commit" "$deploy_subject"
    _notify_deploy "OK" "$deploy_commit" "$deploy_subject"
}

show_console() {
    # Warn if serial-log is already using the port
    local pid_file="/tmp/mini-bowling-serial.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        die "Serial logging is already running (pid $(cat "$pid_file")) and is using the port. Run 'mini-bowling.sh system serial stop' first."
    fi

    require_arduino_cli

    local port
    port=$(find_arduino_port) || die "No Arduino serial port found — is the Arduino connected?"

    echo "Opening serial console on $port at ${BAUD_RATE} baud"
    echo "Type to send. Ctrl+C to exit."
    echo "----------------------------------------"

    exec arduino-cli monitor -p "$port" --fqbn "$BOARD" --config "baudrate=$BAUD_RATE"
}

board_list() {
    require_arduino_cli
    arduino-cli board list
}

# -- restart -------------------------------------------------------------------
# Kill ScoreMore and start it again in one command
restart_scoremore() {
    local sm_pid
    sm_pid=$(_scoremore_pid)
    if [[ -n "$sm_pid" ]]; then
        echo "ScoreMore is running (pid $sm_pid) — stopping..."
        kill_scoremore_gracefully
    else
        echo "ScoreMore is not running — starting fresh..."
    fi
    sleep 1
    start_scoremore
    sleep 2
    sm_pid=$(_scoremore_pid)
    if [[ -n "$sm_pid" ]]; then
        echo -e "${GREEN}✓ ScoreMore restarted (pid $sm_pid)${NC}"
    else
        die "ScoreMore failed to start after restart"
    fi
}

# -- status --watch ------------------------------------------------------------
# Continuously refresh status display
watch_status() {
    local interval="${1:-5}"
    [[ "$interval" =~ ^[0-9]+$ ]] || die "Invalid interval: '$interval' — must be a number of seconds"
    echo "Watching status (refreshing every ${interval}s — Ctrl+C to exit)"
    while true; do
        clear
        echo -e "${BOLD}mini-bowling status${NC}  $(date '+%Y-%m-%d %H:%M:%S')  (Ctrl+C to exit)"
        echo
        print_status
        sleep "$interval"
    done
}

# -- repair --------------------------------------------------------------------
# Check and fix common broken states automatically
repair() {
    echo "=== Repair ==="
    echo
    local fixed=0
    local issues=0

    # 1. Stale serial-log PID file
    local serial_pid_file="/tmp/mini-bowling-serial.pid"
    if [[ -f "$serial_pid_file" ]]; then
        local spid
        spid=$(cat "$serial_pid_file" 2>/dev/null || true)
        if [[ -n "$spid" ]] && ! kill -0 "$spid" 2>/dev/null; then
            echo "→ Removing stale serial-log PID file (pid $spid no longer exists)"
            rm -f "$serial_pid_file"
            fixed=$(( fixed + 1 ))
        else
            echo -e "  ${GREEN}✓${NC}  Serial-log PID file is clean"
        fi
    else
        echo -e "  ${GREEN}✓${NC}  No serial-log PID file"
    fi

    # 2. Stale deploy lock
    local deploy_lock="/tmp/mini-bowling-deploy.lock"
    if [[ -f "$deploy_lock" ]]; then
        local dlpid
        dlpid=$(cat "$deploy_lock" 2>/dev/null || true)
        if [[ -n "$dlpid" ]] && ! kill -0 "$dlpid" 2>/dev/null; then
            echo "→ Removing stale deploy lock (pid $dlpid no longer exists)"
            rm -f "$deploy_lock"
            fixed=$(( fixed + 1 ))
        else
            echo -e "  ${GREEN}✓${NC}  Deploy lock is active (deploy in progress)"
        fi
    else
        echo -e "  ${GREEN}✓${NC}  No deploy lock"
    fi

    # 3. Broken ScoreMore symlink
    if [[ -L "$SYMLINK_PATH" ]] && [[ ! -f "$SYMLINK_PATH" ]]; then
        echo -e "  ${RED}✗${NC}  ScoreMore symlink is broken: $SYMLINK_PATH"
        echo "     Target: $(readlink "$SYMLINK_PATH")"
        echo "     Fix: run 'mini-bowling.sh scoremore download latest' to re-download"
        issues=$(( issues + 1 ))
    elif [[ ! -L "$SYMLINK_PATH" ]]; then
        echo -e "  ${YELLOW}!${NC}  No ScoreMore symlink at $SYMLINK_PATH"
        echo "     Fix: run 'mini-bowling.sh scoremore download latest'"
        issues=$(( issues + 1 ))
    else
        echo -e "  ${GREEN}✓${NC}  ScoreMore symlink OK"
    fi

    # 4. ScoreMore not running (but autostart is enabled)
    local desktop_file="$HOME/.config/autostart/scoremore.desktop"
    local sm_pid
    sm_pid=$(_scoremore_pid)
    if [[ -z "$sm_pid" ]] && [[ -f "$desktop_file" ]]; then
        echo "→ ScoreMore not running but autostart is enabled — starting..."
        start_scoremore
        sleep 2
        sm_pid=$(_scoremore_pid)
        if [[ -n "$sm_pid" ]]; then
            echo -e "  ${GREEN}✓${NC}  ScoreMore started (pid $sm_pid)"
            fixed=$(( fixed + 1 ))
        else
            echo -e "  ${RED}✗${NC}  ScoreMore failed to start"
            issues=$(( issues + 1 ))
        fi
    elif [[ -n "$sm_pid" ]]; then
        echo -e "  ${GREEN}✓${NC}  ScoreMore running (pid $sm_pid)"
    else
        echo -e "  ${YELLOW}!${NC}  ScoreMore not running (autostart not enabled — OK if intentional)"
    fi

    # 5. Required directories missing
    local dir_issues=0
    for dir in "$PROJECT_DIR" "$SCOREMORE_DIR" "$LOG_DIR"; do
        if [[ ! -d "$dir" ]]; then
            echo "→ Creating missing directory: $dir"
            mkdir -p "$dir" && echo -e "  ${GREEN}✓${NC}  Created: $dir" || \
                echo -e "  ${RED}✗${NC}  Failed to create: $dir"
            fixed=$(( fixed + 1 ))
            dir_issues=$(( dir_issues + 1 ))
        fi
    done
    [[ $dir_issues -eq 0 ]] && echo -e "  ${GREEN}✓${NC}  All required directories exist"

    echo
    if [[ $fixed -gt 0 && $issues -eq 0 ]]; then
        echo -e "${GREEN}✓ Repaired $fixed issue(s) — everything OK${NC}"
    elif [[ $fixed -eq 0 && $issues -eq 0 ]]; then
        echo -e "${GREEN}✓ Nothing to repair — everything looks good${NC}"
    else
        echo -e "${YELLOW}Fixed $fixed issue(s), $issues require manual attention (see above)${NC}"
    fi
}

# -- ports ---------------------------------------------------------------------
# List all serial devices with more detail than arduino-cli board list
show_ports() {
    echo "=== Serial Ports ==="
    echo

    local found=false

    # All candidate port device files
    local candidates=()
    for pattern in /dev/ttyACM* /dev/ttyUSB* /dev/ttyS* /dev/cu.usbmodem* /dev/serial/by-id/*; do
        for f in $pattern; do
            [[ -c "$f" ]] && candidates+=("$f")
        done
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo "No serial port devices found."
        echo "  Connect the Arduino and try again, or check: ls /dev/tty*"
        return 0
    fi

    local configured_port="${PORT:-$DEFAULT_PORT}"

    printf "  %-20s  %-8s  %-30s  %s\n" "PORT" "STATUS" "USB INFO" "NOTES"
    printf "  %-20s  %-8s  %-30s  %s\n" "----" "------" "--------" "-----"

    for port in "${candidates[@]}"; do
        local status="unknown"
        local usb_info=""
        local notes=""

        # Check if it's a character device we can access
        if [[ ! -r "$port" ]]; then
            status="no read"
            notes="permission denied — check dialout group"
        else
            status="ok"
        fi

        # Mark the configured port
        [[ "$port" == "$configured_port" ]] && notes="${notes:+$notes, }configured default"

        # Try to get USB vendor/product info from sysfs
        local dev_name
        dev_name=$(basename "$port")
        local usb_path
        usb_path=$(find /sys/bus/usb/devices -name "tty:${dev_name}" 2>/dev/null | head -1)
        if [[ -z "$usb_path" ]]; then
            usb_path=$(find /sys/class/tty/"$dev_name"/device 2>/dev/null | head -1)
        fi
        if [[ -n "$usb_path" ]]; then
            local vid pid manufacturer product
            vid=$(cat "$(dirname "$usb_path")/../idVendor" 2>/dev/null || true)
            pid=$(cat "$(dirname "$usb_path")/../idProduct" 2>/dev/null || true)
            manufacturer=$(cat "$(dirname "$usb_path")/../manufacturer" 2>/dev/null || true)
            product=$(cat "$(dirname "$usb_path")/../product" 2>/dev/null || true)
            [[ -n "$vid" ]] && usb_info="${vid}:${pid}"
            [[ -n "$product" ]] && usb_info="${usb_info:+$usb_info }$product"
            [[ -n "$manufacturer" && -z "$product" ]] && usb_info="${usb_info:+$usb_info }$manufacturer"
        fi

        # Check if in use by serial-log
        local serial_pid_file="/tmp/mini-bowling-serial.pid"
        if [[ -f "$serial_pid_file" ]] && kill -0 "$(cat "$serial_pid_file")" 2>/dev/null; then
            notes="${notes:+$notes, }in use by serial-log"
        fi

        printf "  %-20s  %-8s  %-30s  %s\n" "$port" "$status" "${usb_info:-—}" "${notes:-}"
        found=true
    done

    echo
    # Also run arduino-cli board list if available for recognised board names
    if command -v arduino-cli >/dev/null 2>&1; then
        echo "arduino-cli board list:"
        arduino-cli board list 2>/dev/null | head -20 || echo "  (failed)"
    fi
}

# -- info ----------------------------------------------------------------------
# Dense single-screen summary combining status + pi-status
show_info() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BOLD}=== mini-bowling info  $ts ===${NC}"
    echo

    # -- Hardware --------------------------------------------------------------
    local port
    port=$(find_arduino_port 2>/dev/null || echo "not found")
    [[ -c "$port" ]] && \
        echo -e "Arduino     : ${GREEN}detected${NC} on $port" || \
        echo -e "Arduino     : ${RED}NOT detected${NC}"

    # Sketch
    if _read_arduino_status; then
        echo "Sketch      : $_ard_sketch  ($_ard_commit)  @ $_ard_time"
    else
        echo "Sketch      : unknown"
    fi

    # -- ScoreMore -------------------------------------------------------------
    local sm_pid
    sm_pid=$(_scoremore_pid)
    local sm_ver; sm_ver=$(get_installed_scoremore_version)
    if [[ -n "$sm_pid" ]]; then
        echo -e "ScoreMore   : ${GREEN}running${NC} v${sm_ver:-?}  (pid $sm_pid)"
    else
        echo -e "ScoreMore   : ${RED}not running${NC}"
    fi

    # -- Last deploy -----------------------------------------------------------
    if [[ -f "$DEPLOY_STATUS_FILE" ]]; then
        local dep_finished dep_result dep_commit dep_subject
        dep_finished=$(sed -n '2p' "$DEPLOY_STATUS_FILE")
        dep_result=$(sed -n '3p'   "$DEPLOY_STATUS_FILE")
        dep_commit=$(sed -n '4p'   "$DEPLOY_STATUS_FILE")
        dep_subject=$(sed -n '5p'  "$DEPLOY_STATUS_FILE")
        if [[ "$dep_result" == "OK" ]]; then
            echo -e "Last deploy : ${GREEN}OK${NC} at $dep_finished — $dep_commit${dep_subject:+: $dep_subject}"
        else
            echo -e "Last deploy : ${RED}FAILED${NC} at $dep_finished — $dep_commit${dep_subject:+: $dep_subject}"
        fi
    else
        echo "Last deploy : no record"
    fi

    # -- Pi health -------------------------------------------------------------
    echo
    echo "Uptime      : $(uptime -p 2>/dev/null || uptime)"

    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local raw_temp temp_c
        raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp)
        temp_c=$(( raw_temp / 1000 ))
        if (( temp_c >= 80 )); then
            echo -e "CPU Temp    : ${RED}${temp_c}°C CRITICAL${NC}"
        elif (( temp_c >= 70 )); then
            echo -e "CPU Temp    : ${YELLOW}${temp_c}°C (warm)${NC}"
        else
            echo -e "CPU Temp    : ${GREEN}${temp_c}°C${NC}"
        fi
    fi

    local mem_total mem_free mem_used mem_pct
    mem_total=$(awk '/MemTotal/    {print $2}' /proc/meminfo)
    mem_free=$(awk  '/MemAvailable/{print $2}' /proc/meminfo)
    mem_used=$(( mem_total - mem_free ))
    mem_pct=$(( mem_used * 100 / mem_total ))
    echo "Memory      : $(( mem_used / 1024 ))MB / $(( mem_total / 1024 ))MB  (${mem_pct}%)"

    local disk_used disk_avail disk_pct
    disk_used=$(df -k "$HOME" | awk 'NR==2 {print $3}')
    disk_avail=$(df -k "$HOME" | awk 'NR==2 {print $4}')
    disk_pct=$(df -k "$HOME" | awk 'NR==2 {print $5}')
    echo "Disk        : $(( disk_used / 1024 ))MB used, $(( disk_avail / 1024 ))MB free  ($disk_pct)"

    # -- arduino-cli / Script version ------------------------------------------
    echo
    echo "Script      : v${SCRIPT_VERSION}"
    if command -v arduino-cli >/dev/null 2>&1; then
        local info_cli_ver; info_cli_ver=$(arduino-cli version 2>/dev/null | awk '{print $3}' || echo "?")
        echo "arduino-cli : v${info_cli_ver}"
    else
        echo "arduino-cli : not installed"
    fi
}

# -- tail-all ------------------------------------------------------------------
# Interleave command log and Arduino serial log with timestamps
tail_all() {
    local n="${1:-50}"
    [[ "$n" =~ ^[0-9]+$ ]] || die "Invalid line count: '$n' — must be a number"

    local cmd_log="$LOG_DIR/mini-bowling-$(date '+%Y-%m-%d').log"
    local serial_log_file="$LOG_DIR/arduino-serial-$(date '+%Y-%m-%d').log"

    local have_cmd=false
    local have_serial=false
    [[ -f "$cmd_log" ]]         && have_cmd=true
    [[ -f "$serial_log_file" ]] && have_serial=true

    if ! $have_cmd && ! $have_serial; then
        die "No log files found for today in $LOG_DIR"
    fi

    echo "=== Interleaved logs (last $n lines each) ==="
    $have_cmd    && echo "  Command log : $cmd_log"
    $have_serial && echo "  Serial log  : $serial_log_file"
    echo "  [CMD] = command log  [ARD] = Arduino serial"
    echo "----------------------------------------"

    # Tag each line with source, then sort by timestamp (fields 2-3 after the tag)
    {
        $have_cmd    && tail -n "$n" "$cmd_log"         | sed 's/^/[CMD] /'
        $have_serial && tail -n "$n" "$serial_log_file" | sed 's/^/[ARD] /'
    } | sort --stable -k2,3

    echo
    echo "--- live tail (Ctrl+C to exit) ---"
    echo

    # Live follow both files simultaneously
    local tail_args=()
    $have_cmd    && tail_args+=("$cmd_log")
    $have_serial && tail_args+=("$serial_log_file")

    tail -f "${tail_args[@]}" | awk '
        /^==> .* <==$/ { source=$0; next }
        { tag = (source ~ /serial/) ? "[ARD]" : "[CMD]"; print tag " " $0 }
    '
}

# -- test-upload ---------------------------------------------------------------
# Compile-only (no upload) to verify sketch builds cleanly
cmd_test_upload() {
    local sketch_dir="${1:-Everything}"
    compile_sketch_only "$sketch_dir" "Test Compile" "Compile failed - fix errors before deploying"
}

# -- scoremore-logs ------------------------------------------------------------
# Find and tail ScoreMore's own application logs
scoremore_logs() {
    local subcmd="${1:-show}"

    # Electron apps typically log to ~/.config/<AppName>/logs/ or
    # ~/.local/share/<AppName>/logs/ on Linux
    local log_candidates=(
        "$HOME/.config/ScoreMore/logs"
        "$HOME/.config/scoremore/logs"
        "$HOME/.local/share/ScoreMore/logs"
        "$HOME/.local/share/scoremore/logs"
    )

    local log_dir=""
    for candidate in "${log_candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
            log_dir="$candidate"
            break
        fi
    done

    # Also check if ScoreMore is running and its process can hint at the path
    if [[ -z "$log_dir" ]]; then
        local sm_pid
        sm_pid=$(_scoremore_pid)
        if [[ -n "$sm_pid" ]]; then
            local proc_log_dir
            proc_log_dir=$(ls -la /proc/"$sm_pid"/fd 2>/dev/null | \
                awk '
                    {
                        for (i = 1; i <= NF; i++) {
                            path = $i
                            if (path ~ /^\/[^[:space:]]+\.log$/ && tolower(path) ~ /score/) {
                                sub(/\/[^/]+$/, "", path)
                                print path
                                exit
                            }
                        }
                    }
                ' || true)
            [[ -n "$proc_log_dir" && -d "$proc_log_dir" ]] && log_dir="$proc_log_dir"
        fi
    fi

    if [[ -z "$log_dir" ]]; then
        echo "ScoreMore log directory not found."
        echo "Checked:"
        for c in "${log_candidates[@]}"; do echo "  $c"; done
        echo
        echo "If ScoreMore is running, its logs may be at one of these paths."
        echo "You can also check: ls ~/.config/ | grep -i score"
        return 0
    fi

    case "$subcmd" in
        show|list)
            echo "=== ScoreMore Logs: $log_dir ==="
            echo
            local files
            mapfile -t files < <(find "$log_dir" -maxdepth 2 -name "*.log" 2>/dev/null | sort -r | head -10)
            if [[ ${#files[@]} -eq 0 ]]; then
                echo "No .log files found in $log_dir"
                return 0
            fi
            for f in "${files[@]}"; do
                printf "  %-50s  %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
            done
            echo
            echo "Run: mini-bowling.sh scoremore logs tail    (live tail latest log)"
            echo "Run: mini-bowling.sh scoremore logs dump    (full output of latest)"
            ;;
        tail)
            local latest
            latest=$(find "$log_dir" -maxdepth 2 -name "*.log" 2>/dev/null | sort -r | head -1)
            [[ -z "$latest" ]] && die "No ScoreMore log files found in $log_dir"
            echo "Tailing: $latest  (Ctrl+C to exit)"
            echo "----------------------------------------"
            tail -f "$latest"
            ;;
        dump)
            local latest
            latest=$(find "$log_dir" -maxdepth 2 -name "*.log" 2>/dev/null | sort -r | head -1)
            [[ -z "$latest" ]] && die "No ScoreMore log files found in $log_dir"
            echo "=== $latest ==="
            echo
            cat "$latest"
            ;;
        *)
            die "Unknown subcommand: '$subcmd' — use show, tail, or dump"
            ;;
    esac
}

ensure_directories() {
    mkdir -p -- "$PROJECT_DIR"   && echo "Project dir OK:  $PROJECT_DIR"
    mkdir -p -- "$SCOREMORE_DIR" && echo "ScoreMore dir OK: $SCOREMORE_DIR"
    mkdir -p -- "$LOG_DIR"       && echo "Log dir OK:      $LOG_DIR"
}

# -- support bundle ------------------------------------------------------------
# Collect diagnostic info into a compressed archive for sharing with support
support_bundle() {
    local output_dir="$HOME/Documents/Bowling/support"
    local timestamp; timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local bundle_name="mini-bowling-support-${timestamp}"
    local bundle_dir="$output_dir/$bundle_name"
    local archive="${bundle_dir}.tar.gz"

    mkdir -p "$bundle_dir" || die "Cannot create support directory: $output_dir"

    echo "=== Generating Support Bundle ==="
    echo "  Collecting diagnostic information..."
    echo

    # ---- 1. info.txt — header ------------------------------------------------
    {
        echo "================================================================"
        echo "  mini-bowling Support Bundle"
        echo "  Generated : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Host      : $(hostname 2>/dev/null)"
        echo "  Script    : mini-bowling.sh $SCRIPT_VERSION"
        echo "================================================================"
        echo
        echo "Script path  : $(command -v mini-bowling.sh 2>/dev/null || realpath "$0")"
        echo "Shell        : bash $BASH_VERSION"
        echo
        uname -a 2>/dev/null || true
        echo
        if [[ -f /etc/os-release ]]; then
            cat /etc/os-release
        fi
    } > "$bundle_dir/info.txt"
    echo "  → info.txt"

    # ---- 2. status.txt — full status output ----------------------------------
    {
        echo "=== mini-bowling status ==="
        echo
        print_status 2>/dev/null || echo "(status failed)"
    } > "$bundle_dir/status.txt"
    echo "  → status.txt"

    # ---- 3. system-check.txt — system readiness check -----------------------
    {
        system_check 2>&1 || true
    } > "$bundle_dir/system-check.txt"
    echo "  → system-check.txt"

    # ---- 4. doctor.txt — dependency check ------------------------------------
    {
        doctor 2>&1 || true
    } > "$bundle_dir/doctor.txt"
    echo "  → doctor.txt"

    # ---- 5. environment.txt — relevant env vars and key paths ---------------
    {
        echo "=== Environment Variables ==="
        echo
        printf "  %-22s %s\n" "USER"             "${USER:-}"
        printf "  %-22s %s\n" "HOME"             "${HOME:-}"
        printf "  %-22s %s\n" "DISPLAY"          "${DISPLAY:-<not set>}"
        printf "  %-22s %s\n" "MINI_BOWLING_DIR" "${MINI_BOWLING_DIR:-<not set — using default>}"
        printf "  %-22s %s\n" "PATH"             "$PATH"
        echo
        echo "=== Key Paths ==="
        echo
        for entry in \
            "PROJECT_DIR:$PROJECT_DIR" \
            "SCOREMORE_DIR:$SCOREMORE_DIR" \
            "LOG_DIR:$LOG_DIR" \
            "SYMLINK_PATH:$SYMLINK_PATH"; do
            local lbl="${entry%%:*}" val="${entry#*:}"
            if [[ -d "$val" ]]; then
                printf "  %-20s %s  (directory)\n" "$lbl" "$val"
            elif [[ -L "$val" ]]; then
                local target; target=$(readlink "$val" 2>/dev/null || echo "?")
                printf "  %-20s %s  (symlink → %s)\n" "$lbl" "$val" "$target"
            elif [[ -f "$val" ]]; then
                printf "  %-20s %s  (file)\n" "$lbl" "$val"
            else
                printf "  %-20s %s  (NOT FOUND)\n" "$lbl" "$val"
            fi
        done
        echo
        echo "=== File Permissions ==="
        echo
        for check_path in \
            "$(command -v mini-bowling.sh 2>/dev/null || echo "$0")" \
            "$SYMLINK_PATH" \
            "$LOG_DIR" \
            "$PROJECT_DIR"; do
            [[ -e "$check_path" || -L "$check_path" ]] && \
                ls -ld "$check_path" 2>/dev/null || true
        done
    } > "$bundle_dir/environment.txt"
    echo "  → environment.txt"

    # ---- 6. crontab.txt -------------------------------------------------------
    {
        echo "=== Crontab (user: ${USER:-$(id -un)}) ==="
        echo
        _read_crontab || echo "(no crontab or access denied)"
    } > "$bundle_dir/crontab.txt"
    echo "  → crontab.txt"

    # ---- 7. arduino.txt — arduino-cli version, cores, boards, status --------
    {
        echo "=== arduino-cli ==="
        echo
        if command -v arduino-cli >/dev/null 2>&1; then
            echo "Version:"
            arduino-cli version 2>/dev/null || echo "  (version failed)"
            echo
            echo "Installed cores:"
            arduino-cli core list 2>/dev/null || echo "  (core list failed)"
            echo
            echo "Installed libraries:"
            arduino-cli lib list 2>/dev/null || echo "  (lib list failed)"
            echo
            echo "Required libraries status:"
            local rpt_lib_list; rpt_lib_list=$(arduino-cli lib list 2>/dev/null)
            for lib in "${ARDUINO_LIBS[@]}"; do
                if echo "$rpt_lib_list" | grep -qF "$lib"; then
                    printf "  ✓  %s\n" "$lib"
                else
                    printf "  ✗  %s  MISSING\n" "$lib"
                fi
            done
            echo
            echo "Board list:"
            arduino-cli board list 2>/dev/null || echo "  (board list failed)"
        else
            echo "  arduino-cli NOT FOUND in PATH"
        fi
        echo
        echo "=== Arduino Upload Status File ==="
        echo
        if [[ -f "$ARDUINO_STATUS_FILE" ]]; then
            cat "$ARDUINO_STATUS_FILE"
        else
            echo "(no upload recorded — $ARDUINO_STATUS_FILE not found)"
        fi
        echo
        echo "=== Serial Port Devices ==="
        echo
        local found_port=false
        for port_glob in /dev/ttyACM* /dev/ttyUSB* /dev/cu.usbmodem* /dev/serial/by-id/*; do
            for f in $port_glob; do
                if [[ -c "$f" ]]; then
                    ls -la "$f" 2>/dev/null
                    found_port=true
                fi
            done
        done
        $found_port || echo "  (no serial port devices found)"
    } > "$bundle_dir/arduino.txt"
    echo "  → arduino.txt"

    # ---- 8. scoremore.txt — version, running state, AppImages, autostart ----
    {
        echo "=== ScoreMore ==="
        echo
        scoremore_version 2>/dev/null || echo "(no ScoreMore symlink)"
        echo
        echo "Running processes:"
        if [[ -n "$(_scoremore_pid)" ]]; then
            pgrep -af "ScoreMore.*AppImage" 2>/dev/null || \
                pgrep -f "ScoreMore.*AppImage" 2>/dev/null
        else
            echo "  Not running"
        fi
        echo
        echo "AppImages in $SCOREMORE_DIR:"
        if [[ -d "$SCOREMORE_DIR" ]]; then
            find "$SCOREMORE_DIR" -maxdepth 1 -name "*.AppImage" \
                -exec ls -lh {} \; 2>/dev/null || echo "  (none found)"
        else
            echo "  Directory not found: $SCOREMORE_DIR"
        fi
        echo
        echo "Autostart:"
        local desktop_file="$HOME/.config/autostart/scoremore.desktop"
        if [[ -f "$desktop_file" ]]; then
            echo "  Enabled — $desktop_file"
            cat "$desktop_file" 2>/dev/null
        else
            echo "  Not configured ($desktop_file not found)"
        fi
    } > "$bundle_dir/scoremore.txt"
    echo "  → scoremore.txt"

    # ---- 9. git.txt — recent commits and status for both repos ---------------
    {
        echo "=== Arduino Project Repo ($PROJECT_DIR) ==="
        echo
        if [[ -d "$PROJECT_DIR/.git" ]]; then
            echo "Last 10 commits:"
            git -C "$PROJECT_DIR" log --oneline -10 2>/dev/null || echo "  (log failed)"
            echo
            echo "Status:"
            git -C "$PROJECT_DIR" status 2>/dev/null || echo "  (status failed)"
            echo
            echo "Remotes:"
            git -C "$PROJECT_DIR" remote -v 2>/dev/null || echo "  (no remotes)"
        else
            echo "  NOT a git repository"
        fi
        echo
        local script_dir
        script_dir=$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")")
        echo "=== Script Repo ($script_dir) ==="
        echo
        if [[ -d "$script_dir/.git" ]]; then
            git -C "$script_dir" log --oneline -5 2>/dev/null || echo "  (log failed)"
        else
            echo "  Not a git clone (installed as single file)"
        fi
    } > "$bundle_dir/git.txt"
    echo "  → git.txt"

    # ---- 10. dmesg-usb.txt — kernel USB/serial messages ----------------------
    {
        echo "=== dmesg — USB/Serial messages (last 100 matching lines) ==="
        echo
        dmesg 2>/dev/null | \
            grep -iE "usb|acm|ttyACM|ttyUSB|serial|cdc|ch341|cp210" | \
            tail -100 || \
            echo "(dmesg not available or no USB messages found)"
    } > "$bundle_dir/dmesg-usb.txt"
    echo "  → dmesg-usb.txt"

    # ---- 11. pi-health.txt — Pi vitals ----------------------------------------
    {
        echo "=== Raspberry Pi Health ==="
        echo
        echo "Uptime      : $(uptime 2>/dev/null || echo unavailable)"
        if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
            local raw; raw=$(cat /sys/class/thermal/thermal_zone0/temp)
            echo "CPU Temp    : $(( raw / 1000 ))°C"
        else
            echo "CPU Temp    : unavailable"
        fi
        echo
        awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} \
             END{printf "Memory      : %d MB used of %d MB (%d%%)\n", \
             (t-a)/1024, t/1024, (t-a)*100/t}' /proc/meminfo 2>/dev/null || true
        df -h / 2>/dev/null | \
            awk 'NR>1{printf "Disk (/)    : %s used of %s (%s)\n",$3,$2,$5}' || true
        df -h "$HOME" 2>/dev/null | \
            awk 'NR>1{printf "Disk (home) : %s used of %s (%s)\n",$3,$2,$5}' || true
        echo
        echo "Architecture: $(uname -m 2>/dev/null || echo unknown)"
        local os_name
        os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}" || echo "unknown")
        echo "OS          : $os_name"
    } > "$bundle_dir/pi-health.txt"
    echo "  → pi-health.txt"

    # ---- 12. deploy-status.txt -----------------------------------------------
    {
        echo "=== Deploy Status File ==="
        echo
        if [[ -f "$DEPLOY_STATUS_FILE" ]]; then
            cat "$DEPLOY_STATUS_FILE"
        else
            echo "(no deploy status recorded — $DEPLOY_STATUS_FILE not found)"
        fi
    } > "$bundle_dir/deploy-status.txt"
    echo "  → deploy-status.txt"

    # ---- 13. logs/ — recent mini-bowling logs (last 7 days) ------------------
    local logs_dir="$bundle_dir/logs"
    mkdir -p "$logs_dir"
    local log_count=0
    if [[ -d "$LOG_DIR" ]]; then
        while IFS= read -r -d '' f; do
            cp -- "$f" "$logs_dir/" 2>/dev/null && log_count=$(( log_count + 1 ))
        done < <(find "$LOG_DIR" -maxdepth 1 \
            \( -name "mini-bowling-*.log" -o -name "arduino-serial-*.log" \
               -o -name "os-update.log" -o -name "scoremore-update.log" \
               -o -name "script-update.log" \) \
            -mtime -7 -print0 2>/dev/null)
    fi
    echo "  → logs/ ($log_count file(s) from last 7 days)"

    # ---- 14. scoremore-logs/ — ScoreMore app logs ----------------------------
    local sm_log_dir=""
    for candidate in \
        "$HOME/.config/ScoreMore/logs" \
        "$HOME/.config/scoremore/logs" \
        "$HOME/.local/share/ScoreMore/logs" \
        "$HOME/.local/share/scoremore/logs"; do
        [[ -d "$candidate" ]] && { sm_log_dir="$candidate"; break; }
    done
    if [[ -n "$sm_log_dir" ]]; then
        local sm_logs_dest="$bundle_dir/scoremore-logs"
        mkdir -p "$sm_logs_dest"
        local sm_count=0
        while IFS= read -r -d '' f; do
            cp -- "$f" "$sm_logs_dest/" 2>/dev/null && sm_count=$(( sm_count + 1 ))
        done < <(find "$sm_log_dir" -maxdepth 2 -name "*.log" -mtime -7 -print0 2>/dev/null)
        echo "  → scoremore-logs/ ($sm_count file(s) from $sm_log_dir)"
    else
        echo "  → scoremore-logs/ (ScoreMore log directory not found)"
    fi

    # ---- Package into tarball ------------------------------------------------
    echo
    echo -n "  Compressing bundle..."
    tar -czf "$archive" -C "$output_dir" "$bundle_name" 2>/dev/null || \
        die "Failed to create archive: $archive"
    echo " done"

    # Clean up uncompressed bundle directory
    rm -rf -- "$bundle_dir"

    echo
    echo -e "${GREEN}✓ Support bundle created${NC}"
    echo
    echo "  Path : $archive"
    echo "  Size : $(du -h "$archive" | cut -f1)"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Share this file when reporting an issue:"
    echo "  $archive"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "  To list contents:  tar -tzf \"$archive\""
    echo "  To extract:        tar -xzf \"$archive\""

    # Keep only last 5 support bundles
    local old_bundles
    mapfile -t old_bundles < <(find "$output_dir" -maxdepth 1 \
        -name "mini-bowling-support-*.tar.gz" 2>/dev/null | sort -r | tail -n +6)
    if [[ ${#old_bundles[@]} -gt 0 ]]; then
        for f in "${old_bundles[@]}"; do
            rm -f -- "$f"
        done
        echo
        echo "  (Pruned ${#old_bundles[@]} old support bundle(s) — keeping 5 most recent)"
    fi
}

# Item 4: wait for network connectivity before proceeding (used by cron deploy)
wait_for_network() {
    local timeout="${1:-30}"
    local elapsed=0
    # Try multiple hosts - 8.8.8.8 may be blocked on some networks
    local hosts=(8.8.8.8 1.1.1.1 9.9.9.9)

    echo -n "Waiting for network"
    while true; do
        for host in "${hosts[@]}"; do
            if ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
                echo
                echo -e "${GREEN}→ Network available${NC}"
                return 0
            fi
        done
        if (( elapsed >= timeout )); then
            echo
            die "Network not available after ${timeout}s — aborting"
        fi
        echo -n "."
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
}

list_script_branches() {
    local script_repo_dir="$HOME/.local/share/mini-bowling-script"

    echo "Fetching branch list from $SCRIPT_REPO..."

    if [[ ! -d "$script_repo_dir/.git" ]]; then
        echo "→ Cloning script repo to read branch list..."
        mkdir -p "$(dirname "$script_repo_dir")"
        git clone --quiet "$SCRIPT_REPO" "$script_repo_dir" || \
            die "git clone failed — is the network available?"
    else
        git -C "$script_repo_dir" fetch --quiet origin 2>/dev/null || \
            echo -e "${YELLOW}Warning: fetch failed — showing last known branches${NC}"
    fi

    local current
    current=$(git -C "$script_repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

    echo
    echo "Branches in $SCRIPT_REPO:"
    echo "----------------------------------------------"

    local branches
    branches=$(git -C "$script_repo_dir" branch -a 2>/dev/null | \
        sed 's|^\*\? *||;s|remotes/origin/||' | \
        grep -v '^HEAD' | sort -u)

    while IFS= read -r b; do
        local marker="  "
        [[ "$b" == "$current" ]] && marker="${GREEN}→ ${NC}"
        local commit subject
        commit=$(git -C "$script_repo_dir" log -1 --format='%h' "origin/$b" 2>/dev/null || \
                 git -C "$script_repo_dir" log -1 --format='%h' "$b" 2>/dev/null || echo "?")
        subject=$(git -C "$script_repo_dir" log -1 --format='%s' "origin/$b" 2>/dev/null || \
                  git -C "$script_repo_dir" log -1 --format='%s' "$b" 2>/dev/null || echo "")
        printf "${marker}  %-30s  [%s] %s\n" "$b" "$commit" "$subject"
    done <<< "$branches"

    echo
    echo "Usage:"
    echo "  mini-bowling.sh script update                    (update from main)"
    echo "  mini-bowling.sh script update --branch <name>   (update from specific branch)"
}

update_script() {
    local _branch="main"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch|-b) _branch="${2:?Missing branch name for --branch}"; shift 2 ;;
            *) die "Unexpected argument: $1 — usage: script update [--branch <name>]" ;;
        esac
    done

    local script_path
    script_path=$(command -v mini-bowling.sh 2>/dev/null) || script_path=$(realpath "$0")

    echo "Current version : $SCRIPT_VERSION"
    echo "Script path     : $script_path"
    [[ "$_branch" != "main" ]] && echo "Update branch   : $_branch"
    echo

    # Find or create a local clone of the script repo to pull from
    local script_repo_dir="$HOME/.local/share/mini-bowling-script"

    if [[ -d "$script_repo_dir/.git" ]]; then
        echo "→ Fetching latest from $SCRIPT_REPO..."
        git -C "$script_repo_dir" fetch --quiet origin || \
            die "git fetch failed — is the network available?"

        # Verify the requested branch exists on the remote
        if ! git -C "$script_repo_dir" rev-parse "origin/$_branch" >/dev/null 2>&1; then
            die "Branch '$_branch' not found on remote — run: mini-bowling.sh script branch --list"
        fi

        # Switch to the requested branch in the local mirror if needed
        local _current_branch
        _current_branch=$(git -C "$script_repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        if [[ "$_current_branch" != "$_branch" ]]; then
            echo "→ Switching mirror to branch $_branch..."
            git -C "$script_repo_dir" checkout --quiet "$_branch" 2>/dev/null || \
                git -C "$script_repo_dir" checkout --quiet -b "$_branch" \
                    --track "origin/$_branch" 2>/dev/null || \
                die "Cannot checkout branch '$_branch' in local mirror"
        fi

        local behind
        behind=$(git -C "$script_repo_dir" rev-list HEAD..origin/"$_branch" --count 2>/dev/null || echo 0)
        if [[ "$behind" -eq 0 ]]; then
            echo -e "${GREEN}✓ Already up to date${NC}"
            return 0
        fi
        echo "→ $behind new commit(s) available — pulling..."

        # Reset any local modifications in the clone - this is a pure mirror,
        # not a working copy, so local edits should never be preserved
        if ! git -C "$script_repo_dir" diff --quiet 2>/dev/null || \
           ! git -C "$script_repo_dir" diff --cached --quiet 2>/dev/null; then
            echo -e "  ${YELLOW}Local modifications found in clone — resetting to remote${NC}"
            git -C "$script_repo_dir" reset --hard "origin/$_branch" --quiet 2>/dev/null || true
        fi

        git -C "$script_repo_dir" pull --quiet origin "$_branch" || {
            # Pull still failed - nuclear option: delete and re-clone
            echo -e "  ${YELLOW}Pull failed — re-cloning from scratch...${NC}"
            rm -rf "$script_repo_dir"
            mkdir -p "$(dirname "$script_repo_dir")"
            git clone --quiet "$SCRIPT_REPO" "$script_repo_dir" || die "git clone failed"
            if [[ "$_branch" != "main" ]]; then
                git -C "$script_repo_dir" checkout --quiet -b "$_branch" \
                    --track "origin/$_branch" 2>/dev/null || true
            fi
        }
    else
        echo "→ Cloning script repo..."
        mkdir -p "$(dirname "$script_repo_dir")"
        git clone --quiet "$SCRIPT_REPO" "$script_repo_dir" || die "git clone failed"
        if [[ "$_branch" != "main" ]]; then
            git -C "$script_repo_dir" checkout --quiet -b "$_branch" \
                --track "origin/$_branch" 2>/dev/null || \
            die "Cannot checkout branch '$_branch' — run: mini-bowling.sh script branch --list"
        fi
    fi

    local new_script="$script_repo_dir/mini-bowling.sh"
    [[ -f "$new_script" ]] || die "mini-bowling.sh not found in repo at $new_script"

    local new_version
    new_version=$(grep -m1 'SCRIPT_VERSION=' "$new_script" | sed 's/.*SCRIPT_VERSION="//;s/".*//' || echo "unknown")

    # Validate syntax before installing - a broken update should never reach /usr/bin
    echo "→ Validating syntax of new script..."
    if ! bash -n "$new_script" 2>/dev/null; then
        die "New script failed syntax check — aborting update to protect the installed version.
  The downloaded script is at: $new_script
  Run 'bash -n $new_script' to see the errors."
    fi
    echo -e "  ${GREEN}✓ Syntax OK${NC}"

    echo "→ Installing version $new_version to $script_path..."
    chmod +x "$new_script"

    if [[ "$script_path" == /usr/bin/* ]] || [[ "$script_path" == /usr/local/bin/* ]]; then
        sudo cp "$new_script" "$script_path" || die "sudo cp failed — do you have sudo access?"
    else
        cp "$new_script" "$script_path" || die "cp failed"
    fi

    echo -e "${GREEN}✓ Updated: $SCRIPT_VERSION → $new_version${NC}"

    # Update mini-bowling (no .sh) if it's a separate copy in the same bin directory
    local bin_dir; bin_dir=$(dirname "$script_path")
    local plain_cmd="$bin_dir/mini-bowling"
    if [[ -f "$plain_cmd" && ! -L "$plain_cmd" ]]; then
        echo "→ Updating $plain_cmd..."
        if [[ "$bin_dir" == /usr/bin || "$bin_dir" == /usr/local/bin ]]; then
            sudo cp "$new_script" "$plain_cmd" || \
                echo -e "  ${YELLOW}Warning: could not update $plain_cmd — run: sudo cp $new_script $plain_cmd${NC}"
        else
            cp "$new_script" "$plain_cmd" || \
                echo -e "  ${YELLOW}Warning: could not update $plain_cmd${NC}"
        fi
        echo -e "  ${GREEN}✓ Updated:${NC} $plain_cmd"
    fi

    # Update tab completion file if it was previously installed to a standard location
    local completion_src="$script_repo_dir/mini-bowling-completion.bash"
    local completion_dst=""
    for _candidate in \
        /etc/bash_completion.d/mini-bowling.sh \
        /usr/share/bash-completion/completions/mini-bowling.sh \
        /usr/local/share/bash-completion/completions/mini-bowling.sh; do
        if [[ -f "$_candidate" ]]; then
            completion_dst="$_candidate"
            break
        fi
    done
    if [[ -f "$completion_src" && -n "$completion_dst" ]]; then
        echo "→ Updating tab completion ($completion_dst)..."
        sudo cp "$completion_src" "$completion_dst" || \
            echo -e "  ${YELLOW}Warning: could not update completion file — run: sudo cp $completion_src $completion_dst${NC}"
        echo -e "  ${GREEN}✓ Tab completion updated:${NC} $completion_dst"
        echo "  Re-source to activate: source $completion_dst"
    fi

    echo "  Run 'mini-bowling.sh version' to confirm."
}

script_version() {
    local script_path
    script_path=$(command -v mini-bowling.sh 2>/dev/null) || script_path=$(realpath "$0")

    echo "mini-bowling version : $SCRIPT_VERSION"
    echo "Script path          : $script_path"
    echo "Last modified        : $(date -r "$script_path" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$script_path" 2>/dev/null | cut -c1-19)"
    echo "Shell                : $BASH_VERSION"

    # Check remote for a newer version
    echo -n "Remote version       : "
    local remote_version=""
    if command -v curl >/dev/null 2>&1; then
        # Extract owner/repo from SCRIPT_REPO (strip https://github.com/ and .git)
        local repo_path="${SCRIPT_REPO#https://github.com/}"
        repo_path="${repo_path%.git}"
        local raw_url="https://raw.githubusercontent.com/${repo_path}/refs/heads/${DEFAULT_GIT_BRANCH}/mini-bowling.sh"
        remote_version=$(curl -fsSL --max-time 5 "$raw_url" 2>/dev/null \
            | grep -m1 'SCRIPT_VERSION=' | sed 's/.*SCRIPT_VERSION="//;s/".*//' || echo "")
    fi

    if [[ -z "$remote_version" ]]; then
        echo "unavailable (no network or repo unreachable)"
    elif [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
        echo -e "${GREEN}${remote_version} (up to date)${NC}"
    else
        echo -e "${YELLOW}${remote_version} — update available!${NC}"
        echo "  Run: mini-bowling.sh script update"
    fi
}

# Item 5: show which ScoreMore version is currently active via the desktop symlink
scoremore_version() {
    if [[ ! -L "$SYMLINK_PATH" ]]; then
        echo "No ScoreMore symlink found at $SYMLINK_PATH"
        return 0
    fi

    local target
    target=$(readlink -f -- "$SYMLINK_PATH" 2>/dev/null) || die "Cannot resolve symlink"

    local filename
    filename=$(basename "$target")

    # Extract version from filename: ScoreMore-1.8.0-arm64.AppImage
    local version
    version=$(echo "$filename" | sed -n "s/^ScoreMore-\\(.*\\)-${ARCH}\\.${EXTENSION}$/\\1/p")

    echo "ScoreMore version : ${version:-unknown}"
    echo "AppImage path     : $target"

    if [[ -f "$target" ]]; then
        echo "File size         : $(du -h "$target" | cut -f1)"
        echo "Last modified     : $(date -r "$target" '+%Y-%m-%d %H:%M:%S')"
    else
        echo -e "${RED}Warning:${NC} symlink target does not exist: $target"
    fi
}

# Item 7: backup key config files to a timestamped archive
backup_config() {
    local backup_dir="$HOME/Documents/Bowling/backups"
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local archive="$backup_dir/mini-bowling-backup-${timestamp}.tar.gz"

    mkdir -p "$backup_dir" || die "Cannot create backup directory: $backup_dir"

    echo "Creating backup: $archive"

    local include_appimage=false
    for arg in "$@"; do
        [[ "$arg" == "--include-appimage" ]] && include_appimage=true
    done

    local items=()
    [[ -d "$PROJECT_DIR" ]]            && items+=("$PROJECT_DIR")
    [[ -d "$HOME/.config/ScoreMore" ]] && items+=("$HOME/.config/ScoreMore")

    # AppImage is 100MB+ and can be re-downloaded - skip by default
    if $include_appimage; then
        [[ -f "$SYMLINK_PATH" ]] && items+=("$(readlink -f "$SYMLINK_PATH")")
    else
        echo "  (Skipping ScoreMore AppImage — use --include-appimage to include it)"
    fi

    # Include the script itself so it survives an SD card failure
    local script_path
    script_path=$(command -v mini-bowling.sh 2>/dev/null) || script_path=$(realpath "$0")
    [[ -f "$script_path" ]] && items+=("$script_path")

    if [[ ${#items[@]} -eq 0 ]]; then
        die "Nothing to back up — no project dir or ScoreMore config found"
    fi

    tar -czf "$archive" --ignore-failed-read "${items[@]}" 2>/dev/null || \
        die "Backup failed"

    echo -e "${GREEN}✓ Backup created:${NC} $archive"
    echo "  Size: $(du -h "$archive" | cut -f1)"

    # Keep only the last 10 backups
    local old_backups
    mapfile -t old_backups < <(find "$backup_dir" -name "mini-bowling-backup-*.tar.gz" \
                                    2>/dev/null | sort -r | tail -n +11)
    if [[ ${#old_backups[@]} -gt 0 ]]; then
        for f in "${old_backups[@]}"; do
            rm -f -- "$f" && echo "→ Removed old backup: $(basename "$f")"
        done
        echo "  Pruned ${#old_backups[@]} old backup(s)"
    fi

    local total_backups
    total_backups=$(find "$backup_dir" -name "mini-bowling-backup-*.tar.gz" 2>/dev/null | wc -l)
    echo "  Total backups kept: $total_backups / 10"
}

system_report() {
    local report_dir="$HOME/Documents/Bowling/reports"
    local timestamp; timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local report_file="$report_dir/mini-bowling-report-${timestamp}.txt"

    mkdir -p "$report_dir" || die "Cannot create report directory: $report_dir"

    echo "Generating system report..."

    {
        echo "================================================================"
        echo "  mini-bowling System Report"
        echo "  Generated : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Host      : $(hostname 2>/dev/null)"
        echo "  Version   : mini-bowling.sh $SCRIPT_VERSION"
        echo "================================================================"
        echo

        # --- System identity ---
        echo "── System ──────────────────────────────────────────────────────"
        uname -a 2>/dev/null || true
        if [[ -f /etc/os-release ]]; then
            grep -E "^(PRETTY_NAME|VERSION)" /etc/os-release | sed 's/^/  /'
        fi
        echo "  Uptime: $(uptime -p 2>/dev/null || uptime)"
        echo

        # --- Pi vitals ---
        echo "── Raspberry Pi ────────────────────────────────────────────────"
        if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
            local raw; raw=$(cat /sys/class/thermal/thermal_zone0/temp)
            echo "  CPU temp  : $(( raw / 1000 ))°C"
        fi
        awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "  Memory    : %d MB used of %d MB (%d%%)\n", (t-a)/1024, t/1024, (t-a)*100/t}' /proc/meminfo
        df -h / 2>/dev/null | awk 'NR==2{printf "  Disk /    : %s used of %s (%s)\n", $3, $2, $5}'
        echo

        # --- Arduino ---
        echo "── Arduino ─────────────────────────────────────────────────────"
        if _read_arduino_status; then
            echo "  Sketch   : $_ard_sketch"
            echo "  Uploaded : $_ard_time"
            echo "  Commit   : $_ard_commit"
            echo "  Branch   : $_ard_branch"
        else
            echo "  No upload on record"
        fi
        if [[ -d "$PROJECT_DIR/.git" ]]; then
            echo "  Repo HEAD: $(git -C "$PROJECT_DIR" log --oneline -1 2>/dev/null)"
            echo "  Branch   : $(_current_branch)"
        fi
        local port; port=$(find_arduino_port 2>/dev/null || echo "not found")
        echo "  Port     : $port"
        echo

        # --- ScoreMore ---
        echo "── ScoreMore ───────────────────────────────────────────────────"
        if [[ -n "$(_scoremore_pid)" ]]; then
            echo "  Running  : yes (pid $(_scoremore_pid))"
        else
            echo "  Running  : no"
        fi
        local sm_ver; sm_ver=$(get_installed_scoremore_version)
        echo "  Version  : ${sm_ver:-no AppImage found}"
        local autostart_file="$HOME/.config/autostart/scoremore.desktop"
        echo "  Autostart: $([[ -f "$autostart_file" ]] && echo "enabled" || echo "disabled")"
        echo

        # --- Cron jobs ---
        echo "── Cron Jobs ───────────────────────────────────────────────────"
        local cron_entries; cron_entries=$(_read_crontab | { grep "mini-bowling" || true; })
        if [[ -n "$cron_entries" ]]; then
            echo "$cron_entries" | sed 's/^/  /'
        else
            echo "  No mini-bowling cron jobs"
        fi
        echo

        # --- Recent deploys ---
        echo "── Recent Deploys (last 10) ────────────────────────────────────"
        for log_file in "$LOG_DIR"/mini-bowling-*.log; do
            [[ -f "$log_file" ]] || continue
            { grep -h "mini-bowling.sh deploy" "$log_file" || true; } | \
                grep -v "\-\-dry-run\|unschedule\|schedule\|history" || true
        done | sort -r | head -10 | sed 's/^/  /' || true
        echo

        # --- Last 50 log lines ---
        echo "── Recent Log (last 50 lines) ──────────────────────────────────"
        local latest_log
        latest_log=$(find "$LOG_DIR" -name "mini-bowling-*.log" 2>/dev/null | sort -r | head -1)
        if [[ -n "$latest_log" && -f "$latest_log" ]]; then
            echo "  File: $latest_log"
            echo
            tail -50 "$latest_log" 2>/dev/null | sed 's/^/  /'
        else
            echo "  No log files found"
        fi
        echo

        echo "================================================================"
        echo "  End of report"
        echo "================================================================"

    } > "$report_file"

    echo -e "${GREEN}✓ Report saved:${NC} $report_file"
    echo "  Size: $(du -h "$report_file" | cut -f1)"
    echo
    echo "View with: less \"$report_file\""

    # Prune reports older than 30 days
    find "$report_dir" -name "mini-bowling-report-*.txt" -mtime +30 -delete 2>/dev/null || true
}

system_check() {
    # Quick "ready to bowl?" check — green or red, no verbose output
    local fail=0 warn=0
    local lines=()

    _ok()   { lines+=("  ${GREEN}✓${NC}  $*"); }
    _fail() { lines+=("  ${RED}✗${NC}  $*"); (( ++fail )); }
    _warn() { lines+=("  ${YELLOW}!${NC}  $*"); (( ++warn )); }

    # 1. Arduino-cli
    if command -v arduino-cli >/dev/null 2>&1; then
        local _cli_ver; _cli_ver=$(arduino-cli version 2>/dev/null | awk '{print $3}' || echo "?")
        _ok "arduino-cli installed (v${_cli_ver})"
    else
        _fail "arduino-cli (the tool that uploads code to the Arduino) not found — run: mini-bowling.sh install cli"
    fi

    # 1b. Arduino core
    if command -v arduino-cli >/dev/null 2>&1; then
        arduino_core_installed && _ok "Arduino core installed ($ARDUINO_CORE)" || \
            _fail "Arduino core missing ($ARDUINO_CORE) — run: mini-bowling.sh install cli"
    fi

    # 1c. Arduino libraries
    if command -v arduino-cli >/dev/null 2>&1; then
        local _lib_list _missing_libs=()
        _lib_list=$(arduino-cli lib list 2>/dev/null)
        for lib in "${ARDUINO_LIBS[@]}"; do
            echo "$_lib_list" | grep -qF "$lib" || _missing_libs+=("$lib")
        done
        if (( ${#_missing_libs[@]} == 0 )); then
            _ok "All required Arduino libraries installed (${#ARDUINO_LIBS[@]})"
        else
            _fail "Missing Arduino libraries: ${_missing_libs[*]} — run: mini-bowling.sh install cli"
        fi
    fi

    # 2. Project directory / git repo
    if [[ -d "$PROJECT_DIR/.git" ]]; then
        _ok "Arduino project cloned ($PROJECT_DIR)"
    elif [[ -d "$PROJECT_DIR" ]]; then
        _fail "Arduino project directory exists but is not a git repo — run: mini-bowling.sh install setup"
    else
        _fail "Arduino project directory missing — run: mini-bowling.sh install setup"
    fi

    # 3. ScoreMore AppImage
    if [[ -L "$SYMLINK_PATH" && -f "$SYMLINK_PATH" ]]; then
        _ok "ScoreMore application present"
    else
        _warn "ScoreMore application not found at $SYMLINK_PATH — run: mini-bowling.sh scoremore download latest"
    fi

    # 3b. Platform / AppImage runtime
    if scoremore_platform_supported; then
        _ok "Platform supported ($(detected_platform_summary))"
    else
        _fail "ScoreMore requires Raspberry Pi OS 64-bit ($(detected_platform_summary))"
    fi
    if appimage_runtime_ready; then
        _ok "Application runtime ready"
    else
        _warn "libfuse2 not installed — ScoreMore will run in slower extract mode (safe, just slower to start)"
    fi

    # 4. ScoreMore running
    if [[ -n "$(_scoremore_pid)" ]]; then
        _ok "ScoreMore is running"
    else
        _warn "ScoreMore is NOT running — run: mini-bowling.sh scoremore start"
    fi

    # 5. Sketch uploaded
    if _read_arduino_status; then
        local head_commit
        head_commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "")
        if [[ "$head_commit" == "$_ard_commit" ]]; then
            _ok "Arduino has the latest code"
        else
            _warn "Arduino code is out of date — run: mini-bowling.sh deploy"
        fi
    else
        _warn "No code has been uploaded to the Arduino yet — run: mini-bowling.sh deploy"
    fi

    # 6. Arduino serial port
    if ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null | grep -q .; then
        _ok "Arduino detected (USB connection found)"
    else
        _warn "Arduino not detected — check the USB cable between the Pi and the Arduino"
    fi

    # 7. Watchdog
    if _read_crontab | grep -q "# mini-bowling watchdog"; then
        _ok "Auto-restart (watchdog) is active — ScoreMore will restart automatically if it crashes"
    else
        _warn "Auto-restart not enabled — run: mini-bowling.sh scoremore watchdog enable"
    fi

    # 8. Disk space
    local disk_pct_num
    disk_pct_num=$(df / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    if (( disk_pct_num >= 90 )); then
        _fail "Disk is ${disk_pct_num}% full — free up space: mini-bowling.sh system cleanup"
    elif (( disk_pct_num >= 75 )); then
        _warn "Disk is ${disk_pct_num}% full — consider running: mini-bowling.sh system cleanup"
    else
        _ok "Disk is ${disk_pct_num}% full"
    fi

    # Summary
    echo "=== System Check ==="
    echo
    for line in "${lines[@]}"; do
        echo -e "$line"
    done
    echo

    if (( fail > 0 )); then
        echo -e "${RED}✗ NOT ready — $fail issue(s) need attention${NC}"
        return 1
    elif (( warn > 0 )); then
        echo -e "${YELLOW}~ Ready with $warn warning(s)${NC}"
    else
        echo -e "${GREEN}✓ Ready to bowl!${NC}"
    fi
}

system_health() {
    echo "╔══════════════════════════════════════════════════╗"
    echo "║            mini-bowling System Health            ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo

    # 1. Dependencies
    echo "── Dependencies ─────────────────────────────────────"
    local deps=(git curl arduino-cli pgrep pkill nohup realpath)
    local all_deps_ok=true
    for dep in "${deps[@]}"; do
        if command -v "$dep" >/dev/null 2>&1; then
            printf "  ${GREEN}✓${NC}  %s\n" "$dep"
        else
            printf "  ${RED}✗${NC}  %s  NOT FOUND\n" "$dep"
            all_deps_ok=false
        fi
    done
    $all_deps_ok || echo -e "  ${YELLOW}Run 'system doctor' for full diagnostics${NC}"
    echo

    # 2. Pi status (condensed)
    echo "── Raspberry Pi ──────────────────────────────────────"
    echo -n "  Uptime    : "; uptime -p 2>/dev/null || uptime
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local raw; raw=$(cat /sys/class/thermal/thermal_zone0/temp)
        local c=$(( raw / 1000 )) f=$(( raw / 1000 * 9 / 5 + 32 ))
        if (( c >= 80 )); then
            echo -e "  CPU Temp  : ${RED}${c}°C / ${f}°F (CRITICAL)${NC}"
        elif (( c >= 70 )); then
            echo -e "  CPU Temp  : ${YELLOW}${c}°C / ${f}°F (warm)${NC}"
        else
            echo -e "  CPU Temp  : ${GREEN}${c}°C / ${f}°F${NC}"
        fi
    fi
    local mem_total mem_free mem_pct
    mem_total=$(awk '/MemTotal/    {print $2}' /proc/meminfo)
    mem_free=$( awk '/MemAvailable/{print $2}' /proc/meminfo)
    mem_pct=$(( (mem_total - mem_free) * 100 / mem_total ))
    printf "  Memory    : %s%%  (%s MB used of %s MB)\n" \
        "$mem_pct" "$(( (mem_total - mem_free) / 1024 ))" "$(( mem_total / 1024 ))"
    local disk_pct; disk_pct=$(df / 2>/dev/null | awk 'NR==2{print $5}')
    echo "  Disk (/)  : $disk_pct used"
    echo

    # 3. ScoreMore
    echo "── ScoreMore ─────────────────────────────────────────"
    if [[ -n "$(_scoremore_pid)" ]]; then
        echo -e "  ${GREEN}✓${NC}  ScoreMore is running"
    else
        echo -e "  ${RED}✗${NC}  ScoreMore is NOT running"
    fi
    local sm_ver; sm_ver=$(get_installed_scoremore_version)
    if [[ -n "$sm_ver" ]]; then
        echo "     Version : $sm_ver"
    else
        echo -e "  ${YELLOW}!${NC}  No ScoreMore AppImage found at $SYMLINK_PATH"
    fi
    local wd_installed=false
    _read_crontab | grep -q "# mini-bowling watchdog" && wd_installed=true
    $wd_installed && echo -e "  ${GREEN}✓${NC}  Watchdog cron active" || \
        echo -e "  ${YELLOW}-${NC}  Watchdog cron not installed"
    echo

    # 4. Arduino / sketch
    echo "── Arduino ───────────────────────────────────────────────"
    if command -v arduino-cli >/dev/null 2>&1; then
        local sh_cli_ver; sh_cli_ver=$(arduino-cli version 2>/dev/null | head -1 || echo "unknown")
        echo "  arduino-cli : $sh_cli_ver"
        if arduino_core_installed; then
            echo -e "  ${GREEN}✓${NC}  Core: $ARDUINO_CORE"
        else
            echo -e "  ${RED}✗${NC}  Core missing: $ARDUINO_CORE — run: install cli"
        fi
        local sh_lib_list sh_missing=()
        sh_lib_list=$(arduino-cli lib list 2>/dev/null)
        for lib in "${ARDUINO_LIBS[@]}"; do
            echo "$sh_lib_list" | grep -qF "$lib" || sh_missing+=("$lib")
        done
        if (( ${#sh_missing[@]} == 0 )); then
            echo -e "  ${GREEN}✓${NC}  Libraries: all ${#ARDUINO_LIBS[@]} required libraries installed"
        else
            echo -e "  ${YELLOW}!${NC}  Libraries missing: ${sh_missing[*]}"
            echo "     Run: mini-bowling.sh install cli"
        fi
    else
        echo -e "  ${RED}✗${NC}  arduino-cli not found — run: install cli"
    fi
    if _read_arduino_status; then
        local sketch="$_ard_sketch" uploaded="$_ard_time" commit="$_ard_commit" branch="$_ard_branch"
        echo "  Sketch    : $sketch"
        echo "  Uploaded  : $uploaded"
        echo "  Commit    : $commit  (branch: ${branch:-unknown})"
        # Check if repo HEAD is ahead of what's on the Arduino
        if [[ -d "$PROJECT_DIR/.git" ]]; then
            local head_commit
            head_commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "")
            if [[ -n "$head_commit" && "$head_commit" != "$commit" ]]; then
                echo -e "  ${YELLOW}!${NC}  Repo HEAD ($head_commit) differs — deploy may be needed"
            else
                echo -e "  ${GREEN}✓${NC}  Arduino is up to date with repo HEAD"
            fi
        fi
    else
        echo -e "  ${YELLOW}-${NC}  No upload recorded yet"
    fi
    echo

    # 5. Serial logging
    echo "── Serial logging ────────────────────────────────────"
    local pid_file="/tmp/mini-bowling-serial.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC}  Serial logging active (pid $(cat "$pid_file"))"
    else
        echo "  -  Serial logging not running"
    fi
    echo

    echo "── Cron ──────────────────────────────────────────────"
    local cron_entries; cron_entries=$(_read_crontab | grep "mini-bowling" || true)
    if [[ -n "$cron_entries" ]]; then
        while IFS= read -r line; do
            echo "  $line"
        done <<< "$cron_entries"
    else
        echo "  No mini-bowling cron jobs installed"
    fi
    echo
}

system_cron() {
    echo "=== mini-bowling Cron Jobs ==="
    echo

    local cron_all; cron_all=$(_read_crontab)
    if [[ -z "$cron_all" ]]; then
        echo "No crontab for user $USER."
        return 0
    fi

    local cron_entries; cron_entries=$(echo "$cron_all" | grep "mini-bowling" || true)
    if [[ -z "$cron_entries" ]]; then
        echo "No mini-bowling cron jobs found."
        echo
        echo "To add them:"
        echo "  mini-bowling.sh scoremore watchdog enable"
        echo "  mini-bowling.sh deploy schedule HH:MM"
        return 0
    fi

    # Parse and describe each entry
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local min hr desc
        min=$(echo "$line" | awk '{print $1}')
        hr=$( echo "$line" | awk '{print $2}')

        local time_str; time_str=$(printf "%02d:%02d" "$hr" "$min")
        if echo "$line" | grep -q "# mini-bowling watchdog"; then
            desc="Watchdog  (restarts ScoreMore if not running)"
        elif echo "$line" | grep -q "# mini-bowling scheduled deploy"; then
            desc="Scheduled deploy  (daily at ${time_str})"
        elif echo "$line" | grep -q "# mini-bowling os-updates"; then
            desc="OS updates  (daily at ${time_str} — pi update)"
        elif echo "$line" | grep -q "# mini-bowling scoremore-update"; then
            if echo "$line" | grep -q "\-\-check-only"; then
                desc="ScoreMore update check  (daily at ${time_str} — check only)"
            else
                desc="ScoreMore auto-update  (daily at ${time_str} — downloads + restarts if newer)"
            fi
        elif echo "$line" | grep -q "# mini-bowling script-update"; then
            desc="Script update  (daily at ${time_str} — script update)"
        else
            desc="(mini-bowling job)"
        fi
        printf "  %s\n" "$line"
        echo "    → $desc"
        echo
    done <<< "$cron_entries"

    echo "To manage:"
    echo "  scoremore watchdog enable|disable|status"
    echo "  deploy schedule HH:MM  |  deploy unschedule"
    echo "  system os-updates enable [HH:MM]  |  disable  |  status"
    echo "  system scoremore-update enable [HH:MM]  |  disable  |  status"
    echo "  system script-update enable [HH:MM]  |  disable  |  status"
}

# Item 10: doctor - check all required dependencies are present
doctor() {
    echo "=== Dependency Check ==="
    echo

    local all_ok=true
    local deps=(git curl arduino-cli pgrep pkill nohup realpath tee awk df find)

    for dep in "${deps[@]}"; do
        if command -v "$dep" >/dev/null 2>&1; then
            printf "  ${GREEN}✓${NC}  %-20s %s\n" "$dep" "$(command -v "$dep")"
        else
            printf "  ${RED}✗${NC}  %-20s NOT FOUND\n" "$dep"
            all_ok=false
        fi
    done

    echo
    echo "arduino-cli:"
    if command -v arduino-cli >/dev/null 2>&1; then
        local cli_ver; cli_ver=$(arduino-cli version 2>/dev/null | head -1 || echo "unknown")
        printf "  ${GREEN}✓${NC}  %s\n" "$cli_ver"
    else
        printf "  ${RED}✗${NC}  arduino-cli NOT FOUND\n"
        echo "     Fix: mini-bowling.sh install cli"
        all_ok=false
    fi

    echo
    echo "Arduino core:"
    if command -v arduino-cli >/dev/null 2>&1; then
        if arduino_core_installed; then
            printf "  ${GREEN}✓${NC}  %s installed\n" "$ARDUINO_CORE"
        else
            printf "  ${RED}✗${NC}  %s NOT installed\n" "$ARDUINO_CORE"
            echo "     Fix: arduino-cli core install $ARDUINO_CORE"
            all_ok=false
        fi
    else
        printf "  ${YELLOW}-${NC}  skipped (arduino-cli not installed)\n"
    fi

    echo
    echo "Arduino libraries:"
    if command -v arduino-cli >/dev/null 2>&1; then
        local lib_list; lib_list=$(arduino-cli lib list 2>/dev/null)
        for lib in "${ARDUINO_LIBS[@]}"; do
            if echo "$lib_list" | grep -qF "$lib"; then
                printf "  ${GREEN}✓${NC}  %s\n" "$lib"
            else
                printf "  ${RED}✗${NC}  %s  NOT installed\n" "$lib"
                echo "     Fix: arduino-cli lib install \"$lib\""
                all_ok=false
            fi
        done
    else
        printf "  ${YELLOW}-${NC}  skipped (arduino-cli not installed)\n"
    fi

    echo
    # Optional but useful
    local optional=(iwconfig iw sha256sum shasum)
    echo "Optional:"
    for dep in "${optional[@]}"; do
        if command -v "$dep" >/dev/null 2>&1; then
            printf "  ${GREEN}✓${NC}  %-20s %s\n" "$dep" "$(command -v "$dep")"
        else
            printf "  ${YELLOW}-${NC}  %-20s not found (non-critical)\n" "$dep"
        fi
    done

    echo
    echo "Platform:"
    if scoremore_platform_supported; then
        printf "  ${GREEN}✓${NC}  %s\n" "$(detected_platform_summary)"
    else
        printf "  ${RED}✗${NC}  %s\n" "$(detected_platform_summary)"
        echo "     ScoreMore is configured for Raspberry Pi OS 64-bit / arm64."
        echo "     Fix: install a 64-bit Raspberry Pi OS image on the Pi."
        all_ok=false
    fi

    echo
    echo "ScoreMore runtime:"
    if appimage_runtime_ready; then
        printf "  ${GREEN}✓${NC}  AppImage runtime looks ready\n"
    else
        printf "  ${YELLOW}!${NC}  libfuse2 not detected\n"
        echo "     The script will fall back to APPIMAGE_EXTRACT_AND_RUN=1 on launch."
        echo "     For best compatibility, install libfuse2 if available on your distro."
    fi
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        printf "  ${GREEN}✓${NC}  Wayland session detected (%s)\n" "$WAYLAND_DISPLAY"
    elif [[ -n "${DISPLAY:-}" ]]; then
        printf "  ${GREEN}✓${NC}  X11/Xwayland display detected (%s)\n" "$DISPLAY"
    else
        printf "  ${YELLOW}!${NC}  No active GUI session detected right now\n"
        echo "     Cron/watchdog launches may still work if a desktop user logs in later."
    fi

    echo
    # Directory checks
    echo "Directories:"
    for dir in "$PROJECT_DIR" "$SCOREMORE_DIR" "$LOG_DIR"; do
        if [[ -d "$dir" ]]; then
            printf "  ${GREEN}✓${NC}  %s\n" "$dir"
        else
            printf "  ${YELLOW}-${NC}  %s  (not created yet — run: mini-bowling.sh install create-dir)\n" "$dir"
        fi
    done

    echo
    # Serial port access (dialout group lets the user talk to USB devices like the Arduino)
    echo "Arduino USB access:"
    local current_user
    current_user=$(id -un)
    if id -nG "$current_user" 2>/dev/null | grep -qw "dialout"; then
        # User is in dialout in /etc/group - but check if current session has it active
        if ! id -Gn 2>/dev/null | grep -qw "dialout"; then
            printf "  ${YELLOW}!${NC}  $current_user has USB access but needs to log out and back in\n"
            echo "     The permission was added but your current session does not have it yet."
            echo "     Fix: log out and log back in (or reboot)"
        else
            printf "  ${GREEN}✓${NC}  $current_user has USB access to the Arduino\n"
        fi
    else
        printf "  ${RED}✗${NC}  $current_user does not have USB access to the Arduino\n"
        echo "     Without this permission, uploading code will fail."
        echo "     Fix: sudo usermod -aG dialout $current_user"
        echo "     Then log out and back in (or reboot) for the change to take effect."
        all_ok=false
    fi

    echo
    if $all_ok; then
        echo -e "${GREEN}✓ All checks passed${NC}"
    else
        echo -e "${RED}✗ Some checks failed — see above for fix commands${NC}"
        return 1
    fi
}

# Item 1: pre-flight check - verify all conditions before a deploy
preflight() {
    local quick=false
    for arg in "$@"; do
        [[ "$arg" == "--quick" || "$arg" == "-q" ]] && quick=true
    done

    echo "=== Pre-flight Check ==="
    $quick && echo -e "    ${YELLOW}(quick mode — skipping network checks 3, 8, 9)${NC}"
    echo

    local all_ok=true

    # 0. Platform support
    if scoremore_platform_supported; then
        echo -e "  ${GREEN}✓${NC}  Platform supported: $(detected_platform_summary)"
    else
        echo -e "  ${RED}✗${NC}  Unsupported platform for ScoreMore: $(detected_platform_summary)"
        echo "     Use Raspberry Pi OS 64-bit / arm64 on a Raspberry Pi 5."
        all_ok=false
    fi

    # 1. arduino-cli installed
    if command -v arduino-cli >/dev/null 2>&1; then
        local pf_cli_ver; pf_cli_ver=$(arduino-cli version 2>/dev/null | awk '{print $3}' || echo "?")
        echo -e "  ${GREEN}✓${NC}  arduino-cli installed (v${pf_cli_ver})"
    else
        echo -e "  ${RED}✗${NC}  arduino-cli not found — run: mini-bowling.sh install cli"
        all_ok=false
    fi

    # 1b. Arduino core installed
    if command -v arduino-cli >/dev/null 2>&1; then
        if arduino_core_installed; then
            echo -e "  ${GREEN}✓${NC}  Arduino core installed: $ARDUINO_CORE"
        else
            echo -e "  ${RED}✗${NC}  Arduino core missing: $ARDUINO_CORE"
            echo "     Run: arduino-cli core install $ARDUINO_CORE"
            all_ok=false
        fi
    fi

    # 1c. Arduino libraries
    if command -v arduino-cli >/dev/null 2>&1; then
        local pf_lib_list pf_missing=()
        pf_lib_list=$(arduino-cli lib list 2>/dev/null)
        for lib in "${ARDUINO_LIBS[@]}"; do
            echo "$pf_lib_list" | grep -qF "$lib" || pf_missing+=("$lib")
        done
        if (( ${#pf_missing[@]} == 0 )); then
            echo -e "  ${GREEN}✓${NC}  All required Arduino libraries installed (${#ARDUINO_LIBS[@]})"
        else
            echo -e "  ${RED}✗${NC}  Missing Arduino libraries: ${pf_missing[*]}"
            echo "     Run: mini-bowling.sh install cli"
            all_ok=false
        fi
    fi

    # 2. Arduino port reachable
    local port
    port=$(find_arduino_port) || true
    if [[ -n "$port" ]] && [[ -c "$port" ]]; then
        echo -e "  ${GREEN}✓${NC}  Arduino port found: $port"
    else
        echo -e "  ${RED}✗${NC}  No Arduino serial port found"
        all_ok=false
    fi

    # 3. Internet reachable (skipped in quick mode)
    if $quick; then
        echo -e "  ${YELLOW}-${NC}  Internet check skipped (--quick)"
    elif ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC}  Internet reachable"
    else
        echo -e "  ${RED}✗${NC}  No internet connection"
        all_ok=false
    fi

    # 4. Disk space (require 500MB free)
    local avail_kb
    avail_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
    local avail_mb=$(( avail_kb / 1024 ))
    if (( avail_kb >= 512000 )); then
        echo -e "  ${GREEN}✓${NC}  Disk space: ${avail_mb}MB free"
    else
        echo -e "  ${RED}✗${NC}  Low disk space: ${avail_mb}MB free (500MB recommended)"
        all_ok=false
    fi

    # 5. CPU temperature
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local raw_temp temp_c
        raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp)
        temp_c=$(( raw_temp / 1000 ))
        if (( temp_c >= 80 )); then
            echo -e "  ${RED}✗${NC}  CPU temperature critical: ${temp_c}°C (throttling likely)"
            all_ok=false
        elif (( temp_c >= 70 )); then
            echo -e "  ${YELLOW}!${NC}  CPU temperature warm: ${temp_c}°C"
        else
            echo -e "  ${GREEN}✓${NC}  CPU temperature: ${temp_c}°C"
        fi
    fi

    # 6. Git repo clean
    if [[ -d "$PROJECT_DIR/.git" ]]; then
        if git -C "$PROJECT_DIR" diff --quiet && git -C "$PROJECT_DIR" diff --cached --quiet; then
            echo -e "  ${GREEN}✓${NC}  Git repo clean"
        else
            echo -e "  ${YELLOW}!${NC}  Git repo has uncommitted local changes"
        fi
    else
        echo -e "  ${YELLOW}!${NC}  Project directory is not a git repo: $PROJECT_DIR"
    fi

    # 7. ScoreMore symlink valid
    if [[ -L "$SYMLINK_PATH" ]] && [[ -f "$SYMLINK_PATH" ]]; then
        echo -e "  ${GREEN}✓${NC}  ScoreMore symlink valid: $SYMLINK_PATH"
    elif [[ -L "$SYMLINK_PATH" ]]; then
        echo -e "  ${YELLOW}!${NC}  ScoreMore symlink is broken: $SYMLINK_PATH"
    else
        echo -e "  ${YELLOW}!${NC}  No ScoreMore symlink at $SYMLINK_PATH — run: mini-bowling.sh scoremore download <version>"
    fi

    # 7b. AppImage runtime / GUI session
    if appimage_runtime_ready; then
        echo -e "  ${GREEN}✓${NC}  AppImage runtime ready"
    else
        echo -e "  ${YELLOW}!${NC}  libfuse2 not detected — ScoreMore will use APPIMAGE_EXTRACT_AND_RUN=1"
    fi
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        echo -e "  ${GREEN}✓${NC}  Wayland session detected: $WAYLAND_DISPLAY"
    elif [[ -n "${DISPLAY:-}" ]]; then
        echo -e "  ${GREEN}✓${NC}  X11/Xwayland display detected: $DISPLAY"
    else
        echo -e "  ${YELLOW}!${NC}  No active GUI session detected — ScoreMore launch may depend on desktop login"
    fi

    # 8. Remote git update check (skipped in quick mode)
    if $quick; then
        echo -e "  ${YELLOW}-${NC}  Remote git check skipped (--quick)"
    elif [[ -d "$PROJECT_DIR/.git" ]] && ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        git -C "$PROJECT_DIR" fetch --quiet origin "$DEFAULT_GIT_BRANCH" 2>/dev/null || true
        local behind
        behind=$(git -C "$PROJECT_DIR" rev-list HEAD..origin/"$DEFAULT_GIT_BRANCH" --count 2>/dev/null || echo 0)
        if [[ "$behind" -gt 0 ]]; then
            echo -e "  ${YELLOW}!${NC}  $behind new commit(s) available on remote — run: mini-bowling.sh deploy"
        else
            echo -e "  ${GREEN}✓${NC}  Git repo up to date with remote"
        fi
    fi

    # 9. ScoreMore update check (skipped in quick mode)
    if $quick; then
        echo -e "  ${YELLOW}-${NC}  ScoreMore update check skipped (--quick)"
    else
        local sm_page sm_latest
        sm_page=$(curl --silent --fail --max-time 5 "https://www.scoremorebowling.com/download" 2>/dev/null || true)
        sm_latest=$(extract_scoremore_version "$sm_page")
        if [[ -n "$sm_latest" ]]; then
            local sm_installed; sm_installed=$(get_installed_scoremore_version)
            if [[ -n "$sm_installed" && "$sm_latest" == "$sm_installed" ]]; then
                echo -e "  ${GREEN}✓${NC}  ScoreMore up to date ($sm_installed)"
            elif [[ -n "$sm_installed" ]]; then
                echo -e "  ${YELLOW}!${NC}  ScoreMore update available: $sm_installed → $sm_latest — run: mini-bowling.sh scoremore download $sm_latest"
            else
                echo -e "  ${YELLOW}!${NC}  ScoreMore latest: $sm_latest — run: mini-bowling.sh scoremore download $sm_latest"
            fi
        fi
    fi

    echo
    if $quick; then
        echo -e "    ${YELLOW}(3 network checks skipped — run without --quick for full check)${NC}"
        echo
    fi
    if $all_ok; then
        echo -e "${GREEN}✓ All checks passed — ready to deploy${NC}"
    else
        echo -e "${RED}✗ Some checks failed — review above before deploying${NC}"
        return 1
    fi
}

# Item 9: guided first-time setup
install_setup() {
    echo "=== mini-bowling First-Time Setup ==="
    echo "This will run through the initial setup steps for a fresh Raspberry Pi."
    if scoremore_platform_supported; then
        echo -e "Platform: ${GREEN}$(detected_platform_summary)${NC}"
    else
        echo -e "Platform: ${RED}$(detected_platform_summary)${NC}"
        echo "Warning: ScoreMore is configured for Raspberry Pi OS 64-bit / arm64."
        echo "Continue only if this Pi is meant to run the arm64 ScoreMore AppImage."
    fi
    echo

    # Step 1: create directories
    echo "Step 1/9: Creating required directories..."
    ensure_directories
    echo

    # Step 2: install arduino-cli
    echo "Step 2/9: Checking arduino-cli..."
    install_cli
    echo

    # Step 3: clone or verify project directory
    echo "Step 3/9: Arduino project directory"
    if [[ -d "$PROJECT_DIR/.git" ]]; then
        echo -e "  ${GREEN}✓${NC}  Repo already cloned: $PROJECT_DIR"
        echo "  Running git pull to get latest code..."
        git -C "$PROJECT_DIR" pull origin "$DEFAULT_GIT_BRANCH" || \
            echo -e "  ${YELLOW}Warning: git pull failed — check network and try 'mini-bowling.sh code branch update' later${NC}"
    elif [[ -d "$PROJECT_DIR" ]] && [[ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]]; then
        echo -e "  ${YELLOW}Directory exists with content but is not a git repo:${NC} $PROJECT_DIR"
        echo "  Skipped — if this is intentional, ignore this warning."
    else
        echo "  Cloning Arduino project from $PROJECT_REPO..."
        echo "  Target: $PROJECT_DIR"
        if ! git ls-remote --quiet "$PROJECT_REPO" HEAD >/dev/null 2>&1; then
            echo -e "  ${RED}✗ Cannot reach repo: $PROJECT_REPO${NC}"
            echo "  Check your network connection."
            echo "  Skipped — run manually: git clone $PROJECT_REPO $PROJECT_DIR"
        else
            git clone "$PROJECT_REPO" "$PROJECT_DIR" || die "git clone failed"
            echo -e "  ${GREEN}✓ Cloned to $PROJECT_DIR${NC}"
        fi
    fi
    echo

    # Step 4: download ScoreMore
    echo "Step 4/9: Download ScoreMore"
    if [[ -L "$SYMLINK_PATH" ]] && [[ -f "$SYMLINK_PATH" ]]; then
        local current_ver; current_ver=$(get_installed_scoremore_version)
        echo "  ScoreMore already installed: $current_ver"
        echo -n "  Download latest version anyway? [y/N]: "
        read -r dl_answer
        if [[ "${dl_answer,,}" == "y" ]]; then
            local latest_ver
            latest_ver=$(_fetch_latest_scoremore_version)
            if [[ -n "$latest_ver" ]]; then
                download_scoremore_version "$latest_ver" || \
                    echo -e "  ${YELLOW}Warning: download failed — run 'mini-bowling.sh scoremore download latest' later${NC}"
            else
                echo -e "  ${YELLOW}Could not determine latest version — run 'mini-bowling.sh scoremore download latest' manually.${NC}"
            fi
        fi
    else
        echo "  Downloading latest ScoreMore..."
        local latest_ver
        latest_ver=$(_fetch_latest_scoremore_version)
        if [[ -n "$latest_ver" ]]; then
            download_scoremore_version "$latest_ver" || \
                echo -e "  ${YELLOW}Warning: download failed — run 'mini-bowling.sh scoremore download latest' later${NC}"
        else
            echo -e "  ${YELLOW}Could not determine latest version — run 'mini-bowling.sh scoremore download latest' manually.${NC}"
        fi
    fi
    echo

    # Step 5: install script + completion to /usr/bin
    echo "Step 5/9: Installing script to /usr/bin..."
    local script_src; script_src=$(realpath "$0")
    local script_dst="/usr/bin/mini-bowling.sh"
    local completion_dst="/etc/bash_completion.d/mini-bowling.sh"

    # Install the script
    if [[ "$script_src" == "$script_dst" ]]; then
        echo -e "  ${GREEN}✓${NC}  Script already at $script_dst"
    else
        if sudo cp "$script_src" "$script_dst" && sudo chmod +x "$script_dst"; then
            echo -e "  ${GREEN}✓${NC}  Installed: $script_dst"
        else
            echo -e "  ${YELLOW}!${NC}  Could not install to $script_dst — do you have sudo access?"
            echo "       Run manually: sudo cp $script_src $script_dst"
        fi
    fi

    # Install the completion file — look for it alongside the script
    local completion_src
    for _candidate in \
        "$(dirname "$script_src")/mini-bowling-completion.bash" \
        "$HOME/mini-bowling-completion.bash" \
        "./mini-bowling-completion.bash"; do
        if [[ -f "$_candidate" ]]; then
            completion_src="$_candidate"
            break
        fi
    done

    if [[ -z "${completion_src:-}" ]]; then
        echo -e "  ${YELLOW}!${NC}  mini-bowling-completion.bash not found — tab completion not installed."
        echo "       Download it from: $SCRIPT_REPO"
        echo "       Then run: sudo cp mini-bowling-completion.bash $completion_dst"
    else
        if sudo cp "$completion_src" "$completion_dst"; then
            echo -e "  ${GREEN}✓${NC}  Tab completion installed: $completion_dst"
            # shellcheck disable=SC1090
            source "$completion_dst" 2>/dev/null || true
        else
            echo -e "  ${YELLOW}!${NC}  Could not install completion file."
            echo "       Run manually: sudo cp $completion_src $completion_dst"
        fi
    fi
    echo

    # Step 6: autostart
    echo "Step 6/9: Configuring ScoreMore autostart..."
    local desktop_file="$HOME/.config/autostart/scoremore.desktop"
    if [[ -f "$desktop_file" ]]; then
        echo -e "  ${GREEN}✓${NC}  Autostart already configured: $desktop_file"
    else
        setup_autostart
    fi
    echo

    # Step 7: doctor check
    echo "Step 7/9: Checking dependencies..."
    doctor
    echo

    # Step 8: watchdog
    echo "Step 8/9: ScoreMore watchdog (restarts ScoreMore every 5 min if it crashes)"
    if _read_crontab | grep -q "# mini-bowling watchdog"; then
        echo -e "  ${GREEN}✓${NC}  Watchdog already enabled."
    else
        echo -n "  Enable watchdog? [Y/n]: "
        read -r wd_answer
        if [[ "${wd_answer,,}" != "n" ]]; then
            setup_watchdog enable
        else
            echo "  Skipped — run 'mini-bowling.sh scoremore watchdog enable' at any time."
        fi
    fi
    echo

    # Step 9: schedule
    echo "Step 9/9: Schedule daily deploy (optional)"
    local existing_schedule
    existing_schedule=$(_read_crontab | grep "# mini-bowling scheduled deploy" || true)
    if [[ -n "$existing_schedule" ]]; then
        echo -e "  ${GREEN}✓${NC}  Deploy already scheduled: $existing_schedule"
        echo -n "  Change schedule? [y/N]: "
        read -r resched_answer
        [[ "${resched_answer,,}" != "y" ]] && { echo; return 0; } || true
    fi
    echo -n "  Enter a daily deploy time in HH:MM format, or press Enter to skip: "
    read -r sched_time
    if [[ -n "$sched_time" ]]; then
        schedule_deploy "$sched_time"
    else
        echo "  Skipped — run 'mini-bowling.sh deploy schedule HH:MM' at any time."
    fi

    echo
    echo -e "${GREEN}✓ Setup complete.${NC}"
    echo
    echo "Next steps:"
    echo "  1. Connect the Arduino via USB and confirm it is detected:"
    echo "       mini-bowling.sh system ports"
    echo "  2. Most Arduinos show up as /dev/ttyACM0 automatically."
    echo "     If yours shows a different port (e.g. /dev/ttyUSB0), tell the script:"
    echo "       export PORT=/dev/ttyUSB0"
    echo "     To make this permanent across reboots, add that line to ~/.bashrc"
    echo "  3. Run a pre-flight check:  mini-bowling.sh system preflight"
    echo "  4. Run your first deploy:   mini-bowling.sh deploy"
}

setup_autostart() {
    local autostart_dir="$HOME/.config/autostart"
    local desktop_file="$autostart_dir/scoremore.desktop"

    mkdir -p "$autostart_dir" || die "Cannot create $autostart_dir"

    if [[ -f "$desktop_file" ]]; then
        echo -e "${YELLOW}Autostart file already exists — overwriting:${NC} $desktop_file"
    fi

    cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=ScoreMore
Exec=env APPIMAGE_EXTRACT_AND_RUN=1 "$HOME/Desktop/ScoreMore.AppImage"
Terminal=false
EOF

    echo -e "${GREEN}✓ Autostart configured:${NC} $desktop_file"
}

remove_autostart() {
    local desktop_file="$HOME/.config/autostart/scoremore.desktop"

    if [[ ! -f "$desktop_file" ]]; then
        echo "Autostart file not found — nothing to remove: $desktop_file"
        return 0
    fi

    rm -- "$desktop_file" && echo -e "${GREEN}✓ Autostart removed:${NC} $desktop_file" \
        || die "Failed to remove $desktop_file"
}

schedule_deploy() {
    local time="${1?Missing time argument — usage: mini-bowling.sh schedule-deploy HH:MM}"

    # Validate HH:MM format
    [[ "$time" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || \
        die "Invalid time format: '$time' — expected HH:MM (e.g. 02:30, 14:00)"

    local hour="${time%%:*}"
    local minute="${time##*:}"
    local script_path
    script_path=$(command -v mini-bowling.sh 2>/dev/null) || script_path="$0"
    script_path=$(realpath -- "$script_path")

    # Warn if the script isn't in a standard system PATH location - cron runs with
    # a minimal PATH (/usr/bin:/bin) so it won't find scripts in ~/bin or similar
    case "$script_path" in
        /usr/bin/*|/usr/local/bin/*|/bin/*)
            : ;;  # fine — in system PATH
        *)
            echo -e "${YELLOW}Warning: script is at $script_path${NC}"
            echo "  Cron uses a minimal PATH and may not find it there."
            echo "  Recommended: sudo cp \"$script_path\" /usr/bin/mini-bowling.sh"
            echo
            ;;
    esac

    local cron_marker="# mini-bowling scheduled deploy"
    local cron_job="$minute $hour * * * \"$script_path\" deploy $cron_marker"

    # Remove any existing scheduled deploy entry, then add the new one
    local existing
    existing=$(_read_crontab)

    local filtered
    filtered=$(echo "$existing" | grep -v "$cron_marker" || true)

    # Write updated crontab
    {
        [[ -n "$filtered" ]] && echo "$filtered"
        echo "$cron_job"
    } | crontab - || die "Failed to update crontab"

    echo -e "${GREEN}✓ Scheduled deploy set:${NC} every day at ${time}"
    echo "  Cron entry: $cron_job"
    echo
    echo "Run 'mini-bowling.sh deploy unschedule' to remove."
}

unschedule_deploy() {
    local cron_marker="# mini-bowling scheduled deploy"

    local existing
    existing=$(_read_crontab)

    if ! echo "$existing" | grep -q "$cron_marker"; then
        echo "No scheduled deploy found — nothing to remove."
        return 0
    fi

    echo "$existing" | grep -v "$cron_marker" | crontab - || die "Failed to update crontab"
    echo -e "${GREEN}✓ Scheduled deploy removed.${NC}"
}

# ------------------------------------------------
#  Scheduled maintenance cron helpers
# ------------------------------------------------

_cron_script_path() {
    local sp
    sp=$(command -v mini-bowling.sh 2>/dev/null) || sp=$(realpath "$0")
    echo "$sp"
}

setup_os_updates_schedule() {
    local subcmd="${1:-enable}"
    local time="${2:-03:00}"
    local cron_marker="# mini-bowling os-updates"
    local script_path; script_path=$(_cron_script_path)

    case "$subcmd" in
        enable)
            [[ "$time" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || \
                die "Invalid time format: '$time' — expected HH:MM (e.g. 03:00)"
            local hour="${time%%:*}" minute="${time##*:}"
            local cron_job="$minute $hour * * * \"$script_path\" pi update >> $LOG_DIR/os-update.log 2>&1 $cron_marker"
            _cron_manage enable "$cron_marker" "OS updates" "$cron_job"
            echo -e "${GREEN}✓ OS updates scheduled:${NC} daily at ${time}"
            echo "  Log: $LOG_DIR/os-update.log"
            echo "  Run 'mini-bowling.sh system os-updates disable' to remove."
            ;;
        disable) _cron_manage disable "$cron_marker" "OS updates" ;;
        status)  _cron_manage status  "$cron_marker" "OS updates" ;;
        *)       die "Unknown subcommand: '$subcmd' — use: enable [HH:MM], disable, status" ;;
    esac
}

setup_scoremore_update_schedule() {
    local subcmd="${1:-enable}"
    local time="${2:-03:30}"
    # Optional third arg: --check-only (log only, don't auto-download)
    local mode="${3:-}"
    local cron_marker="# mini-bowling scoremore-update"
    local script_path; script_path=$(_cron_script_path)

    case "$subcmd" in
        enable)
            [[ "$time" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || \
                die "Invalid time format: '$time' — expected HH:MM (e.g. 03:30)"
            local hour="${time%%:*}" minute="${time##*:}"
            # Use scoremore update (auto-download+restart) by default;
            # --check-only uses scoremore update --check-only (report only)
            local sm_cmd="scoremore update"
            [[ "$mode" == "--check-only" ]] && sm_cmd="scoremore update --check-only"
            local cron_job="$minute $hour * * * \"$script_path\" $sm_cmd >> $LOG_DIR/scoremore-update.log 2>&1 $cron_marker"
            _cron_manage enable "$cron_marker" "ScoreMore update" "$cron_job"
            if [[ "$mode" == "--check-only" ]]; then
                echo -e "${GREEN}✓ ScoreMore update check scheduled:${NC} daily at ${time} (check only — no auto-download)"
            else
                echo -e "${GREEN}✓ ScoreMore auto-update scheduled:${NC} daily at ${time} (downloads + restarts if newer version found)"
            fi
            echo "  Log: $LOG_DIR/scoremore-update.log"
            echo "  Run 'mini-bowling.sh system scoremore-update disable' to remove."
            ;;
        disable) _cron_manage disable "$cron_marker" "ScoreMore update" ;;
        status)  _cron_manage status  "$cron_marker" "ScoreMore update" ;;
        *)       die "Unknown subcommand: '$subcmd' — use: enable [HH:MM], disable, status" ;;
    esac
}

setup_script_update_schedule() {
    local subcmd="${1:-enable}"
    local time="${2:-04:00}"
    local cron_marker="# mini-bowling script-update"
    local script_path; script_path=$(_cron_script_path)

    case "$subcmd" in
        enable)
            [[ "$time" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || \
                die "Invalid time format: '$time' — expected HH:MM (e.g. 04:00)"
            local hour="${time%%:*}" minute="${time##*:}"
            local cron_job="$minute $hour * * * \"$script_path\" script update >> $LOG_DIR/script-update.log 2>&1 $cron_marker"
            _cron_manage enable "$cron_marker" "Script update" "$cron_job"
            echo -e "${GREEN}✓ Script update scheduled:${NC} daily at ${time}"
            echo "  Log: $LOG_DIR/script-update.log"
            echo "  Run 'mini-bowling.sh system script-update disable' to remove."
            ;;
        disable) _cron_manage disable "$cron_marker" "Script update" ;;
        status)  _cron_manage status  "$cron_marker" "Script update" ;;
        *)       die "Unknown subcommand: '$subcmd' — use: enable [HH:MM], disable, status" ;;
    esac
}

# ------------------------------------------------
#  Arduino / Deploy Management
# ------------------------------------------------

# Item 1: rollback to previous git commit and re-upload
cmd_rollback() {
    require_git_repo
    require_arduino_cli
    require_arduino_core

    local steps="${1:-1}"
    [[ "$steps" =~ ^[0-9]+$ ]] || die "Invalid step count: '$steps' — must be a number"

    echo "Current commit:"
    git -C "$PROJECT_DIR" log --oneline -1
    echo

    # Item 4: confirmation prompt - rollback resets git history
    echo -e "${YELLOW}Warning:${NC} This will reset $steps git commit(s) with 'git reset --hard'."
    echo "This rewrites local git history. Recoverable via 'git reflog' within 90 days."
    local countdown=5
    echo -n "Press Ctrl+C to cancel, or wait $countdown seconds to continue"
    while [[ $countdown -gt 0 ]]; do
        sleep 1
        countdown=$(( countdown - 1 ))
        echo -n "."
    done
    echo
    echo

    echo -e "${YELLOW}Rolling back $steps commit(s)...${NC}"
    git -C "$PROJECT_DIR" reset --hard "HEAD~${steps}" || die "git reset failed"

    echo "Now at:"
    git -C "$PROJECT_DIR" log --oneline -1
    echo

    # Use the same sketch that was last uploaded, not a hardcoded name
    local sketch="Everything"
    if _read_arduino_status && [[ -n "$_ard_sketch" && -d "$PROJECT_DIR/$_ard_sketch" ]]; then
        sketch="$_ard_sketch"
    fi
    echo "→ Uploading sketch: $sketch"

    # Verify port before killing ScoreMore
    local port
    port=$(find_arduino_port) || true
    verify_arduino_port "$port"

    # Hold the deploy lock so the watchdog doesn't restart ScoreMore mid-upload
    local deploy_lock="/tmp/mini-bowling-deploy.lock"
    echo "$$" > "$deploy_lock"
    trap 'rm -f "$deploy_lock"' EXIT

    echo "Terminating ScoreMore before upload..."
    kill_scoremore_gracefully

    echo "→ Compiling + uploading $sketch sketch..."
    local -a timeout_cmd=()
    command -v timeout >/dev/null 2>&1 && timeout_cmd=(timeout 120)

    "${timeout_cmd[@]}" arduino-cli compile --upload \
        --port "$port" \
        --fqbn "$BOARD" \
        "${PROJECT_DIR}/${sketch}" || {
        local exit_code=$?
        rm -f "$deploy_lock"
        trap - EXIT
        [[ $exit_code -eq 124 ]] && die "arduino-cli timed out after 120s — Arduino may be locked up"
        die "arduino-cli failed (exit $exit_code)"
    }

    # Record what was uploaded
    mkdir -p "$LOG_DIR"
    {
        echo "$sketch"
        echo "$(date '+%Y-%m-%d %H:%M:%S')"
        echo "$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
        echo "$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo '')"
        echo "$(_current_branch)"
    } > "$ARDUINO_STATUS_FILE"

    trap - EXIT
    rm -f "$deploy_lock"
    start_scoremore
}

check_scoremore_update() {
    echo "Checking ScoreMore latest version from scoremorebowling.com..."

    local latest
    latest=$(_fetch_latest_scoremore_version)
    [[ -n "$latest" ]] || die "Could not reach scoremorebowling.com or parse version — check network"

    echo "Latest available : $latest"

    # Get currently installed version from symlink filename
    local installed; installed=$(get_installed_scoremore_version)

    if [[ -z "$installed" ]]; then
        echo "Installed        : none"
        echo
        echo "Run: mini-bowling.sh scoremore download $latest"
        return 0
    fi

    echo "Installed        : $installed"

    if [[ "$latest" == "$installed" ]]; then
        echo -e "${GREEN}✓ ScoreMore is up to date${NC}"
    else
        echo -e "${YELLOW}→ Update available:${NC} $installed → $latest"
        echo
        echo "Run: mini-bowling.sh scoremore download $latest"
    fi
}

scoremore_update() {
    # Check for a newer ScoreMore version; download + restart if found.
    # With --check-only: report but do not download (same as check-update).
    local auto=true
    [[ "${1:-}" == "--check-only" ]] && auto=false

    echo "=== ScoreMore Update ==="
    echo

    echo "Checking scoremorebowling.com for latest version..."
    local latest
    latest=$(_fetch_latest_scoremore_version)
    [[ -n "$latest" ]] || die "Could not reach scoremorebowling.com or parse version — check network"

    local installed; installed=$(get_installed_scoremore_version)

    echo "Installed : ${installed:-none}"
    echo "Latest    : $latest"
    echo

    if [[ -n "$installed" && "$latest" == "$installed" ]]; then
        echo -e "${GREEN}✓ ScoreMore is already up to date${NC}"
        return 0
    fi

    if ! $auto; then
        echo -e "${YELLOW}→ Update available:${NC} ${installed:-none} → $latest"
        echo "  Run: mini-bowling.sh scoremore update"
        return 0
    fi

    echo -e "${YELLOW}→ Updating:${NC} ${installed:-none} → $latest"
    echo

    # Stop ScoreMore before downloading to avoid file-in-use issues
    local was_running=false
    if [[ -n "$(_scoremore_pid)" ]]; then
        was_running=true
        echo "Stopping ScoreMore..."
        kill_scoremore_gracefully
    fi

    if ! download_scoremore_version "$latest"; then
        echo -e "${RED}✗ Download failed${NC}"
        if $was_running; then
            echo "Restarting previous ScoreMore version..."
            start_scoremore
        fi
        die "ScoreMore update failed"
    fi

    echo -e "${GREEN}✓ ScoreMore updated to $latest${NC}"
    if $was_running; then
        echo "Restarting ScoreMore..."
        start_scoremore
    fi
}

# Item 3: check if remote has new commits without pulling
check_update() {
    require_git_repo

    echo "Checking for updates on ${DEFAULT_GIT_BRANCH}..."
    git -C "$PROJECT_DIR" fetch --quiet origin "$DEFAULT_GIT_BRANCH" 2>/dev/null || \
        die "git fetch failed — is the network available?"

    local local_ref remote_ref
    local_ref=$(git -C "$PROJECT_DIR" rev-parse HEAD)
    remote_ref=$(git -C "$PROJECT_DIR" rev-parse "origin/${DEFAULT_GIT_BRANCH}")

    echo "Local  : $(git -C "$PROJECT_DIR" log --oneline -1 HEAD)"

    if [[ "$local_ref" == "$remote_ref" ]]; then
        echo -e "${GREEN}✓ Already up to date${NC}"
        return 0
    fi

    local count
    count=$(git -C "$PROJECT_DIR" rev-list HEAD..origin/"$DEFAULT_GIT_BRANCH" --count)
    echo "Remote : $count new commit(s) available:"
    git -C "$PROJECT_DIR" log --oneline HEAD..origin/"$DEFAULT_GIT_BRANCH"
    echo
    echo "Run 'mini-bowling.sh deploy' to apply."
}

cmd_component_upgrade() {
    local check_only=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check|-c) check_only=true; shift ;;
            *) die "Unknown option: '$1' — use: component-upgrade [--check]" ;;
        esac
    done

    local _updates=0

    if $check_only; then
        echo "=== Component Update Check ==="
    else
        echo "=== Component Upgrade ==="
    fi
    echo

    # ── 1. mini-bowling.sh script ─────────────────────────────────────────────
    echo "Script (mini-bowling.sh)"
    echo "  Current : v${SCRIPT_VERSION}"
    local cu_remote_ver=""
    if command -v curl >/dev/null 2>&1; then
        local cu_repo="${SCRIPT_REPO#https://github.com/}"; cu_repo="${cu_repo%.git}"
        cu_remote_ver=$(curl -fsSL --max-time 8 \
            "https://raw.githubusercontent.com/${cu_repo}/refs/heads/${DEFAULT_GIT_BRANCH}/mini-bowling.sh" \
            2>/dev/null | grep -m1 'SCRIPT_VERSION=' | sed 's/.*SCRIPT_VERSION="//;s/".*//' || echo "")
    fi
    if [[ -z "$cu_remote_ver" ]]; then
        echo -e "  Remote  : ${YELLOW}unavailable${NC}"
    elif [[ "$cu_remote_ver" == "$SCRIPT_VERSION" ]]; then
        echo -e "  Remote  : ${GREEN}✓ up to date (v${cu_remote_ver})${NC}"
    else
        echo -e "  Remote  : ${YELLOW}v${cu_remote_ver} available${NC}"
        (( ++_updates )) || true
        if ! $check_only; then
            update_script || echo -e "  ${YELLOW}Warning: script update failed${NC}"
        fi
    fi
    echo

    # ── 2. Arduino code (project repo) ────────────────────────────────────────
    echo "Arduino code"
    if [[ ! -d "$PROJECT_DIR/.git" ]]; then
        echo -e "  ${YELLOW}Project repo not found: $PROJECT_DIR — run: deploy${NC}"
    else
        local cu_branch cu_commit
        cu_branch=$(_current_branch)
        cu_commit=$(git -C "$PROJECT_DIR" log --oneline -1 2>/dev/null || echo "unknown")
        echo "  Branch  : $cu_branch"
        echo "  HEAD    : $cu_commit"
        if git -C "$PROJECT_DIR" fetch --quiet origin "$cu_branch" 2>/dev/null; then
            local cu_behind
            cu_behind=$(git -C "$PROJECT_DIR" rev-list "HEAD..origin/${cu_branch}" --count 2>/dev/null || echo "?")
            if [[ "$cu_behind" == "0" ]]; then
                echo -e "  Remote  : ${GREEN}✓ up to date${NC}"
            else
                echo -e "  Remote  : ${YELLOW}${cu_behind} new commit(s) available${NC}"
                (( ++_updates )) || true
                if ! $check_only; then
                    git -C "$PROJECT_DIR" pull --quiet origin "$cu_branch" \
                        && echo -e "  ${GREEN}✓ Arduino code updated — run: deploy to upload${NC}" \
                        || echo -e "  ${YELLOW}Warning: git pull failed${NC}"
                fi
            fi
        else
            echo -e "  Remote  : ${YELLOW}fetch failed — check network${NC}"
        fi
    fi
    echo

    # ── 3. arduino-cli ────────────────────────────────────────────────────────
    echo "arduino-cli"
    if ! command -v arduino-cli >/dev/null 2>&1; then
        echo -e "  ${RED}Not installed — run: mini-bowling.sh install cli${NC}"
        (( ++_updates )) || true
    else
        local cu_cli_ver
        cu_cli_ver=$(arduino-cli version 2>/dev/null | awk '{print $3}' || echo "?")
        echo "  Installed : v${cu_cli_ver}"

        if arduino_core_installed; then
            echo -e "  Core      : ${GREEN}✓ ${ARDUINO_CORE}${NC}"
        else
            echo -e "  Core      : ${RED}✗ ${ARDUINO_CORE} missing${NC}"
            (( ++_updates )) || true
        fi

        local cu_lib_list cu_missing=()
        cu_lib_list=$(arduino-cli lib list 2>/dev/null)
        local cu_lib
        for cu_lib in "${ARDUINO_LIBS[@]}"; do
            echo "$cu_lib_list" | grep -qF "$cu_lib" || cu_missing+=("$cu_lib")
        done
        if (( ${#cu_missing[@]} == 0 )); then
            echo -e "  Libraries : ${GREEN}✓ all ${#ARDUINO_LIBS[@]} required installed${NC}"
        else
            echo -e "  Libraries : ${YELLOW}missing: ${cu_missing[*]}${NC}"
            (( ++_updates )) || true
        fi

        if ! $check_only; then
            echo "  → Updating arduino-cli index and upgrading components..."
            arduino-cli update 2>/dev/null || echo -e "  ${YELLOW}Warning: arduino-cli update failed${NC}"
            arduino-cli upgrade 2>/dev/null || echo -e "  ${YELLOW}Warning: arduino-cli upgrade failed${NC}"
            arduino_core_installed || install_arduino_core
            (( ${#cu_missing[@]} > 0 )) && install_arduino_libs || true
            echo -e "  ${GREEN}✓ arduino-cli components up to date${NC}"
        fi
    fi
    echo

    # ── 4. ScoreMore ──────────────────────────────────────────────────────────
    echo "ScoreMore"
    local cu_sm_installed
    cu_sm_installed=$(get_installed_scoremore_version 2>/dev/null || echo "")
    if [[ -z "$cu_sm_installed" ]]; then
        echo -e "  ${YELLOW}Not installed — run: mini-bowling.sh install setup${NC}"
    else
        echo "  Current : v${cu_sm_installed}"
        local cu_sm_latest=""
        cu_sm_latest=$(_fetch_latest_scoremore_version)
        if [[ -z "$cu_sm_latest" ]]; then
            echo -e "  Remote  : ${YELLOW}unavailable${NC}"
        elif [[ "$cu_sm_latest" == "$cu_sm_installed" ]]; then
            echo -e "  Remote  : ${GREEN}✓ up to date (v${cu_sm_latest})${NC}"
        else
            echo -e "  Remote  : ${YELLOW}v${cu_sm_latest} available${NC}"
            (( ++_updates )) || true
            $check_only || scoremore_update || echo -e "  ${YELLOW}Warning: ScoreMore update failed${NC}"
        fi
    fi
    echo

    # ── 5. OS packages ────────────────────────────────────────────────────────
    echo "OS packages"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "  (apt-get not available — skipping)"
    else
        echo -n "  → Checking (apt-get update)... "
        if sudo apt-get update -q 2>/dev/null; then
            echo "done"
            local cu_pkg_count
            cu_pkg_count=$(apt-get --dry-run upgrade 2>/dev/null | grep -c '^Inst ' || true)
            if [[ "$cu_pkg_count" -eq 0 ]]; then
                echo -e "  Packages : ${GREEN}✓ up to date${NC}"
            else
                echo -e "  Packages : ${YELLOW}${cu_pkg_count} package(s) available${NC}"
                (( ++_updates )) || true
                if ! $check_only; then
                    sudo apt-get upgrade -y 2>/dev/null \
                        && echo -e "  ${GREEN}✓ OS packages upgraded${NC}" \
                        || echo -e "  ${YELLOW}Warning: apt-get upgrade had errors${NC}"
                    [[ -f /var/run/reboot-required ]] && \
                        echo -e "  ${YELLOW}→ Reboot required — run: pi reboot${NC}" || true
                fi
            fi
        else
            echo -e "${YELLOW}failed${NC}"
            echo -e "  ${YELLOW}apt-get update failed — check network${NC}"
        fi
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo
    echo "────────────────────────────────────────────"
    if (( _updates == 0 )); then
        echo -e "${GREEN}✓ All components up to date${NC}"
    elif $check_only; then
        echo -e "${YELLOW}${_updates} component(s) have updates available${NC}"
        echo "  Run: mini-bowling.sh component-upgrade  to install all updates"
    else
        echo -e "${GREEN}✓ Component upgrade complete${NC}"
    fi
}

# Item 5: list available ScoreMore versions and manage old ones
scoremore_history() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true

    case "$subcmd" in
        list)
            if [[ ! -d "$SCOREMORE_DIR" ]]; then
                echo "ScoreMore directory not found: $SCOREMORE_DIR"
                return 0
            fi

            local files
            mapfile -t files < <(find "$SCOREMORE_DIR" -maxdepth 1 \
                -name "ScoreMore-*.AppImage" 2>/dev/null | sort -V -r)

            if [[ ${#files[@]} -eq 0 ]]; then
                echo "No ScoreMore AppImages found in $SCOREMORE_DIR"
                return 0
            fi

            local active
            active=$(readlink -f "$SYMLINK_PATH" 2>/dev/null || true)

            echo "ScoreMore AppImages (newest first):"
            for f in "${files[@]}"; do
                local size date_str active_marker
                size=$(du -h "$f" | cut -f1)
                date_str=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c '%y' "$f" 2>/dev/null | cut -c1-16)
                active_marker=""
                if [[ "$f" == "$active" ]]; then
                    active_marker=" ${GREEN}← active${NC}"
                fi
                printf "  %-50s %6s  %s" "$(basename "$f")" "$size" "$date_str"
                echo -e "$active_marker"
            done
            echo
            echo "Run 'mini-bowling.sh scoremore history use <version>' to switch versions."
            echo "Run 'mini-bowling.sh scoremore history clean' to remove all but the active version."
            ;;

        use)
            local ver="${1?Missing version — e.g. mini-bowling.sh scoremore history use 1.8.0}"
            local filename="${APP_NAME}-${ver}-${ARCH}.${EXTENSION}"
            local target="$SCOREMORE_DIR/$filename"

            [[ -f "$target" ]] || die "Version not found: $target"

            kill_scoremore_gracefully
            sleep 2
            create_or_update_symlink "$target"
            start_scoremore
            ;;

        clean)
            local active
            active=$(readlink -f "$SYMLINK_PATH" 2>/dev/null || true)
            [[ -z "$active" ]] && die "No active symlink found — cannot determine which version to keep"

            local removed=0
            while IFS= read -r -d '' f; do
                if [[ "$f" != "$active" ]]; then
                    rm -f -- "$f"
                    echo "→ Removed: $(basename "$f")"
                    removed=$((removed + 1))
                fi
            done < <(find "$SCOREMORE_DIR" -maxdepth 1 -name "ScoreMore-*.AppImage" -print0 2>/dev/null)

            if [[ $removed -eq 0 ]]; then
                echo "Nothing to remove — only the active version is present."
            else
                echo -e "${GREEN}✓ Removed $removed old version(s)${NC}"
            fi
            ;;

        *)
            die "Unknown subcommand: '$subcmd' — use list, use <version>, or clean"
            ;;
    esac
}

# Item 5: rollback ScoreMore to a previously downloaded version
rollback_scoremore() {
    if [[ ! -d "$SCOREMORE_DIR" ]]; then
        die "ScoreMore directory not found: $SCOREMORE_DIR"
    fi

    local active
    active=$(readlink -f "$SYMLINK_PATH" 2>/dev/null || true)

    # List versions sorted newest-first, excluding the active one
    local files
    mapfile -t files < <(find "$SCOREMORE_DIR" -maxdepth 1 \
        -name "ScoreMore-*.AppImage" 2>/dev/null | sort -V -r)

    local previous=""
    for f in "${files[@]}"; do
        if [[ "$f" != "$active" ]]; then
            previous="$f"
            break
        fi
    done

    if [[ -z "$previous" ]]; then
        local total=${#files[@]}
        if [[ $total -eq 0 ]]; then
            die "No ScoreMore AppImages found in $SCOREMORE_DIR — run: mini-bowling.sh scoremore download latest"
        elif [[ $total -eq 1 ]]; then
            die "Only one ScoreMore version is installed ($(basename "${files[0]}")) — nothing to roll back to.
  Download an older version first: mini-bowling.sh scoremore download <version>
  Or list available versions: mini-bowling.sh scoremore history list"
        else
            die "Could not determine previous version — run: mini-bowling.sh scoremore history list"
        fi
    fi

    echo "Current  : $(basename "$active")"
    echo "Roll back to: $(basename "$previous")"
    echo
    kill_scoremore_gracefully
    sleep 2
    create_or_update_symlink "$previous"
    start_scoremore
    echo -e "${GREEN}✓ Rolled back to $(basename "$previous")${NC}"
}

# Item 6: capture Arduino serial output to a log file in the background
serial_log() {
    local subcmd="${1:-start}"
    shift 2>/dev/null || true

    local serial_log_file="$LOG_DIR/arduino-serial-$(date '+%Y-%m-%d').log"
    local pid_file="/tmp/mini-bowling-serial.pid"

    case "$subcmd" in
        start)
            require_arduino_cli

            if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
                echo "Serial logging already running (pid $(cat "$pid_file"))"
                echo "Log file: $serial_log_file"
                return 0
            fi

            local port
            port=$(find_arduino_port) || die "No Arduino port found"

            echo "Starting serial logging on $port..."
            echo "Log file: $serial_log_file"

            mkdir -p "$LOG_DIR"
            stty -F "$port" "$BAUD_RATE" cs8 -cstopb -parenb raw -echo 2>/dev/null || \
                stty -f "$port" "$BAUD_RATE" cs8 -cstopb -parenb raw -echo 2>/dev/null || true

            # Wrapper that auto-rotates the log at 10MB to prevent filling the SD card
            {
                while true; do
                    # Rotate if current log exceeds 10MB
                    if [[ -f "$serial_log_file" ]]; then
                        local size_bytes
                        size_bytes=$(stat -c%s "$serial_log_file" 2>/dev/null || stat -f%z "$serial_log_file" 2>/dev/null || echo 0)
                        if (( size_bytes > 10485760 )); then
                            local rotated="$serial_log_file.$(date '+%H%M%S').old"
                            mv "$serial_log_file" "$rotated"
                            echo "$(date '+%Y-%m-%d %H:%M:%S')  [log rotated — previous: $(basename "$rotated")]" >> "$serial_log_file"
                        fi
                    fi
                    # Read one line from port; if port disappears, pause and retry
                    if ! IFS= read -r line < "$port" 2>/dev/null; then
                        sleep 2
                        continue
                    fi
                    echo "$line" >> "$serial_log_file"
                done
            } &
            local bg_pid=$!
            disown
            echo $bg_pid > "$pid_file"

            sleep 1
            if kill -0 "$bg_pid" 2>/dev/null; then
                echo -e "${GREEN}✓ Serial logging started (pid $bg_pid)${NC}"
            else
                rm -f "$pid_file"
                die "Serial monitor failed to start — is the Arduino connected?"
            fi
            ;;

        stop)
            local stopped=false

            # Kill by PID file first
            if [[ -f "$pid_file" ]]; then
                local pid
                pid=$(cat "$pid_file")
                if kill "$pid" 2>/dev/null; then
                    stopped=true
                fi
                rm -f "$pid_file"
            fi

            # Also sweep for any stray serial logging processes not tracked by PID file
            # (can happen after reboot if PID file was in /tmp and got wiped)
            # Exclude current PID so the stop command doesn't kill itself.
            local stray_pids
            stray_pids=$(pgrep -f "mini-bowling.*serial\|arduino-serial" 2>/dev/null | grep -v "^$$\$" || true)
            if [[ -n "$stray_pids" ]]; then
                echo "$stray_pids" | xargs kill 2>/dev/null || true
                stopped=true
            fi

            if $stopped; then
                echo -e "${GREEN}✓ Serial logging stopped${NC}"
            else
                echo "Serial logging is not running."
            fi
            ;;

        status)
            if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
                echo -e "Serial logging : ${GREEN}running${NC} (pid $(cat "$pid_file"))"
                echo "Log file       : $serial_log_file"
            else
                echo "Serial logging : not running"
                rm -f "$pid_file" 2>/dev/null || true
            fi
            ;;

        tail)
            [[ -f "$serial_log_file" ]] || die "No serial log for today: $serial_log_file"
            tail -f "$serial_log_file"
            ;;

        *)
            die "Unknown subcommand: '$subcmd' — use start, stop, status, or tail"
            ;;
    esac
}

# Item 2 / 7: check if ScoreMore is running and restart if not
watchdog() {
    # Don't restart ScoreMore if a deploy is actively running - the deploy
    # intentionally kills ScoreMore before uploading and restarts it afterward
    local deploy_lock="/tmp/mini-bowling-deploy.lock"
    if [[ -f "$deploy_lock" ]]; then
        local lock_pid
        lock_pid=$(cat "$deploy_lock" 2>/dev/null || true)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "Deploy in progress (pid $lock_pid) — skipping watchdog restart"
            return 0
        else
            rm -f "$deploy_lock"  # stale lock
        fi
    fi

    local sm_pid
    sm_pid=$(_scoremore_pid)

    if [[ -n "$sm_pid" ]]; then
        echo -e "${GREEN}✓ ScoreMore is running (pid $sm_pid)${NC}"
    else
        echo -e "${YELLOW}ScoreMore is not running — restarting...${NC}"
        start_scoremore
        sleep 3

        sm_pid=$(_scoremore_pid)
        if [[ -n "$sm_pid" ]]; then
            echo -e "${GREEN}✓ ScoreMore restarted (pid $sm_pid)${NC}"
        else
            die "ScoreMore failed to start"
        fi
    fi

    # Item 1: restart serial logging if it was supposed to be running but died
    local pid_file="/tmp/mini-bowling-serial.pid"
    if [[ -f "$pid_file" ]]; then
        local serial_pid
        serial_pid=$(cat "$pid_file")
        if ! kill -0 "$serial_pid" 2>/dev/null; then
            echo -e "${YELLOW}Serial logging was running but has stopped — restarting...${NC}"
            rm -f "$pid_file"
            serial_log start || echo -e "${YELLOW}Warning: could not restart serial logging${NC}"
        fi
    fi
}

# Item 7: add/remove cron job for automatic watchdog
setup_watchdog() {
    local subcmd="${1:-enable}"
    local cron_marker="# mini-bowling watchdog"
    local script_path; script_path=$(_cron_script_path)

    case "$subcmd" in
        enable)
            local cron_job="*/5 * * * * \"$script_path\" scoremore watchdog run $cron_marker"
            _cron_manage enable "$cron_marker" "Watchdog" "$cron_job"
            echo -e "${GREEN}✓ Watchdog enabled:${NC} checks ScoreMore every 5 minutes"
            ;;
        disable) _cron_manage disable "$cron_marker" "Watchdog" ;;
        status)  _cron_manage status  "$cron_marker" "Watchdog" ;;
        *)       die "Unknown subcommand: '$subcmd' — use enable, disable, or status" ;;
    esac
}

# Item 10: clean up old ScoreMore AppImages and Arduino build cache
disk_cleanup() {
    echo "=== Disk Cleanup ==="
    echo

    local freed=0

    # Remove all but the active ScoreMore AppImage
    if [[ -d "$SCOREMORE_DIR" ]]; then
        local active
        active=$(readlink -f "$SYMLINK_PATH" 2>/dev/null || true)
        local sm_removed=0

        while IFS= read -r -d '' f; do
            if [[ "$f" != "$active" ]]; then
                local size_kb
                size_kb=$(du -k "$f" | cut -f1)
                rm -f -- "$f"
                echo "→ Removed old AppImage: $(basename "$f") ($(( size_kb / 1024 ))MB)"
                freed=$(( freed + size_kb ))
                sm_removed=$(( sm_removed + 1 ))
            fi
        done < <(find "$SCOREMORE_DIR" -maxdepth 1 -name "ScoreMore-*.AppImage" -print0 2>/dev/null)

        if [[ $sm_removed -eq 0 ]]; then
            echo "  ScoreMore: nothing to remove (only active version present)"
        fi
    fi

    # Remove Arduino build cache
    local build_dirs=("$PROJECT_DIR/build" "$HOME/.cache/arduino" "$HOME/.arduino15/cache")
    local build_removed=0
    for dir in "${build_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local size_kb
            size_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
            rm -rf -- "$dir"
            echo "→ Removed build cache: $dir ($(( size_kb / 1024 ))MB)"
            freed=$(( freed + size_kb ))
            build_removed=$(( build_removed + 1 ))
        fi
    done
    if [[ $build_removed -gt 0 ]]; then
        echo -e "  ${YELLOW}Note: next arduino-cli compile will be slower — build cache will be rebuilt automatically.${NC}"
    fi

    # Remove old log files beyond 30 days (in case prune_logs missed any)
    local log_removed=0
    while IFS= read -r -d '' f; do
        local size_kb
        size_kb=$(du -k "$f" | cut -f1)
        rm -f -- "$f"
        freed=$(( freed + size_kb ))
        log_removed=$(( log_removed + 1 ))
    done < <(find "$LOG_DIR" -maxdepth 1 -name "mini-bowling-*.log" -mtime +30 -print0 2>/dev/null)
    [[ $log_removed -gt 0 ]] && echo "→ Removed $log_removed old log file(s)" || true

    # Report backup directory size - backups are not auto-removed here,
    # only the 10-backup limit enforced by `backup` applies
    local backup_dir="$HOME/Documents/Bowling/backups"
    if [[ -d "$backup_dir" ]]; then
        local backup_count backup_size_kb
        backup_count=$(find "$backup_dir" -maxdepth 1 -name "mini-bowling-backup-*.tar.gz" 2>/dev/null | wc -l)
        backup_size_kb=$(du -sk "$backup_dir" 2>/dev/null | cut -f1)
        echo "  Backups: $backup_count file(s), $(( backup_size_kb / 1024 ))MB total"
        echo "  (run 'mini-bowling.sh backup' to apply the 10-backup retention limit)"
    fi

    echo
    if [[ $freed -gt 0 ]]; then
        echo -e "${GREEN}✓ Freed approximately $(( freed / 1024 ))MB${NC}"
    else
        echo -e "${GREEN}✓ Nothing to clean up${NC}"
    fi

    echo
    echo "Current disk usage:"
    df -h / "$HOME" 2>/dev/null | awk 'NR==1 || NR>1 {printf "  %s\n", $0}'
}

# ------------------------------------------------
#  Raspberry Pi Management
# ------------------------------------------------

pi_status() {
    echo "=== Raspberry Pi Status ==="
    echo

    # Uptime
    echo "Uptime      : $(uptime -p 2>/dev/null || uptime)"

    # CPU temperature
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local raw_temp
        raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp)
        local temp_c=$(( raw_temp / 1000 ))
        local temp_f=$(( temp_c * 9 / 5 + 32 ))
        if (( temp_c >= 80 )); then
            echo -e "CPU Temp    : ${RED}${temp_c}°C / ${temp_f}°F (CRITICAL — throttling likely)${NC}"
        elif (( temp_c >= 70 )); then
            echo -e "CPU Temp    : ${YELLOW}${temp_c}°C / ${temp_f}°F (warm)${NC}"
        else
            echo -e "CPU Temp    : ${GREEN}${temp_c}°C / ${temp_f}°F${NC}"
        fi
    else
        echo "CPU Temp    : unavailable"
    fi

    # Memory
    local mem_total mem_used mem_free mem_pct
    mem_total=$(awk '/MemTotal/  {print $2}' /proc/meminfo)
    mem_free=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    mem_used=$(( mem_total - mem_free ))
    mem_pct=$(( mem_used * 100 / mem_total ))
    printf "Memory      : %s MB used / %s MB total (%s%%)\n" \
        "$(( mem_used / 1024 ))" "$(( mem_total / 1024 ))" "$mem_pct"

    # Disk space
    echo
    echo "Disk Usage:"
    df -h / "$HOME" 2>/dev/null | awk 'NR==1 || NR>1 {printf "  %-20s %s\n", $6, $0}' | \
        grep -v "^  Mounted" || df -h /

    # Architecture and OS
    echo
    local arch_dpkg arch_kernel os_name os_version
    arch_dpkg=$(dpkg --print-architecture 2>/dev/null || echo "unavailable")
    arch_kernel=$(uname -m 2>/dev/null || echo "unavailable")
    os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}" || echo "unavailable")
    echo "Architecture: $arch_dpkg  (kernel: $arch_kernel)"
    echo "OS          : $os_name"
}

pi_sysinfo() {
    echo "=== System Info ==="
    echo
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl 2>/dev/null || echo "hostnamectl failed"
    else
        echo "hostnamectl not available — showing fallback info:"
        echo
        echo "  Hostname    : $(hostname 2>/dev/null || echo 'unknown')"
        echo "  Kernel      : $(uname -r 2>/dev/null || echo 'unknown')"
        echo "  Architecture: $(uname -m 2>/dev/null || echo 'unknown')"
        local os_name
        os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}" || echo "unknown")
        echo "  OS          : $os_name"
    fi
}

_read_temp() {
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local raw; raw=$(cat /sys/class/thermal/thermal_zone0/temp)
        local c=$(( raw / 1000 )) f=$(( raw / 1000 * 9 / 5 + 32 ))
        local label color
        if (( c >= 80 )); then
            label="CRITICAL — throttling likely"; color="$RED"
        elif (( c >= 70 )); then
            label="warm"; color="$YELLOW"
        elif (( c >= 60 )); then
            label="ok"; color="$YELLOW"
        else
            label="ok"; color="$GREEN"
        fi
        echo -e "${color}${c}°C / ${f}°F${NC}  ($label)"
    else
        echo "unavailable"
    fi
}

pi_temp() {
    local watch=false interval=5
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --watch|-w) watch=true; shift ;;
            --interval=*) interval="${1#--interval=}"; shift ;;
            [0-9]*) interval="$1"; shift ;;
            *) die "Unknown argument: '$1' — usage: pi temp [--watch [interval]]" ;;
        esac
    done

    if $watch; then
        echo "CPU temperature  (Ctrl+C to exit)"
        echo "─────────────────────────────────"
        while true; do
            printf "\r%-60s" "$(date '+%H:%M:%S')  $(_read_temp)"
            sleep "$interval"
        done
        echo
    else
        echo -n "CPU Temp : "; _read_temp
    fi
}

pi_disk() {
    echo "=== Disk Usage ==="
    echo

    # Overall filesystem
    echo "Filesystem:"
    df -h / 2>/dev/null | awk 'NR>1 {printf "  /            %s used of %s  (%s)\n", $3, $2, $5}'
    echo

    # Key directories
    echo "Key directories:"
    local dirs=(
        "$PROJECT_DIR:Arduino project"
        "$SCOREMORE_DIR:ScoreMore"
        "$LOG_DIR:Logs"
        "${PROJECT_DIR}/build:Build cache"
        "${PROJECT_DIR}/cache:Compiler cache"
        "$HOME/.local/share/mini-bowling-script:Script repo"
    )
    for entry in "${dirs[@]}"; do
        local path="${entry%%:*}" label="${entry#*:}"
        if [[ -d "$path" ]]; then
            local size; size=$(du -sh "$path" 2>/dev/null | cut -f1)
            printf "  %-28s %s\n" "$label" "$size"
        else
            printf "  %-28s %s\n" "$label" "(not found)"
        fi
    done

    echo
    # ScoreMore AppImage count
    local appimage_count appimage_size
    appimage_count=$(find "$SCOREMORE_DIR" -maxdepth 1 -name '*.AppImage' 2>/dev/null | wc -l)
    appimage_size=$(du -sh "$SCOREMORE_DIR" 2>/dev/null | cut -f1 || echo "?")
    echo "ScoreMore AppImages : $appimage_count file(s)  ($appimage_size total)"
    if (( appimage_count > 2 )); then
        echo -e "  ${YELLOW}Tip:${NC} run 'scoremore history clean' to remove old versions"
    fi
}

system_monitor() {
    local interval="${1:-}"
    local watch=false
    if [[ "$interval" == "--watch" ]]; then
        watch=true
        interval="${2:-5}"
    fi
    [[ -z "$interval" ]] && interval=5

    _monitor_snapshot() {
        local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "${BOLD}=== System Monitor  $ts ===${NC}"
        echo

        # --- CPU load ---
        local load1 load5 load15 procs
        IFS=' ' read -r load1 load5 load15 procs _ < /proc/loadavg 2>/dev/null \
            || load1="-" load5="-" load15="-" procs="-"
        local ncpu; ncpu=$(nproc 2>/dev/null || echo 1)
        local color_load="$GREEN"
        # Use integer arithmetic (×100) to avoid bc dependency for float comparison
        local load1_int; load1_int=$(echo "$load1" | awk '{printf "%d", $1 * 100}')
        (( load1_int >= ncpu * 75  )) && color_load="$YELLOW"
        (( load1_int >= ncpu * 100 )) && color_load="$RED"
        echo -e "CPU Load   : ${color_load}${load1} ${load5} ${load15}${NC}  (${ncpu} cores, 1m / 5m / 15m averages)"

        # Per-core usage — two /proc/stat snapshots 0.5s apart
        local -a cores1=() cpu_pct=()
        local line lbl u n s i wa hi si st
        while IFS= read -r line; do
            [[ "$line" =~ ^cpu[0-9] ]] || continue
            IFS=' ' read -r lbl u n s i wa hi si st _ <<< "$line"
            cores1+=("$lbl $((u+n+s+wa+hi+si+st)) $i")
        done < /proc/stat
        sleep 0.5
        local idx=0
        while IFS= read -r line; do
            [[ "$line" =~ ^cpu[0-9] ]] || continue
            IFS=' ' read -r lbl u n s i wa hi si st _ <<< "$line"
            local total2=$((u+n+s+wa+hi+si+st)) idle2=$i
            local prev="${cores1[$idx]:-}"
            local prev_total; prev_total=$(echo "$prev" | awk '{print $2}')
            local prev_idle;  prev_idle=$(echo "$prev"  | awk '{print $3}')
            local dtotal=$(( total2 - prev_total ))
            local didle=$(( idle2 - prev_idle ))
            local pct=0
            (( dtotal > 0 )) && pct=$(( (dtotal - didle) * 100 / dtotal ))
            cpu_pct+=("$pct")
            (( ++idx ))
        done < /proc/stat

        local ci=0
        for pct in "${cpu_pct[@]}"; do
            local bar="" col="$GREEN"
            (( pct >= 50 )) && col="$YELLOW"
            (( pct >= 85 )) && col="$RED"
            local bars=$(( pct / 5 ))
            for (( b=0; b<20; b++ )); do
                if (( b < bars )); then bar+="#"; else bar+="-"; fi
            done
            printf "  core%-2d   [${col}%-20s${NC}] %3d%%\n" "$ci" "$bar" "$pct"
            (( ++ci ))
        done

        # --- Temperature ---
        echo
        if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
            local raw_temp temp_c
            raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp)
            temp_c=$(( raw_temp / 1000 ))
            local col_temp="$GREEN"
            (( temp_c >= 70 )) && col_temp="$YELLOW"
            (( temp_c >= 80 )) && col_temp="$RED"
            echo -e "CPU Temp   : ${col_temp}${temp_c}°C${NC}"
        elif command -v vcgencmd >/dev/null 2>&1; then
            local vctemp; vctemp=$(vcgencmd measure_temp 2>/dev/null | sed "s/temp=//")
            echo "CPU Temp   : $vctemp"
        fi

        # --- Memory ---
        echo
        local mem_total mem_avail mem_used mem_pct
        mem_total=$(awk '/MemTotal/    {print $2}' /proc/meminfo)
        mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
        mem_used=$(( mem_total - mem_avail ))
        mem_pct=$(( mem_used * 100 / mem_total ))
        local col_mem="$GREEN"
        (( mem_pct >= 75 )) && col_mem="$YELLOW"
        (( mem_pct >= 90 )) && col_mem="$RED"
        printf "Memory     : ${col_mem}%dMB used / %dMB total  (%d%%)${NC}\n" \
            "$(( mem_used / 1024 ))" "$(( mem_total / 1024 ))" "$mem_pct"

        # Memory breakdown (cached/buffers)
        local mem_buff mem_cache
        mem_buff=$(awk  '/Buffers/   {print $2}' /proc/meminfo || echo 0)
        mem_cache=$(awk '/^Cached:/  {print $2}' /proc/meminfo || echo 0)
        printf "             %dMB free  |  %dMB buffers  |  %dMB cached\n" \
            "$(( mem_avail / 1024 ))" "$(( mem_buff / 1024 ))" "$(( mem_cache / 1024 ))"

        # --- Disk ---
        echo
        local disk_used disk_avail disk_pct
        disk_pct=$(df -k / 2>/dev/null | awk 'NR==2 {print $5}')
        disk_avail=$(df -k / 2>/dev/null | awk 'NR==2 {printf "%dMB", $4/1024}')
        local col_disk="$GREEN"
        local disk_pct_num="${disk_pct//%/}"
        (( disk_pct_num >= 75 )) && col_disk="$YELLOW"
        (( disk_pct_num >= 90 )) && col_disk="$RED"
        echo -e "Disk (/)   : ${col_disk}${disk_pct} used${NC}  |  ${disk_avail} free"

        # --- ScoreMore process ---
        echo
        local sm_pid; sm_pid=$(_scoremore_pid)
        if [[ -n "$sm_pid" ]]; then
            local sm_cpu sm_mem sm_vsz
            IFS=' ' read -r sm_cpu sm_mem sm_vsz _ < <(
                ps -p "$sm_pid" -o pcpu=,pmem=,vsz= 2>/dev/null || echo "- - -"
            )
            local sm_vsz_mb=$(( ${sm_vsz:-0} / 1024 ))
            echo -e "ScoreMore  : ${GREEN}running${NC}  PID ${sm_pid}  |  CPU ${sm_cpu:-?}%  |  MEM ${sm_mem:-?}%  (${sm_vsz_mb}MB virtual)"
        else
            echo -e "ScoreMore  : ${RED}not running${NC}"
        fi

        # --- Top processes ---
        echo
        echo "Top processes by CPU:"
        ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -8 | \
            awk 'NR==1 {printf "  %-8s %6s  %5s  %s\n", $1, $2, $3, $4; next}
                       {printf "  %-8s %5s%%  %4s%%  %s\n", $1, $2, $3, $4}'

        echo
        echo "Top processes by memory:"
        ps -eo pid,pcpu,pmem,comm --sort=-pmem 2>/dev/null | head -6 | \
            awk 'NR==1 {printf "  %-8s %6s  %5s  %s\n", $1, $2, $3, $4; next}
                       {printf "  %-8s %5s%%  %4s%%  %s\n", $1, $2, $3, $4}'

        echo
        printf "Processes  : %s running\n" "$procs"
    }

    if $watch; then
        echo "System monitor — refreshing every ${interval}s  (Ctrl+C to stop)"
        sleep 1
        while true; do
            tput cup 0 0 2>/dev/null || printf '\033[H'
            _monitor_snapshot
            sleep "$interval"
        done
    else
        _monitor_snapshot
    fi
}

_read_cpu() {
    # Load averages
    local load1 load5 load15 procs
    IFS=' ' read -r load1 load5 load15 procs _ < /proc/loadavg 2>/dev/null || load1="-" load5="-" load15="-" procs="-"
    local ncpu
    ncpu=$(nproc 2>/dev/null || echo 1)

    # Per-core usage (sample two /proc/stat snapshots)
    local -a cpu_pct=()
    local line cores1=() cores2=() labels=()
    # First snapshot
    while IFS= read -r line; do
        [[ "$line" =~ ^cpu[0-9] ]] || continue
        local lbl u n s i wa hi si st
        IFS=' ' read -r lbl u n s i wa hi si st _ <<< "$line"
        cores1+=("$lbl $((u+n+s+wa+hi+si+st)) $i")
        labels+=("$lbl")
    done < /proc/stat
    sleep 0.5
    # Second snapshot
    local idx=0
    while IFS= read -r line; do
        [[ "$line" =~ ^cpu[0-9] ]] || continue
        local lbl u n s i wa hi si st
        IFS=' ' read -r lbl u n s i wa hi si st _ <<< "$line"
        local total2=$((u+n+s+wa+hi+si+st))
        local idle2=$i
        local prev="${cores1[$idx]:-}"
        local prev_total; prev_total=$(echo "$prev" | awk '{print $2}')
        local prev_idle;  prev_idle=$(echo "$prev"  | awk '{print $3}')
        local dtotal=$(( total2 - prev_total ))
        local didle=$(( idle2 - prev_idle ))
        local pct=0
        (( dtotal > 0 )) && pct=$(( (dtotal - didle) * 100 / dtotal ))
        cpu_pct+=("$pct")
        (( ++idx ))
    done < /proc/stat

    # Color by load vs ncpu (weakest threshold first so stronger wins)
    local color_load="$GREEN"
    local load1_int; load1_int=$(echo "$load1" | awk '{printf "%d", $1 * 100}')
    (( load1_int >= ncpu * 75  )) && color_load="$YELLOW"
    (( load1_int >= ncpu * 100 )) && color_load="$RED"

    echo -e "Load avg : ${color_load}${load1} ${load5} ${load15}${NC}  (${ncpu} core(s))"
    echo "Processes: $procs"
    echo

    local i=0
    for pct in "${cpu_pct[@]}"; do
        local bar="" col="$GREEN"
        (( pct >= 50 )) && col="$YELLOW"
        (( pct >= 85 )) && col="$RED"
        local bars=$(( pct / 5 ))
        for (( b=0; b<20; b++ )); do
            if (( b < bars )); then bar+="#"; else bar+="-"; fi
        done
        printf "  core%-2d  [${col}%-20s${NC}] %3d%%\n" "$i" "$bar" "$pct"
        (( ++i ))
    done

    # Top processes by CPU
    echo
    echo "Top processes:"
    ps -eo pid,pcpu,comm --sort=-pcpu 2>/dev/null | head -6 | \
        awk 'NR==1{printf "  %-8s %6s  %s\n",$1,$2,$3; next} {printf "  %-8s %5s%%  %s\n",$1,$2,$3}'
}

pi_cpu() {
    local interval="${1:-}"
    local watch=false
    [[ "$interval" == "--watch" ]] && watch=true && interval="${2:-3}"
    [[ -z "$interval" ]] && interval=3

    if $watch; then
        echo "CPU monitor — refreshing every ${interval}s  (Ctrl+C to stop)"
        echo
        while true; do
            tput cup 0 0 2>/dev/null || printf '\033[H'
            echo "=== CPU Monitor — $(date '+%H:%M:%S') ==="; echo
            _read_cpu
            sleep "$interval"
        done
    else
        echo "=== CPU Usage ==="
        echo
        _read_cpu
    fi
}

pi_update() {
    echo -e "${YELLOW}Updating Raspberry Pi OS packages...${NC}"
    sudo apt-get update || die "apt update failed"
    sudo apt-get upgrade -y || die "apt upgrade failed"
    echo -e "${GREEN}✓ System packages up to date${NC}"

    if [[ -f /var/run/reboot-required ]]; then
        echo -e "${YELLOW}→ A reboot is required to apply updates.${NC}"
        echo "  Run: mini-bowling.sh pi reboot"
    fi
}

pi_reboot() {
    sudo -n true 2>/dev/null || sudo true || die "sudo access required for reboot — run: sudo mini-bowling.sh pi reboot"
    echo -e "${YELLOW}Rebooting Raspberry Pi in 5 seconds... (Ctrl+C to cancel)${NC}"
    sleep 5
    sudo reboot
}

pi_shutdown() {
    sudo -n true 2>/dev/null || sudo true || die "sudo access required for shutdown — run: sudo mini-bowling.sh pi-shutdown"
    echo -e "${YELLOW}Shutting down Raspberry Pi in 5 seconds... (Ctrl+C to cancel)${NC}"
    sleep 5
    sudo shutdown -h now
}

wifi_status() {
    echo "=== Wi-Fi Status ==="
    echo

    # Interface detection
    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}') || iface=""

    if [[ -z "$iface" ]]; then
        echo -e "Network     : ${RED}No route to internet${NC}"
        return 0
    fi

    echo "Interface   : $iface"

    # IP address
    local ip
    ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    echo "IP Address  : ${ip:-unknown}"

    # SSID and signal (requires iwconfig or iw)
    if command -v iwconfig >/dev/null 2>&1; then
        local ssid signal
        ssid=$(iwconfig "$iface" 2>/dev/null | awk -F'"' '/ESSID/ {print $2}')
        signal=$(iwconfig "$iface" 2>/dev/null | sed -n 's/.*Signal level=\([^ ]*\).*/\1/p' | head -1)
        [[ -n "$ssid"   ]] && echo "SSID        : $ssid"
        [[ -n "$signal" ]] && echo "Signal      : $signal dBm"
    elif command -v iw >/dev/null 2>&1; then
        local ssid
        ssid=$(iw dev "$iface" link 2>/dev/null | awk '/SSID/ {print $2}')
        [[ -n "$ssid" ]] && echo "SSID        : $ssid"
    fi

    # Internet reachability
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo -e "Internet    : ${GREEN}reachable${NC}"
    else
        echo -e "Internet    : ${RED}unreachable${NC}"
    fi
}

vnc_status() {
    echo "=== VNC Status ==="
    echo

    # -- 1. Installation -------------------------------------------------------

    local vnc_bin=""
    local vnc_flavor=""

    if command -v vncserver >/dev/null 2>&1; then
        vnc_bin=$(command -v vncserver)
        # Distinguish RealVNC (ships on Pi OS) from TigerVNC / TightVNC
        if vncserver --help 2>&1 | grep -qi "realvnc\|vnc connect"; then
            vnc_flavor="RealVNC"
        elif vncserver --help 2>&1 | grep -qi "tigervnc"; then
            vnc_flavor="TigerVNC"
        elif vncserver --help 2>&1 | grep -qi "tightvnc"; then
            vnc_flavor="TightVNC"
        else
            vnc_flavor="VNC"
        fi
    elif command -v x11vnc >/dev/null 2>&1; then
        vnc_bin=$(command -v x11vnc)
        vnc_flavor="x11vnc"
    fi

    if [[ -z "$vnc_bin" ]]; then
        echo -e "Installed   : ${RED}No VNC server found${NC}"
        echo    "  Install RealVNC:  sudo apt-get install realvnc-vnc-server"
        echo    "  Install TigerVNC: sudo apt-get install tigervnc-standalone-server"
        return 0
    fi

    echo -e "Installed   : ${GREEN}${vnc_flavor}${NC}  ($vnc_bin)"

    # -- 2. Service / running state --------------------------------------------

    local service_running=false
    local service_name=""

    # Check common service names
    for svc in vncserver-x11-serviced vncserver-virtuald tigervnc x11vnc vncserver; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            service_running=true
            service_name="$svc"
            break
        fi
    done

    # Also check for a running vncserver / Xvnc process directly
    local proc_running=false
    if pgrep -x "vncserver\|Xvnc\|x11vnc\|vncserver-x11" >/dev/null 2>&1 || \
       pgrep -f "vncserver\|Xvnc\|x11vnc" >/dev/null 2>&1; then
        proc_running=true
    fi

    if $service_running; then
        echo -e "Service     : ${GREEN}running${NC}  (systemd: $service_name)"
    elif $proc_running; then
        local pid
        pid=$(pgrep -f "Xvnc\|vncserver\|x11vnc" | head -1)
        echo -e "Service     : ${YELLOW}running (process, no systemd service)${NC}  (pid $pid)"
    else
        echo -e "Service     : ${RED}not running${NC}"
        echo    "  Start:  sudo systemctl start vncserver-x11-serviced"
        echo    "   — or — vncserver :1"
    fi

    # -- 3. Active VNC displays / ports ----------------------------------------

    # Each Xvnc display :N listens on port 5900+N
    local displays
    displays=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:59[0-9][0-9]$/ {
        split($4, a, ":"); port=a[length(a)]
        display = port - 5900
        printf ":%d  (port %d)\n", display, port
    }' | sort -u)

    if [[ -n "$displays" ]]; then
        echo -e "Displays    : ${GREEN}${displays}${NC}" | head -1
        # Print extra displays indented if more than one
        echo "$displays" | tail -n +2 | while IFS= read -r d; do
            echo "              $d"
        done
    else
        echo -e "Displays    : ${YELLOW}none listening${NC}"
    fi

    # -- 4. Autostart ----------------------------------------------------------

    local autostart_status=""

    # systemd enable
    for svc in vncserver-x11-serviced vncserver-virtuald tigervnc x11vnc; do
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            autostart_status="enabled (systemd: $svc)"
            break
        fi
    done

    # raspi-config / wayvnc sets this file
    if [[ -z "$autostart_status" ]] && \
       grep -qr "vncserver\|wayvnc\|x11vnc" \
           /etc/xdg/autostart/ /etc/rc.local \
           "$HOME/.config/autostart/" 2>/dev/null; then
        autostart_status="enabled (autostart file)"
    fi

    if [[ -n "$autostart_status" ]]; then
        echo -e "Autostart   : ${GREEN}${autostart_status}${NC}"
    else
        echo -e "Autostart   : ${YELLOW}not configured${NC}"
        echo    "  Enable:  sudo systemctl enable vncserver-x11-serviced"
        echo    "   — or — sudo raspi-config  → Interface Options → VNC"
    fi

    # -- 5. VNC port reachability from localhost --------------------------------

    local port_ok=false
    for port in 5900 5901; do
        if ss -tlnp 2>/dev/null | grep -q ":${port}"; then
            port_ok=true
            break
        fi
    done

    if $port_ok; then
        # Show the IP a remote client would connect to
        local lan_ip
        lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        echo -e "Connect to  : ${GREEN}${lan_ip:-<Pi IP>}:5900${NC}  from your VNC viewer"
    else
        echo -e "Connect to  : ${RED}no VNC port listening${NC}"
    fi
}

# Detect the best available VNC service name for systemd operations
# Sets _vnc_service in the caller's scope
_vnc_detect_service() {
    _vnc_service=""
    for svc in vncserver-x11-serviced vncserver-virtuald tigervnc x11vnc vncserver; do
        if systemctl list-unit-files --quiet "$svc.service" 2>/dev/null | grep -q "$svc"; then
            _vnc_service="$svc"
            return 0
        fi
    done
    return 1
}

vnc_setup() {
    local subcmd="${1:-}"

    # No subcommand: show usage without requiring VNC to be installed
    if [[ -z "$subcmd" ]]; then
        echo "Usage: mini-bowling.sh pi vnc <subcommand>"
        echo
        echo "Subcommands:"
        echo "  start             Start VNC now"
        echo "  stop              Stop VNC"
        echo "  enable-autostart  Enable VNC to start automatically on boot"
        echo "  disable-autostart Disable VNC autostart"
        echo
        echo "Check current VNC state with: mini-bowling.sh pi vnc status"
        return 0
    fi

    # Unknown subcommand check (before VNC detection so error is always shown)
    case "$subcmd" in
        start|stop|enable-autostart|disable-autostart) ;;
        *) die "Unknown vnc-setup subcommand: '$subcmd' — use start, stop, enable-autostart, or disable-autostart" ;;
    esac

    # -- Detect installed VNC flavor -------------------------------------------

    local vnc_bin=""
    local vnc_flavor=""

    if command -v vncserver >/dev/null 2>&1; then
        vnc_bin=$(command -v vncserver)
        if vncserver --help 2>&1 | grep -qi "realvnc\|vnc connect"; then
            vnc_flavor="RealVNC"
        elif vncserver --help 2>&1 | grep -qi "tigervnc"; then
            vnc_flavor="TigerVNC"
        else
            vnc_flavor="VNC"
        fi
    elif command -v x11vnc >/dev/null 2>&1; then
        vnc_bin=$(command -v x11vnc)
        vnc_flavor="x11vnc"
    fi

    if [[ -z "$vnc_bin" ]]; then
        die "No VNC server found. Install one first:
  RealVNC:  sudo apt-get install realvnc-vnc-server
  TigerVNC: sudo apt-get install tigervnc-standalone-server"
    fi

    case "$subcmd" in

        start)
            # -- Start VNC now -------------------------------------------------
            echo -e "${YELLOW}Starting VNC ($vnc_flavor)...${NC}"

            # Check if already running
            if pgrep -f "Xvnc\|vncserver\|x11vnc" >/dev/null 2>&1; then
                echo -e "${GREEN}✓ VNC is already running${NC}"
                local lan_ip
                lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
                echo "  Connect: ${lan_ip:-<Pi IP>}:5900"
                return 0
            fi

            local _vnc_service
            _vnc_detect_service

            if [[ -n "$_vnc_service" ]]; then
                sudo systemctl start "$_vnc_service" || die "Failed to start $_vnc_service"
                sleep 1
                if systemctl is-active --quiet "$_vnc_service"; then
                    echo -e "${GREEN}✓ VNC started${NC}  (systemd: $_vnc_service)"
                else
                    die "Service started but does not appear active — check: sudo systemctl status $_vnc_service"
                fi
            else
                # Fall back to vncserver :1 directly
                echo -e "${YELLOW}No systemd service found — starting vncserver :1 directly${NC}"
                vncserver :1 || die "vncserver :1 failed — you may need to set a VNC password first: vncpasswd"
                echo -e "${GREEN}✓ VNC started on display :1${NC}"
            fi

            local lan_ip
            lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
            echo "  Connect: ${lan_ip:-<Pi IP>}:5900"
            ;;

        stop)
            # -- Stop VNC ------------------------------------------------------
            echo -e "${YELLOW}Stopping VNC ($vnc_flavor)...${NC}"

            local _vnc_service
            _vnc_detect_service

            local stopped=false

            if [[ -n "$_vnc_service" ]] && systemctl is-active --quiet "$_vnc_service" 2>/dev/null; then
                sudo systemctl stop "$_vnc_service" || die "Failed to stop $_vnc_service"
                echo -e "${GREEN}✓ VNC service stopped${NC}  (systemd: $_vnc_service)"
                stopped=true
            fi

            # Also kill any stray Xvnc / vncserver processes
            if pgrep -f "Xvnc\|vncserver :1\|x11vnc" >/dev/null 2>&1; then
                vncserver -kill :1 2>/dev/null || \
                    pkill -f "Xvnc\|vncserver\|x11vnc" 2>/dev/null || true
                echo -e "${GREEN}✓ VNC process stopped${NC}"
                stopped=true
            fi

            $stopped || echo -e "${YELLOW}VNC was not running${NC}"
            ;;

        enable-autostart)
            # -- Enable autostart on boot ---------------------------------------
            echo -e "${YELLOW}Enabling VNC autostart on boot ($vnc_flavor)...${NC}"

            local _vnc_service
            _vnc_detect_service

            if [[ -n "$_vnc_service" ]]; then
                sudo systemctl enable "$_vnc_service" || die "Failed to enable $_vnc_service"
                echo -e "${GREEN}✓ VNC autostart enabled${NC}  (systemd: $_vnc_service)"
                echo    "  VNC will start automatically on next boot."
                echo    "  To start now:  mini-bowling.sh pi vnc start"
            else
                # No systemd service - try raspi-config if available
                if command -v raspi-config >/dev/null 2>&1; then
                    echo "No systemd service found. Enabling via raspi-config..."
                    sudo raspi-config nonint do_vnc 0 || \
                        die "raspi-config VNC enable failed"
                    echo -e "${GREEN}✓ VNC autostart enabled via raspi-config${NC}"
                else
                    die "No systemd VNC service found and raspi-config not available.
Try installing RealVNC: sudo apt-get install realvnc-vnc-server
Then re-run: mini-bowling.sh vnc-setup enable-autostart"
                fi
            fi
            ;;

        disable-autostart)
            # -- Disable autostart ---------------------------------------------
            echo -e "${YELLOW}Disabling VNC autostart ($vnc_flavor)...${NC}"

            local _vnc_service
            _vnc_detect_service

            if [[ -n "$_vnc_service" ]] && systemctl is-enabled --quiet "$_vnc_service" 2>/dev/null; then
                sudo systemctl disable "$_vnc_service" || die "Failed to disable $_vnc_service"
                echo -e "${GREEN}✓ VNC autostart disabled${NC}  (systemd: $_vnc_service)"
            elif command -v raspi-config >/dev/null 2>&1; then
                sudo raspi-config nonint do_vnc 1 || die "raspi-config VNC disable failed"
                echo -e "${GREEN}✓ VNC autostart disabled via raspi-config${NC}"
            else
                echo -e "${YELLOW}VNC autostart was not enabled (or service not found)${NC}"
            fi
            ;;

    esac
}

install_cli() {
    if command -v arduino-cli >/dev/null 2>&1; then
        echo -e "${GREEN}arduino-cli is already installed:${NC} $(arduino-cli version 2>/dev/null | head -1)"
        install_arduino_core
        install_arduino_libs
        echo
        echo "→ Checking for arduino-cli component upgrades..."
        upgrade_arduino_components
        return 0
    fi

    echo -e "${YELLOW}arduino-cli not found. Installing...${NC}"

    local install_dir="${HOME}/.local/bin"
    mkdir -p "$install_dir"

    echo "→ Installing arduino-cli to: $install_dir"

    local install_exit=0
    curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh \
        | BINDIR="$install_dir" sh -s -- --no-interaction || install_exit=$?

    if (( install_exit != 0 )); then
        echo -e "${RED}Installation failed.${NC}"
        echo "You can try manually with:"
        echo "  curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh"
        return 1
    fi

    # Add to PATH for current session and persist to ~/.bashrc if not already present
    if [[ ":$PATH:" != *":$install_dir:"* ]]; then
        export PATH="$install_dir:$PATH"
        echo -e "${GREEN}✓ Added $install_dir to PATH for this session${NC}"
        local bashrc="${HOME}/.bashrc"
        local path_line="export PATH=\"$install_dir:\$PATH\""
        if ! grep -qF "$install_dir" "$bashrc" 2>/dev/null; then
            echo "" >> "$bashrc"
            echo "# Added by mini-bowling install" >> "$bashrc"
            echo "$path_line" >> "$bashrc"
            echo -e "${GREEN}✓ Persisted PATH to $bashrc${NC}"
        fi
    fi

    # Verify
    if "$install_dir/arduino-cli" version >/dev/null 2>&1; then
        echo -e "${GREEN}✓ arduino-cli successfully installed${NC}"
        "$install_dir/arduino-cli" version
    else
        echo -e "${RED}Verification failed${NC} — please check the install output above"
        return 1
    fi

    install_arduino_core
    install_arduino_libs
    echo
    echo "→ Checking for arduino-cli component upgrades..."
    upgrade_arduino_components
}

# Helper: execute a function in the context of a temporary git branch, then restore
with_git_branch() {
    local branch="$1"
    shift

    require_git_repo

    # Remember current state
    local original_ref
    original_ref=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) || die "Could not read HEAD — git repo may be corrupt"

    local was_dirty=false
    local stash_name=""
    if ! git -C "$PROJECT_DIR" diff --quiet || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
        was_dirty=true
        stash_name="mini-bowling-$(date '+%Y%m%d-%H%M%S')"
        echo -e "${YELLOW}Stashing local changes as:${NC} $stash_name"
        echo -e "  (If anything goes wrong, recover with: git stash list  /  git stash pop)"
        git -C "$PROJECT_DIR" stash push -m "$stash_name" || die "Stash failed"
    fi

    # Trap to restore branch + stash if the script is interrupted mid-flight.
    # Also chains to _DEPLOY_EXIT_HANDLER so cmd_deploy's lock / status cleanup
    # runs even when die() calls exit() directly (bypassing the ERR trap).
    local _restore_done=false
    _with_git_branch_restore() {
        if ! $_restore_done; then
            _restore_done=true
            echo -e "${YELLOW}Interrupted — restoring original branch: $original_ref${NC}"
            git -C "$PROJECT_DIR" checkout --quiet "$original_ref" 2>/dev/null || true
            if $was_dirty && [[ -n "$stash_name" ]]; then
                echo -e "${YELLOW}Restoring stashed changes ($stash_name)...${NC}"
                git -C "$PROJECT_DIR" stash pop --quiet 2>/dev/null || \
                    echo -e "${RED}Warning: stash pop failed — recover manually: git stash list${NC}"
            fi
        fi
        # Forward to caller's EXIT handler (e.g. _cmd_deploy_on_exit) if registered
        if [[ -n "${_DEPLOY_EXIT_HANDLER:-}" ]]; then
            local _h="$_DEPLOY_EXIT_HANDLER"
            _DEPLOY_EXIT_HANDLER=""
            eval "$_h"
        fi
    }
    trap '_with_git_branch_restore' INT TERM EXIT

    # Fetch latest from remote so we have up-to-date refs for all branches
    echo "→ Fetching latest from remote..."
    git -C "$PROJECT_DIR" fetch --quiet origin 2>/dev/null || echo -e "${YELLOW}Warning: git fetch failed — using local refs${NC}"

    # Checkout the requested branch, tracking remote if it's a remote-only branch
    echo -e "${YELLOW}Checking out branch:${NC} $branch"
    if git -C "$PROJECT_DIR" checkout --quiet "$branch" 2>/dev/null; then
        : # local branch exists, checked out
    elif git -C "$PROJECT_DIR" checkout --quiet -b "$branch" --track "origin/$branch" 2>/dev/null; then
        echo "  (created local tracking branch from origin/$branch)"
    else
        trap - INT TERM EXIT
        _with_git_branch_restore
        die "Cannot checkout '$branch' — does it exist on remote? Run: mini-bowling.sh code branch list"
    fi

    # Pull latest commits for this branch from remote
    echo "→ Pulling latest commits for $branch..."
    if git -C "$PROJECT_DIR" pull --quiet origin "$branch" 2>/dev/null; then
        local current_commit current_subject
        current_commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        current_subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo "")
        echo -e "${GREEN}→ Now at:${NC} [$current_commit] $current_subject"
    else
        trap - INT TERM EXIT
        _with_git_branch_restore
        die "git pull failed for branch '$branch' — check network and try again"
    fi

    # Run the requested command with remaining args
    local exit_code=0
    "$@" || exit_code=$?

    # Restore original branch and stash
    trap - INT TERM EXIT
    _restore_done=true

    echo -e "${YELLOW}Returning to original branch:${NC} $original_ref"
    git -C "$PROJECT_DIR" checkout --quiet "$original_ref" || echo -e "${RED}Warning: failed to return to $original_ref${NC}"

    if $was_dirty && [[ -n "$stash_name" ]]; then
        echo -e "${YELLOW}Restoring stashed changes ($stash_name)...${NC}"
        git -C "$PROJECT_DIR" stash pop --quiet || \
            echo -e "${RED}Warning: stash pop failed — recover manually: git stash list${NC}"
    fi

    # Re-register caller's EXIT trap so it remains active for the rest of cmd_deploy
    [[ -n "${_DEPLOY_EXIT_HANDLER:-}" ]] && trap "$_DEPLOY_EXIT_HANDLER" EXIT

    return $exit_code
}

# ------------------------------------------------
#  Main
# ------------------------------------------------

_show_full_help() {
    cat <<'EOF'
Usage: mini-bowling.sh <command> [subcommand] [options]

  system check          Is everything ready to bowl? (green/red summary)
  status                Full system status
  status --watch [N]    Auto-refresh every N seconds (default 5)
  info                  One-screen summary: Pi hardware + app + Arduino
  version               Show version and check GitHub for updates

  deploy                Get latest code → upload to Arduino → restart ScoreMore
  deploy --dry-run      Preview what deploy would do, without making changes
  deploy --no-kill      Deploy without stopping ScoreMore first
  deploy --branch NAME  Deploy from a specific code branch
  deploy reset          Delete local repo, clone fresh, then deploy
  deploy schedule HH:MM Schedule daily deploy at given time (Pi's local time)
  deploy unschedule     Remove scheduled deploy
  deploy history [N]    Show last N deploys from logs (default: 20)

  code                  Arduino code management
    code status                    Both git repos + Arduino board at a glance
    code board                     List detected Arduino boards and port addresses
    code board restart             Safely reboot the Arduino (does not change its code)
    code board reset               Wipe Arduino firmware — uploads a blank sketch (destructive)
    code sketch upload [--Name]    Compile + upload sketch to Arduino (default: Everything)
    code sketch upload --no-kill   Upload without stopping ScoreMore first
    code sketch upload --branch N  Upload from a specific code branch
    code sketch list               List available sketch folders in the project
    code sketch test [--Name]      Compile only — check for errors, no upload (default: Everything)
    code sketch rollback [N]       Roll back N git commits and re-upload (default: 1)
    code sketch info               Show what sketch and code version is on the Arduino now
    code compile [--Name]          Compile sketch without uploading (default: Everything)
    code pull                      Download latest code from GitHub (day-to-day update command)
    code pull BRANCH               Switch to a branch and download its latest code
    code switch [BRANCH]           Permanently switch to a branch (default: main)
    code console                   Read live serial output from the Arduino over USB
    code config                    Open the Arduino config editor in a browser
    code reset                     Delete local repo and clone fresh (saves/restores user config)
    code reset --apply-downloads   Also copy user config files from ~/Downloads after reset
    code branch list               List local + remote branches with commit info
    code branch checkout NAME      Temporarily checkout a branch, compile, then return
    code branch switch NAME        Permanently switch to a branch (fetches + pulls)
    code branch update             Same as 'code pull' — download latest for current branch
    code branch check              Check if GitHub has new commits without downloading them

  Note: 'Everything' is the name of the main Arduino sketch folder, not a wildcard.

  scoremore             ScoreMore bowling application management
    scoremore start                Launch ScoreMore
    scoremore stop                 Stop ScoreMore
    scoremore restart              Stop and relaunch ScoreMore
    scoremore update               Download newer version + restart if available
    scoremore update --check-only  Check for a newer version only — do not download
    scoremore download VERSION     Download a specific version (e.g. 1.8.0 or 'latest')
    scoremore version              Show the currently active version
    scoremore check-update         Check scoremorebowling.com for a newer version
    scoremore history              List all downloaded versions
    scoremore history use VERSION  Switch to a specific downloaded version
    scoremore history clean        Remove all downloaded versions except the active one
    scoremore rollback             Switch back to the previous downloaded version
    scoremore autostart enable     Start ScoreMore automatically when the Pi logs in
    scoremore autostart disable    Disable automatic start on login
    scoremore autostart status     Show whether autostart is configured
    scoremore logs                 List ScoreMore application logs
    scoremore logs tail            Watch ScoreMore logs live
    scoremore logs dump            Print the full latest ScoreMore log
    scoremore watchdog run         Run the crash-recovery check once now
    scoremore watchdog enable      Auto-restart ScoreMore every 5 min if it has crashed
    scoremore watchdog disable     Remove the auto-restart schedule
    scoremore watchdog status      Show whether auto-restart is configured

  pi                    Raspberry Pi management
    pi status                      CPU temp, memory, disk, uptime, architecture, OS
    pi sysinfo                     Full system identity (hostname, OS version, etc.)
    pi cpu                         CPU load averages and per-core usage bars
    pi cpu --watch [N]             Continuously refresh CPU stats (default: 3s)
    pi temp                        CPU temperature (one-shot)
    pi temp --watch [N]            Live CPU temperature monitor (default: 5s)
    pi disk                        Disk usage by key directory
    pi update                      Install Raspberry Pi OS software updates
    pi reboot                      Reboot with 5-second countdown
    pi shutdown                    Shut down with 5-second countdown
    pi wifi                        Wi-Fi interface, IP, signal strength, internet check
    pi vnc status                  VNC installation, service state, connect address
    pi vnc start|stop|enable|disable

  logs                  Log file management
    logs                           List log files with sizes
    logs follow                    Watch today's log live (Ctrl+C to stop)
    logs dump                      Print today's full log
    logs dump --date YYYY-MM-DD    Print a specific day's log
    logs tail [N]                  Last N lines of today's log (default: 50)
    logs tail [N] --date DATE      Last N lines of a specific day
    logs clean                     Delete all log files (asks for confirmation)
    logs clean --keep N            Keep last N days, delete older

  install               First-time setup and installation
    install setup                  Guided first-time setup wizard (safe to re-run)
    install create-dir             Create required directories only
    install cli                    Install arduino-cli (the Arduino upload tool)

  script                Script management
    script version                        Show version and check GitHub for updates
    script update                         Update script from GitHub (default branch: main)
    script update --branch NAME           Update from a specific branch
    script branch --list                  List available branches on the script repo

  component-upgrade     Check and upgrade all components
    component-upgrade              Check and install updates for all components
    component-upgrade --check      Report available updates without installing

  system                System administration
    system check                   Is everything ready to bowl? (green/red summary)
    system monitor                 Live resource monitor: CPU, memory, temp, processes
    system monitor --watch [N]     Auto-refresh monitor every N seconds (default: 5)
    system health                  Full dashboard: hardware, app, code, and scheduled tasks
    system report                  Generate a timestamped report file (health + logs + deploys)
    system support                 Generate a compressed diagnostic bundle to share with support
    system cron                    Show all scheduled mini-bowling tasks
    system doctor                  Verify all tools are installed and permissions are correct
    system preflight [--quick]     Run all checks before deploying code
    system backup [--include-appimage]  Archive sketches + config
    system repair                  Auto-fix common broken states
    system cleanup                 Remove old downloads, build caches, and old logs
    system ports                   List USB serial devices (helps identify Arduino port)
    system tail-all [N]            Watch command log + Arduino serial log together live
    system wait-for-network [N]    Wait up to N seconds for network (default: 30)
    system serial start|stop|status|tail|console
    system os-updates enable [HH:MM]        Schedule daily OS update (default: 03:00, Pi local time)
    system os-updates disable|status
    system scoremore-update enable [HH:MM]  Schedule daily ScoreMore update check (default: 03:30)
    system scoremore-update disable|status
    system script-update enable [HH:MM]     Schedule daily script update (default: 04:00)
    system script-update disable|status

  help [command]        Show full help or per-command detail
    help deploy | code | scoremore | pi | system | install | logs

EOF
}

_show_command_help() {
    local topic="${1:-}"
    case "$topic" in
        deploy)
            cat <<'EOF'
deploy — Pull latest code, upload to Arduino, restart ScoreMore

  mini-bowling.sh deploy
  mini-bowling.sh deploy --dry-run
  mini-bowling.sh deploy --no-kill
  mini-bowling.sh deploy --branch <name>
  mini-bowling.sh deploy --sketch <name>
  mini-bowling.sh deploy --Master_Test
  mini-bowling.sh deploy reset
  mini-bowling.sh deploy schedule HH:MM
  mini-bowling.sh deploy unschedule
  mini-bowling.sh deploy history [N]

Options:
  --dry-run          Show what would happen without making changes
  --no-kill          Do not stop ScoreMore before uploading (still starts it after)
  --branch <name>    Temporarily switch to a branch before deploying
  --sketch <name>    Deploy a specific sketch folder (default: Everything)
  --<SketchName>     Shorthand for --sketch, e.g. --Master_Test

Sketch selection:
  deploy                  — upload the Everything sketch (default, restarts ScoreMore)
  deploy --Master_Test    — upload Master_Test sketch only (ScoreMore left as-is)
  deploy --sketch <name>  — upload any sketch folder by name

  Run 'mini-bowling.sh code sketch list' to see all available sketches.

Reset + Deploy:
  deploy reset            — delete local Arduino repo, clone fresh, then deploy

Scheduling:
  deploy schedule 02:30   — run deploy automatically every day at 02:30 (Pi's local time)
  deploy unschedule       — remove the scheduled job
  deploy history          — show last 20 deploys from log files
EOF
            ;;
        code)
            cat <<'EOF'
code — Arduino code management

  code status                 Both git repos + Arduino board at a glance
  code sketch upload          Compile + upload to Arduino (default: Everything sketch)
  code sketch list            List sketch folders in the project directory
  code sketch test            Compile only — check for errors, no upload
  code sketch rollback        Roll back N git commits and re-upload (default: 1)
  code sketch info            Show what sketch and code version is currently on the Arduino
  code compile                Compile without uploading (faster error check)
  code pull                   Download latest code from GitHub (everyday update command)
  code switch [BRANCH]        Permanently switch git branch (default: main)
  code console                Read live serial output from the Arduino over USB
  code config                 Open the Arduino config editor in a browser
  code reset                  Delete local repo and clone fresh (auto-saves/restores user config)
  code reset --apply-downloads  Also apply user config files from ~/Downloads after reset
  code board list             Show detected Arduino boards and port addresses
  code board restart          Safely reboot the Arduino — does NOT change its code
  code board reset            Wipe Arduino firmware by uploading a blank sketch (destructive)
  code branch list|checkout|switch|update|check

Note: 'Everything' is the name of the main Arduino sketch folder, not a wildcard.
Note: 'code pull' and 'code branch update' both download the latest code — 'code pull' is the everyday command.

Tip: use 'code sketch info' to confirm the Arduino is running the expected code.
Tip: use 'code status' to see both git repos and the Arduino board together.
Tip: use 'code board restart' to reboot the Arduino without uploading new code.
Tip: use 'code board reset' only if you need to wipe the firmware before re-deploying.
Tip: use 'code reset' to recover from a corrupted or broken local repo.
Tip: 'code reset' automatically saves and restores general_config.user.h and pin_config.user.h.
EOF
            ;;
        scoremore)
            cat <<'EOF'
scoremore — ScoreMore bowling application management

  scoremore start|stop|restart
  scoremore download latest|<version>
  scoremore version
  scoremore check-update
  scoremore history [list|use <ver>|clean]
  scoremore rollback
  scoremore autostart enable|disable|status
  scoremore logs [show|list|tail|dump]
  scoremore watchdog run|enable|disable|status

Tip: use 'scoremore watchdog enable' to set up automatic crash recovery — ScoreMore will restart itself if it stops unexpectedly.
Tip: use 'scoremore autostart enable' to start ScoreMore automatically every time the Pi logs in.
EOF
            ;;
        pi)
            cat <<'EOF'
pi — Raspberry Pi monitoring and management

  pi status             CPU temp, memory, disk, uptime, architecture, OS
  pi sysinfo            Full hostnamectl identity
  pi cpu                CPU load averages and per-core bar graph
  pi cpu --watch [N]    Live refresh every N seconds (default 3)
  pi temp               CPU temperature (one-shot)
  pi temp --watch [N]   Live temp monitor every N seconds (default 5)
  pi disk               Disk usage by key directory (project, ScoreMore, logs)
  pi update             Run apt update + upgrade
  pi reboot             Reboot with 5-second countdown
  pi shutdown           Shut down with 5-second countdown
  pi wifi               Wi-Fi interface, IP, SSID, signal, internet check
  pi vnc status|start|stop|enable|disable

Tip: use 'pi temp --watch' to monitor temperature during a long compile.
EOF
            ;;
        system)
            cat <<'EOF'
system — System administration commands

  system check          Is everything ready to bowl? (green/red summary)
  system monitor        Live resource monitor: CPU, memory, temperature, processes
  system monitor --watch [N]  Auto-refresh every N seconds (default: 5)
  system health         Full dashboard: hardware, app, code, and scheduled tasks
  system report         Generate a timestamped report file (health + logs + deploys)
  system support        Generate a compressed diagnostic bundle to share with support
  system cron           Show all scheduled mini-bowling tasks
  system doctor         Verify all tools are installed and permissions are correct
  system preflight      Run all pre-deploy checks (--quick skips network test)
  system backup         Archive sketches + config to ~/mini-bowling-backup/
  system repair         Auto-fix common broken states
  system cleanup        Remove old downloads, build caches, and old logs
  system ports          List USB serial devices (helps identify which port the Arduino is on)
  system tail-all [N]   Watch command log + Arduino serial log together live
  system wait-for-network [N]  Wait until the network is reachable (default: 30s)
  system serial start|stop|status|tail|console

Tip: run 'system check' before a bowling event to confirm everything is ready.
Tip: run 'system preflight' before a deploy to catch issues early.
Tip: run 'system monitor' to watch CPU and memory in real time if something feels slow.
Tip: run 'system support' to create a diagnostic bundle when reporting an issue.
EOF
            ;;
        install)
            cat <<'EOF'
install — First-time setup and installation

  install setup         Guided setup wizard (9 steps, safe to re-run)
  install create-dir    Create required directories only
  install cli           Download and install arduino-cli (the Arduino upload tool)

The setup wizard covers:
  1. Create required directories
  2. Install arduino-cli (the tool that compiles and uploads code to the Arduino)
  3. Clone the Arduino project code from GitHub (or verify it is already present)
  4. Install the Arduino board support and required code libraries
  5. Install this script to /usr/bin so it is available system-wide
  6. Configure ScoreMore to start automatically when the Pi logs in
  7. Download the latest ScoreMore application
  8. Enable automatic crash recovery (restarts ScoreMore if it stops unexpectedly)
  9. Optionally schedule a daily automatic code update

Tip: re-running 'install setup' is safe — it skips steps that are already done.
EOF
            ;;
        logs)
            cat <<'EOF'
logs — Log file management

  logs                  List log files with sizes
  logs follow           Live tail today's log file
  logs dump             Print today's full log
  logs dump --date YYYY-MM-DD   Print a specific day's log
  logs tail [N]         Last N lines of today's log (default: 50)
  logs tail N --date DATE       Last N lines of a specific day
  logs clean            Delete all log files (confirms first)
  logs clean --keep N   Keep last N days, delete older

Log files are stored in: ~/Documents/Bowling/logs/
EOF
            ;;
        *)
            echo "Available help topics:"
            echo "  deploy  code  scoremore  pi  system  install  logs"
            echo
            echo "Usage: mini-bowling.sh help <topic>"
            echo "  Example: mini-bowling.sh help deploy"
            echo "        or: mini-bowling.sh  (no args) for interactive menu"
            ;;
    esac
}

main() {
    if [[ $# -eq 0 ]]; then
        # Interactive numbered menu — runs a command on selection
        local _menu_items=(
            "system check        — is everything ready to bowl? (green/red summary)"
            "status              — full system status"
            "info                — one-screen summary of Pi + app + Arduino"
            "system health       — detailed dashboard: hardware, app, code, and cron jobs"
            "system monitor      — live resource monitor: CPU, memory, temperature, processes"
            "deploy              — get latest code + upload to Arduino + restart ScoreMore"
            "deploy --dry-run    — preview what deploy would do, without making changes"
            "scoremore restart   — restart the ScoreMore bowling application"
            "scoremore update    — download a newer ScoreMore version if available"
            "scoremore start     — launch ScoreMore"
            "scoremore stop      — stop ScoreMore"
            "code sketch upload  — compile + upload the Everything sketch to the Arduino"
            "code sketch info    — show what code is currently running on the Arduino"
            "code status         — show both git repos and Arduino board at a glance"
            "code board          — list detected Arduino boards and ports"
            "code pull           — download the latest Arduino code (does not upload)"
            "code console        — read live output from the Arduino over USB"
            "code config         — open the Arduino config editor in a browser"
            "pi status           — CPU temperature, memory, disk, uptime"
            "pi cpu              — live CPU load and per-core usage"
            "pi temp --watch     — live CPU temperature monitor"
            "pi disk             — disk usage breakdown"
            "pi update           — install system software updates"
            "logs follow         — live tail today's log"
            "system report       — generate a timestamped system report file"
            "system support      — generate a diagnostic bundle to share with support"
            "system cron         — show scheduled mini-bowling tasks"
            "system doctor       — verify all tools are installed and permissions are correct"
            "system preflight    — run all checks before deploying code"
            "scoremore watchdog enable  — enable auto-restart if ScoreMore crashes"
            "install setup       — guided first-time setup wizard"
            "script update       — update this script from GitHub"
            "component-upgrade   — check and upgrade all components"
            "help                — full command reference"
        )

        echo "mini-bowling.sh  v${SCRIPT_VERSION}"
        echo "Manage your mini-bowling system: Arduino code, ScoreMore app, and Raspberry Pi."
        echo
        echo "What would you like to do?"
        echo
        local i=1
        for item in "${_menu_items[@]}"; do
            printf "  %2d)  %s\n" "$i" "$item"
            (( ++i ))
        done
        echo
        printf "Enter number (or press Enter to cancel): "
        local choice
        read -r choice </dev/tty

        [[ -z "$choice" ]] && exit 0

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#_menu_items[@]} )); then
            echo "Invalid selection." >&2
            exit 1
        fi

        local selected="${_menu_items[$(( choice - 1 ))]}"
        # Extract command part (before the ' — ' separator)
        local run_cmd
        run_cmd=$(echo "$selected" | sed 's/[[:space:]][[:space:]]*—.*//')
        run_cmd=$(echo "$run_cmd" | sed 's/^[[:space:]]*//')

        echo
        echo "Running: mini-bowling.sh $run_cmd"
        echo

        if [[ "$run_cmd" == "help" ]]; then
            _show_full_help
            exit 0
        fi

        # Re-invoke with the selected command
        local -a run_argv=()
        local old_ifs="$IFS"
        IFS=' '
        read -r -a run_argv <<< "$run_cmd"
        IFS="$old_ifs"
        exec "$0" "${run_argv[@]}"
    fi

    local cmd="$1"

    # Ensure ~/.local/bin is in PATH if arduino-cli was installed there
    _ensure_local_bin_path

    # Item 8: silently create required directories on first run if missing
    mkdir -p "$PROJECT_DIR" "$SCOREMORE_DIR" "$LOG_DIR" 2>/dev/null || true

    # Skip logging for purely read-only commands that don't change any state.
    # Everything else (deploy, code, scoremore download/start/stop, pi reboot, etc.) IS logged.
    local _log=true
    case "$cmd" in
        status|info|version|logs|help)
            _log=false ;;
        system)
            # system doctor/preflight/ports/tail-all/wait-for-network/health/cron/check/monitor are read-only
            # system backup/repair/cleanup DO modify state - log those
            case "${2:-}" in
                check|health|monitor|cron|doctor|preflight|ports|tail-all|wait-for-network)
                    _log=false ;;
                os-updates|scoremore-update|script-update)
                    [[ "${3:-}" == "status" ]] && _log=false ;;
            esac ;;
        scoremore)
            # scoremore version/check-update/history/logs/watchdog-status are read-only
            case "${2:-}" in
                version|check-update|history|logs)
                    _log=false ;;
                update)
                    # scoremore update --check-only is read-only; bare update modifies state
                    [[ "${3:-}" == "--check-only" ]] && _log=false ;;
                watchdog)
                    [[ "${3:-}" == "status" ]] && _log=false ;;
            esac ;;
        pi)
            # pi status/sysinfo/temp/disk/cpu/wifi are read-only; pi vnc status is read-only
            case "${2:-}" in
                status|sysinfo|temp|disk|cpu|wifi)
                    _log=false ;;
                vnc)
                    [[ "${3:-}" == "status" ]] && _log=false ;;
            esac ;;
        code)
            # code branch list/check are read-only; code sketch list/compile are read-only
            case "${2:-}" in
                status|board) _log=false ;;
                branch)
                    case "${3:-}" in
                        list|check) _log=false ;;
                    esac ;;
                sketch)
                    [[ "${3:-}" == "list" || "${3:-}" == "info" ]] && _log=false ;;
                compile|console|config) _log=false ;;
            esac ;;
        deploy)
            [[ "${2:-}" == "history" ]] && _log=false ;;
        script)
            # script version is read-only
            [[ "${2:-}" == "version" ]] && _log=false ;;
    esac

    if $_log; then
        setup_logging "$cmd" "$@"
        prune_logs
    fi

    shift

    # Commands using sudo need a real TTY - run them directly, log header only
    local bypass_tee=false
    if [[ "$cmd" == "pi" ]]; then
        bypass_tee=true
    fi

    # Dispatch - if logging is active, pipe stdout to tee without exec redirects
    if [[ -n "${MINI_BOWLING_LOG:-}" ]] && ! $bypass_tee; then
        _dispatch "$cmd" "$@" | tee -a "$MINI_BOWLING_LOG"
    else
        _dispatch "$cmd" "$@"
    fi

    echo -e "${GREEN}Done.${NC}"
}

# Resolve "latest" to the actual ScoreMore version string; pass through any
# explicit version unchanged.  Dies on network failure when resolving "latest".
_resolve_dl_version() {
    local ver="$1"
    if [[ "$ver" == "latest" ]]; then
        echo "Resolving latest ScoreMore version..." >&2
        ver=$(_fetch_latest_scoremore_version)
        [[ -n "$ver" ]] || die "Could not determine latest version from scoremorebowling.com"
        echo "Latest version: $ver" >&2
    fi
    echo "$ver"
}

# Shared upload logic for code sketch upload and code branch checkout.
# Compiles + uploads $sketch; handles branch switching via with_git_branch;
# restarts ScoreMore when the Everything sketch is uploaded with kill enabled.
_do_upload() {
    local sketch="$1" branch="$2" kill_app="$3"
    local current_branch
    current_branch=$(_current_branch)
    if [[ -z "$branch" || "$branch" == "$current_branch" ]]; then
        cmd_compile_and_upload "$sketch" "$kill_app"
    else
        with_git_branch "$branch" cmd_compile_and_upload "$sketch" "$kill_app"
    fi
    if [[ "$sketch" == "Everything" && "$kill_app" == "true" ]]; then
        start_scoremore
    elif [[ "$sketch" == "Everything" ]]; then
        echo "ScoreMore left as-is (--no-kill)"
    else
        echo "ScoreMore left as-is (sketch is '$sketch' from branch '$branch', not 'Everything')"
    fi
}

# Pull latest code for the current or a specified branch.
# Usage: cmd_code_pull [<branch>|--branch <branch>|--branch=<branch>]
cmd_code_pull() {
    require_git_repo
    local branch=""
    if [[ "${1:-}" == "--branch" ]]; then
        branch="${2:?Missing branch name after --branch}"
        shift 2
    elif [[ "${1:-}" == --branch=* ]]; then
        branch="${1#--branch=}"
        shift
    elif [[ -n "${1:-}" && "${1:-}" != --* ]]; then
        branch="$1"
        shift
    fi

    local current
    current=$(_current_branch)

    if [[ -n "$branch" && "$branch" != "$current" ]]; then
        echo "→ Fetching from remote..."
        git -C "$PROJECT_DIR" fetch --quiet origin 2>/dev/null || \
            echo -e "${YELLOW}Warning: fetch failed${NC}"
        echo -e "${YELLOW}Switching to branch:${NC} $branch"
        if git -C "$PROJECT_DIR" checkout --quiet "$branch" 2>/dev/null; then
            : # local branch exists
        elif git -C "$PROJECT_DIR" checkout --quiet -b "$branch" --track "origin/$branch" 2>/dev/null; then
            echo "  (created local tracking branch from origin/$branch)"
        else
            die "Cannot checkout '$branch' — run: mini-bowling.sh code branch list"
        fi
        current="$branch"
    else
        echo "→ Fetching from remote..."
        git -C "$PROJECT_DIR" fetch --quiet origin 2>/dev/null || \
            echo -e "${YELLOW}Warning: fetch failed${NC}"
    fi

    if ! git -C "$PROJECT_DIR" diff --quiet || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
        echo -e "${YELLOW}Warning:${NC} uncommitted local changes — pulling anyway (may cause conflicts)"
    fi
    echo "→ Pulling latest commits for $current..."
    git -C "$PROJECT_DIR" pull origin "$current" 2>/dev/null || \
        die "git pull failed — check network and try again"

    local commit subject
    commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    subject=$(git -C "$PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo "")
    echo -e "${GREEN}✓ $current is up to date:${NC} [$commit] $subject"
}

_dispatch() {
    local cmd="$1"
    shift

    case "$cmd" in

        # -- help (top-level) -------------------------------------------------
        help)
            if [[ -n "${1:-}" ]]; then
                _show_command_help "$1"
            else
                _show_full_help
            fi
            ;;

        # -- status / info (top-level shortcuts) ------------------------------
        status)
            if [[ "${1:-}" == "--watch" || "${1:-}" == "-w" ]]; then
                watch_status "${2:-5}"
            else
                print_status
            fi
            ;;

        info)
            show_info
            ;;

        # -- version (top-level shortcut) --------------------------------------
        version)
            script_version
            ;;

        # -- deploy ------------------------------------------------------------
        deploy)
            local subcmd="${1:-run}"
            # If first arg looks like a flag, treat as bare deploy
            [[ "${1:-}" == --* || -z "${1:-}" ]] && subcmd="run"
            [[ "$subcmd" != "run" && "$subcmd" != "schedule" && "$subcmd" != "unschedule" && "$subcmd" != "history" && "$subcmd" != "reset" ]] && subcmd="run"
            case "$subcmd" in
                run)
                    cmd_deploy "$@"
                    ;;
                schedule)
                    shift
                    schedule_deploy "${1?Missing time — usage: deploy schedule HH:MM}"
                    ;;
                unschedule)
                    unschedule_deploy
                    ;;
                history)
                    deploy_history "$@"
                    ;;
                reset)
                    shift
                    echo "=== Deploy Reset ==="
                    echo
                    cmd_code_reset --force
                    echo
                    echo "→ Proceeding with fresh deploy..."
                    echo
                    cmd_deploy "$@"
                    ;;
            esac
            ;;

        # -- sketch ------------------------------------------------------------
        # -- code (sketch + branch) --------------------------------------------
        code)
            local codecmd="${1:-help}"; shift 2>/dev/null || true
            case "$codecmd" in

                # code sketch -------------------------------------------------
                sketch)
                    local subcmd="${1:-upload}"; shift 2>/dev/null || true
                    case "$subcmd" in
                        upload)
                            local branch="$DEFAULT_GIT_BRANCH" sketch="Everything" kill_app="true"
                            while [[ $# -gt 0 ]]; do
                                case "$1" in
                                    --no-kill|-k)  kill_app="false"; shift ;;
                                    --branch=*)    branch="${1#--branch=}"; shift ;;
                                    --branch)      shift; branch="${1?}"; shift ;;
                                    --*)           sketch="${1#--}"; shift ;;
                                    *)             die "Unexpected argument: $1" ;;
                                esac
                            done
                            [[ "$sketch" != "Everything" ]] && kill_app="false"
                            _do_upload "$sketch" "$branch" "$kill_app"
                            ;;
                        list)
                            list_available_sketches
                            ;;
                        test)
                            local sketch="Everything"
                            [[ "${1:-}" == --* ]] && sketch="${1#--}"
                            cmd_test_upload "$sketch"
                            ;;
                        rollback)
                            cmd_rollback "${1:-1}"
                            ;;
                        info)
                            cmd_sketch_info
                            ;;
                        *)
                            die "Unknown code sketch subcommand: '$subcmd' — use: upload, list, test, rollback, info"
                            ;;
                    esac
                    ;;

                branch)
                    local subcmd="${1:-list}"; shift 2>/dev/null || true
                    case "$subcmd" in
                        list)
                            list_branches
                            ;;
                        checkout)
                            local br="${1?Missing branch name — usage: code branch checkout <n>}"
                            local sketch="${2:-Everything}"
                            [[ "$sketch" == --* ]] && sketch="${sketch#--}"
                            local kill_app="true"
                            [[ "$sketch" != "Everything" ]] && kill_app="false"
                            with_git_branch "$br" cmd_compile_and_upload "$sketch" "$kill_app"
                            if [[ "$sketch" == "Everything" ]]; then
                                start_scoremore
                            fi
                            ;;
                        switch)
                            switch_branch "${1:-$DEFAULT_GIT_BRANCH}"
                            ;;
                        update)
                            cmd_update
                            ;;
                        check)
                            check_update
                            ;;
                        *)
                            die "Unknown code branch subcommand: '$subcmd' — use: list, checkout, switch, update, check"
                            ;;
                    esac
                    ;;

                # code pull ---------------------------------------------------
                pull)
                    cmd_code_pull "$@"
                    ;;

                # code switch -------------------------------------------------
                switch)
                    # Shorthand for: code branch switch <branch> (default: main)
                    switch_branch "${1:-$DEFAULT_GIT_BRANCH}"
                    ;;

                # code compile ------------------------------------------------
                compile)
                    # Compile sketch without uploading — defaults to Everything
                    local sketch="Everything"
                    [[ "${1:-}" == --* ]] && sketch="${1#--}" && shift
                    compile_sketch_only "$sketch"
                    ;;

                # code status -------------------------------------------------
                status)
                    cmd_code_status
                    ;;

                # code board --------------------------------------------------
                board)
                    local board_subcmd="${1:-list}"; shift 2>/dev/null || true
                    case "$board_subcmd" in
                        list|show|"")
                            cmd_code_board
                            ;;
                        reset)
                            cmd_board_reset "$@"
                            ;;
                        restart)
                            cmd_board_restart
                            ;;
                        *)
                            die "Unknown code board subcommand: '$board_subcmd' — use: list, reset, restart"
                            ;;
                    esac
                    ;;

                # code console ------------------------------------------------
                console)
                    # Shorthand for: system serial console
                    show_console
                    ;;

                # code config -------------------------------------------------
                config)
                    cmd_config_tool
                    ;;

                # code reset --------------------------------------------------
                reset)
                    cmd_code_reset "$@"
                    ;;

                *)
                    echo "code subcommands:"
                    echo "  code status                    both git repos + Arduino board at a glance"
                    echo "  code board list                show detected Arduino boards (arduino-cli board list)"
                    echo "  code board restart             restart the Arduino by toggling DTR on the serial port"
                    echo "  code board reset               upload blank sketch to reset the Arduino board firmware"
                    echo "  code sketch upload [--Name] [--branch <n>] [--no-kill]"
                    echo "  code sketch list"
                    echo "  code sketch test [--Name]      compile only — no upload"
                    echo "  code sketch rollback [N]"
                    echo "  code sketch info               sketch, branch, and commit on Arduino"
                    echo "  code compile [--Name]          compile sketch without uploading (default: Everything)"
                    echo "  code pull                      pull latest for current branch"
                    echo "  code pull <branch>             switch to branch and pull latest"
                    echo "  code pull --branch <n>         switch to branch and pull latest"
                    echo "  code switch [<branch>]         permanently switch to branch (default: main)"
                    echo "  code console                   open interactive serial console"
                    echo "  code config                    open Arduino config tool in browser"
                    echo "  code reset                     delete local repo and clone fresh from remote"
                    echo "  code branch list"
                    echo "  code branch checkout <n> [--Sketch]"
                    echo "  code branch switch [<n>]       permanently switch branch (default: main)"
                    echo "  code branch update             pull latest for current branch"
                    echo "  code branch check              check remote for new commits"
                    ;;
            esac
            ;;

        # -- scoremore ---------------------------------------------------------
        scoremore)
            local subcmd="${1:-restart}"; shift 2>/dev/null || true
            case "$subcmd" in
                start)           start_scoremore ;;
                stop)            kill_scoremore_gracefully ;;
                restart)         restart_scoremore ;;
                download)
                    local ver
                    ver=$(_resolve_dl_version "${1?Missing version — use: scoremore download <ver> or latest}")
                    download_scoremore_version "$ver"
                    ;;
                version)         scoremore_version ;;
                check-update)    check_scoremore_update ;;
                update)          scoremore_update "$@" ;;
                history)         scoremore_history "$@" ;;
                rollback)        rollback_scoremore ;;
                autostart)
                    local astcmd="${1:-enable}"; shift 2>/dev/null || true
                    case "$astcmd" in
                        enable)  setup_autostart ;;
                        disable) remove_autostart ;;
                        status)
                            local desktop_file="$HOME/.config/autostart/scoremore.desktop"
                            if [[ -f "$desktop_file" ]]; then
                                echo -e "${GREEN}✓ ScoreMore autostart is enabled${NC}"
                                echo "  File: $desktop_file"
                            else
                                echo -e "${YELLOW}✗ ScoreMore autostart is disabled${NC}"
                            fi
                            ;;
                        *)  die "Unknown autostart subcommand: '$astcmd' — use: enable, disable, status" ;;
                    esac
                    ;;
                remove-autostart) remove_autostart ;;  # deprecated: use 'scoremore autostart disable'
                logs)            scoremore_logs "${1:-show}" ;;
                watchdog)
                    local wdcmd="${1:-run}"; shift 2>/dev/null || true
                    case "$wdcmd" in
                        run)     watchdog ;;
                        enable)  setup_watchdog enable ;;
                        disable) setup_watchdog disable ;;
                        status)  setup_watchdog status ;;
                        *)
                            die "Unknown scoremore watchdog subcommand: '$wdcmd' — use: run, enable, disable, status"
                            ;;
                    esac
                    ;;
                *)
                    die "Unknown scoremore subcommand: '$subcmd' — use: start, stop, restart, download, version, update, check-update, history, rollback, autostart, logs, watchdog"
                    ;;
            esac
            ;;

        # -- system ------------------------------------------------------------
        system)
            local subcmd="${1:-help}"; shift 2>/dev/null || true
            case "$subcmd" in
                check)            system_check ;;
                monitor)          system_monitor "$@" ;;
                health)           system_health ;;
                report)           system_report ;;
                support)          support_bundle ;;
                cron)             system_cron ;;
                os-updates)       setup_os_updates_schedule "${1:-enable}" "${2:-}" ;;
                scoremore-update) setup_scoremore_update_schedule "${1:-enable}" "${2:-}" ;;
                script-update)    setup_script_update_schedule "${1:-enable}" "${2:-}" ;;
                doctor)           doctor ;;
                preflight)        preflight "$@" ;;
                backup)           backup_config "$@" ;;
                repair)           repair ;;
                cleanup)          disk_cleanup ;;
                ports)            show_ports ;;
                tail-all)         tail_all "$@" ;;
                wait-for-network) wait_for_network "${1:-30}" ;;
                watchdog)
                    # Deprecated: watchdog moved to 'scoremore watchdog' in v4.0.0
                    echo -e "${YELLOW}Warning:${NC} 'system watchdog' has moved to 'scoremore watchdog' as of v4.0.0." >&2
                    echo -e "  Please update any cron jobs or scripts to use: mini-bowling.sh scoremore watchdog $*" >&2
                    echo >&2
                    setup_watchdog_or_run() {
                        local wdcmd="${1:-run}"; shift 2>/dev/null || true
                        case "$wdcmd" in
                            run)     watchdog ;;
                            enable)  setup_watchdog enable ;;
                            disable) setup_watchdog disable ;;
                            status)  setup_watchdog status ;;
                            *)       die "Unknown watchdog subcommand: '$wdcmd' — use: run, enable, disable, status" ;;
                        esac
                    }
                    setup_watchdog_or_run "$@"
                    ;;
                serial)
                    local sercmd="${1:-status}"; shift 2>/dev/null || true
                    case "$sercmd" in
                        start|stop|status|tail) serial_log "$sercmd" "$@" ;;
                        console)                show_console ;;
                        *)
                            die "Unknown system serial subcommand: '$sercmd' — use: start, stop, status, tail, console"
                            ;;
                    esac
                    ;;
                *)
                    echo "system subcommands:"
                    echo "  check                   is everything ready to bowl? (green/red summary)"
                    echo "  monitor                 live resource monitor: CPU, memory, temp, processes"
                    echo "  monitor --watch [N]     auto-refresh monitor every N seconds (default: 5)"
                    echo "  health                  full dashboard: hardware, app, code, scheduled tasks"
                    echo "  report                  generate timestamped report file"
                    echo "  support                 generate compressed diagnostic bundle for support"
                    echo "  cron                    show all scheduled mini-bowling tasks"
                    echo "  doctor                  verify all tools installed and permissions correct"
                    echo "  preflight [--quick]     run all checks before deploying code"
                    echo "  backup [--include-appimage]  archive sketches + config"
                    echo "  repair                  auto-fix common broken states"
                    echo "  cleanup                 remove old downloads, build caches, and old logs"
                    echo "  ports                   list USB serial devices (helps find Arduino port)"
                    echo "  tail-all [N]            watch command log + Arduino serial log together live"
                    echo "  wait-for-network [N]    wait until network is reachable (default: 30s)"
                    echo "  serial start|stop|status|tail|console"
                    echo "  os-updates enable [HH:MM]    schedule daily OS update (default: 03:00)"
                    echo "  os-updates disable|status"
                    echo "  scoremore-update enable [HH:MM]  schedule daily ScoreMore update check (default: 03:30)"
                    echo "  scoremore-update disable|status"
                    echo "  script-update enable [HH:MM] schedule daily script update (default: 04:00)"
                    echo "  script-update disable|status"
                    echo ""
                    echo "  (watchdog moved to: scoremore watchdog run|enable|disable|status)"
                    echo ""
                    echo "See also: install setup|create-dir|cli"
                    echo "         script version|update"
                    ;;
            esac
            ;;
        pi)
            local subcmd="${1:-status}"; shift 2>/dev/null || true
            case "$subcmd" in
                status)   pi_status ;;
                sysinfo)  pi_sysinfo ;;
                cpu)      pi_cpu "$@" ;;
                temp)     pi_temp "$@" ;;
                disk)     pi_disk ;;
                update)   pi_update ;;
                reboot)   pi_reboot ;;
                shutdown) pi_shutdown ;;
                wifi)     wifi_status ;;
                vnc)
                    local vncmd="${1:-status}"; shift 2>/dev/null || true
                    case "$vncmd" in
                        status)  vnc_status ;;
                        start)   vnc_setup start ;;
                        stop)    vnc_setup stop ;;
                        enable)  vnc_setup enable-autostart ;;
                        disable) vnc_setup disable-autostart ;;
                        *)
                            die "Unknown pi vnc subcommand: '$vncmd' — use: status, start, stop, enable, disable"
                            ;;
                    esac
                    ;;
                *)
                    die "Unknown pi subcommand: '$subcmd' — use: status, sysinfo, cpu, temp, disk, update, reboot, shutdown, wifi, vnc"
                    ;;
            esac
            ;;

        # -- logs (top-level shortcut) -----------------------------------------
        logs)
            show_logs "$@"
            ;;

        # -- install (top-level) -----------------------------------------------
        install)
            local instcmd="${1:-setup}"; shift 2>/dev/null || true
            case "$instcmd" in
                setup)      install_setup ;;
                create-dir) ensure_directories ;;
                cli)        install_cli ;;
                *)
                    die "Unknown install subcommand: '$instcmd' — use: setup, create-dir, cli  (for preflight use: system preflight)"
                    ;;
            esac
            ;;

        # -- script (top-level) ------------------------------------------------
        script)
            local scrcmd="${1:-version}"; shift 2>/dev/null || true
            case "$scrcmd" in
                version) script_version ;;
                update)  update_script "$@" ;;
                branch)
                    local _brsubcmd="${1:-}"; shift 2>/dev/null || true
                    case "$_brsubcmd" in
                        --list|list) list_script_branches ;;
                        "")          list_script_branches ;;
                        *) die "Unknown script branch subcommand: '$_brsubcmd' — use: --list" ;;
                    esac
                    ;;
                *)
                    die "Unknown script subcommand: '$scrcmd' — use: version, update [--branch <name>], branch --list"
                    ;;
            esac
            ;;

        # -- component-upgrade -------------------------------------------------
        component-upgrade)
            cmd_component_upgrade "$@"
            ;;

        *)
            echo "Unknown command: '$cmd'" >&2
            echo "Run: mini-bowling.sh  (no arguments) to see all commands" >&2
            exit 1
            ;;
    esac
}

# Allow sourcing for unit tests without running main
[[ "${MINI_BOWLING_SOURCED:-}" == "1" ]] || main "$@"
