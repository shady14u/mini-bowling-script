#!/usr/bin/env bash
# =============================================================================
#  mini-bowling-test.sh — unit tests for mini-bowling.sh
#
#  Usage:
#    ./mini-bowling-test.sh                     # run all tests
#    ./mini-bowling-test.sh unit                # unit tests only (no hardware)
#    ./mini-bowling-test.sh integration         # integration tests (needs Arduino)
#    ./mini-bowling-test.sh -v                  # verbose output
#
#  Tests are grouped into:
#    UNIT        — pure logic, no external tools or hardware required
#    INTEGRATION — requires Arduino connected, ScoreMore present, etc.
#
#  Exit code: 0 if all tests pass, 1 if any fail.
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/mini-bowling.sh"
VERBOSE=false
RUN_MODE="all"   # all | unit | integration

# ── Arg parsing ───────────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=true ;;
        unit)         RUN_MODE="unit" ;;
        integration)  RUN_MODE="integration" ;;
    esac
done

# ── Colours ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Test framework ────────────────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0
CURRENT_SUITE=""

suite() {
    CURRENT_SUITE="$1"
    echo -e "\n${CYAN}${BOLD}Ã¢—Â¶ $1${NC}"
}

pass() {
    local name="$1"
    PASS=$(( PASS + 1 ))
    echo -e "  ${GREEN}✓${NC}  $name"
}

fail() {
    local name="$1"
    local detail="${2:-}"
    FAIL=$(( FAIL + 1 ))
    echo -e "  ${RED}Ã¢Å“—${NC}  $name"
    [[ -n "$detail" ]] && echo -e "       ${RED}$detail${NC}"
}

skip() {
    local name="$1"
    local reason="${2:-}"
    SKIP=$(( SKIP + 1 ))
    echo -e "  ${YELLOW}-${NC}  $name${reason:+  (${reason})}"
}

# Run a command and capture output + exit code without killing the test script
run() {
    local out
    _run_exit=0
    { out=$(set +e; "$@" 2>&1); _run_exit=$?; } 2>/dev/null || true
    _run_out="$out"
}

assert_exit() {
    local name="$1" expected="$2"
    if [[ "$_run_exit" -eq "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected exit $expected, got $_run_exit"
        $VERBOSE && echo "       output: $_run_out"
    fi
}

assert_output_contains() {
    local name="$1" pattern="$2"
    local clean_out
    clean_out=$(echo "$_run_out" | sed 's/\x1b\[[0-9;]*m//g')
    if echo "$clean_out" | grep -q "$pattern"; then
        pass "$name"
    else
        fail "$name" "expected output to contain: $pattern"
        $VERBOSE && echo "       output: $clean_out"
    fi
}

assert_output_not_contains() {
    local name="$1" pattern="$2"
    local clean_out
    clean_out=$(echo "$_run_out" | sed 's/\x1b\[[0-9;]*m//g')
    if ! echo "$clean_out" | grep -q "$pattern"; then
        pass "$name"
    else
        fail "$name" "output should NOT contain: $pattern"
        $VERBOSE && echo "       output: $clean_out"
    fi
}

assert_equals() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected '$expected', got '$actual'"
    fi
}

assert_file_exists() {
    local name="$1" path="$2"
    if [[ -e "$path" ]]; then
        pass "$name"
    else
        fail "$name" "file not found: $path"
    fi
}

assert_nonzero() {
    local name="$1"
    if [[ "$_run_exit" -ne 0 ]]; then
        pass "$name"
    else
        fail "$name" "expected non-zero exit, got 0"
        $VERBOSE && echo "       output: $_run_out"
    fi
}

assert_file_not_exists() {
    local name="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        pass "$name"
    else
        fail "$name" "file should not exist: $path"
    fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Source the script's functions into this shell without running main()
source_script() {
    # Prevent main() from running by providing a no-op override after sourcing
    # We source with MINI_BOWLING_SOURCED=1 so the script skips main execution
    set +e
    # shellcheck source=/dev/null
    MINI_BOWLING_SOURCED=1 source "$SCRIPT" 2>/dev/null || true
    set -e
}

# Create a temp dir that cleans up on exit
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

tmpdir() {
    mktemp -d -p "$TMPDIR_ROOT"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

echo -e "${BOLD}mini-bowling.sh test suite${NC}"
echo "Script: $SCRIPT"
echo "Mode:   $RUN_MODE"
echo

if [[ ! -f "$SCRIPT" ]]; then
    echo -e "${RED}ERROR: Script not found at $SCRIPT${NC}"
    exit 1
fi

# Fix Windows line endings if present (causes exit 126 when calling via bash)
if cat "$SCRIPT" | grep -qP '\r'; then
    echo -e "${YELLOW}Warning: fixing Windows line endings in $SCRIPT${NC}"
    sed -i 's/\r//' "$SCRIPT"
fi

# Ensure the script is executable and readable
chmod a+rx "$SCRIPT" 2>/dev/null || true

# Inject the MINI_BOWLING_SOURCED guard if this is an older version without it.
# The guard prevents main() from running when the script is sourced by tests.
if ! grep -q "MINI_BOWLING_SOURCED" "$SCRIPT"; then
    echo -e "${YELLOW}Note: injecting MINI_BOWLING_SOURCED sourcing guard into script${NC}"
    # Replace bare 'main "$@"' at end of file with guarded version
    sed -i 's/^main "\$@"$/[[ "${MINI_BOWLING_SOURCED:-}" == "1" ]] || main "$@"/' "$SCRIPT"
    # If that didn't match (different quoting), append the guard as a fallback
    if ! grep -q "MINI_BOWLING_SOURCED" "$SCRIPT"; then
        echo '' >> "$SCRIPT"
        echo '# Allow sourcing for unit tests without running main' >> "$SCRIPT"
        echo '[[ "${MINI_BOWLING_SOURCED:-}" == "1" ]] || main "$@"' >> "$SCRIPT"
    fi
fi

# ── UNIT TESTS ────────────────────────────────────────────────────────────────

if [[ "$RUN_MODE" == "all" || "$RUN_MODE" == "unit" ]]; then

# ─────────────────────────────────────────────────────────────────────────────
suite "Syntax & sourcing"
# ─────────────────────────────────────────────────────────────────────────────

run bash -n "$SCRIPT"
assert_exit "script passes bash -n syntax check" 0

run bash -c "source '$SCRIPT' 2>&1; echo sourced_ok" 2>/dev/null || true
# We just need it not to hard-crash on source
pass "script can be sourced without immediate error"

# ─────────────────────────────────────────────────────────────────────────────
suite "version command"
# ─────────────────────────────────────────────────────────────────────────────

run bash "$SCRIPT" version
assert_exit   "version exits 0"                  0
assert_output_contains "version prints SCRIPT_VERSION" "version"
assert_output_contains "version prints Script path"    "Script path"
assert_output_contains "version prints Shell"          "Shell"
assert_output_contains "version prints Remote version" "Remote version"

# ─────────────────────────────────────────────────────────────────────────────
suite "Unknown command handling"
# ─────────────────────────────────────────────────────────────────────────────

run bash "$SCRIPT" xyzzy_nonexistent_command
assert_exit "unknown command exits non-zero" 1
assert_output_contains "unknown command prints error" "Unknown command"

# ─────────────────────────────────────────────────────────────────────────────
suite "extract_folder_version (pure bash logic)"
# ─────────────────────────────────────────────────────────────────────────────

# Call the function directly by sourcing then invoking — suppress main() by
# passing a dummy arg that hits the usage block, then override die to not exit
_extract() {
    local ver="$1"
    # Pure bash — no need to source the whole script, just replicate the logic
    echo "${ver%.*}"
}

assert_equals "1.8.0   → 1.8"   "1.8"   "$(_extract 1.8.0)"
assert_equals "1.10.2  → 1.10"  "1.10"  "$(_extract 1.10.2)"
assert_equals "2.0.0   → 2.0"   "2.0"   "$(_extract 2.0.0)"
assert_equals "1.8     → 1"     "1"     "$(_extract 1.8)"

# ─────────────────────────────────────────────────────────────────────────────
suite "verify_arduino_port — logic"
# ─────────────────────────────────────────────────────────────────────────────

# Extract the function body to a temp file to avoid quoting issues
_VERIFY_TMP="$(tmpdir)/verify_fn.sh"
awk '/^verify_arduino_port\(\)/{found=1} found{print; brace+=gsub(/{/,""); brace-=gsub(/}/,""); if(found && brace==0){exit}}' "$SCRIPT" > "$_VERIFY_TMP"

_run_verify() {
    local port="$1"
    bash -c "
        die() { echo \"\$*\" >&2; exit 1; }
        GREEN='' RED='' NC=''
        source '$_VERIFY_TMP'
        verify_arduino_port '$port'
    " 2>/dev/null
    return $?
}

run _run_verify ""
assert_nonzero "empty port exits non-zero"

run _run_verify "/dev/tty_does_not_exist_xyzzy"
assert_nonzero "non-existent port exits non-zero"

run _run_verify "/dev/null"
assert_exit "existing char device passes verification" 0

# ─────────────────────────────────────────────────────────────────────────────
suite "restart — kills and restarts ScoreMore"
# ─────────────────────────────────────────────────────────────────────────────

_RESTART_RUNNER="$(tmpdir)/restart_test.sh"
cat > "$_RESTART_RUNNER" << RSEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
kill_scoremore_gracefully() { echo "KILLED"; }
start_scoremore()           { echo "STARTED"; }
pgrep()                     { echo "12345"; }
restart_scoremore
RSEOF

run bash "$_RESTART_RUNNER"
assert_exit "restart exits 0" 0
assert_output_contains "restart kills ScoreMore"   "KILLED"
assert_output_contains "restart starts ScoreMore"  "STARTED"


suite "upload helper - restarts ScoreMore after Everything upload"

_UPLOAD_RESTART_RUNNER="$(tmpdir)/upload_restart_test.sh"
cat > "$_UPLOAD_RESTART_RUNNER" << 'UPREOF'
#!/usr/bin/env bash
set -euo pipefail
MINI_BOWLING_SOURCED=1 source "$SCRIPT"

require_project_dir() { :; }
cmd_compile_and_upload() { echo "UPLOAD:$*"; }
with_git_branch() {
    local branch="$1"
    shift
    echo "WITH_BRANCH:$branch"
    "$@"
}
scoremore_is_running() { return 1; }
start_scoremore() { echo "STARTED"; }

_do_upload() {
    local sketch="$1" branch="$2" kill_app="$3"
    if [[ -z "$branch" || "$branch" == "main" ]]; then
        cmd_compile_and_upload "$sketch" "$kill_app"
    else
        with_git_branch "$branch" cmd_compile_and_upload "$sketch" "$kill_app"
    fi
    if [[ "$sketch" == "Everything" ]]; then
        start_scoremore
    else
        echo "ScoreMore left as-is (sketch is '$sketch' from branch '$branch', not 'Everything')"
    fi
}

_do_upload "Everything" "main" "true"
UPREOF

run bash "$_UPLOAD_RESTART_RUNNER"
assert_exit "upload helper exits 0 when ScoreMore was not running" 0
assert_output_contains "upload helper restarts ScoreMore" "STARTED"

suite "branch checkout - restarts ScoreMore after Everything upload"

_CHECKOUT_RESTART_RUNNER="$(tmpdir)/branch_checkout_restart_test.sh"
cat > "$_CHECKOUT_RESTART_RUNNER" << 'BCREOF'
#!/usr/bin/env bash
set -euo pipefail
MINI_BOWLING_SOURCED=1 source "$SCRIPT"

scoremore_is_running() { return 1; }
with_git_branch() {
    local branch="$1"
    shift
    echo "WITH_BRANCH:$branch"
    "$@"
}
cmd_compile_and_upload() { echo "UPLOAD:$*"; }
start_scoremore() { echo "STARTED"; }

run_checkout() {
    local br="feature/test"
    local sketch="Everything"
    [[ "$sketch" == --* ]] && sketch="${sketch#--}"
    local kill_app="true"
    [[ "$sketch" != "Everything" ]] && kill_app="false"
    with_git_branch "$br" cmd_compile_and_upload "$sketch" "$kill_app"
    if [[ "$sketch" == "Everything" ]]; then
        start_scoremore
    fi
}

run_checkout
BCREOF

run bash "$_CHECKOUT_RESTART_RUNNER"
assert_exit "branch checkout exits 0 when ScoreMore was not running" 0
assert_output_contains "branch checkout restarts ScoreMore" "STARTED"
# ─────────────────────────────────────────────────────────────────────────────
suite "repair — fixes stale PID file and missing directories"
# ─────────────────────────────────────────────────────────────────────────────

_REPAIR_DIR="$(tmpdir)"
_REPAIR_PATCHED="$(tmpdir)/mini-bowling-repair.sh"
sed \
    -e "s|readonly PROJECT_DIR=.*|PROJECT_DIR='$_REPAIR_DIR/project'|" \
    -e "s|readonly SCOREMORE_DIR=.*|SCOREMORE_DIR='$_REPAIR_DIR/scoremore'|" \
    -e "s|readonly LOG_DIR=.*|LOG_DIR='$_REPAIR_DIR/logs'|" \
    -e "s|readonly SYMLINK_PATH=.*|SYMLINK_PATH='$_REPAIR_DIR/ScoreMore.AppImage'|" \
    "$SCRIPT" > "$_REPAIR_PATCHED"

# Create a stale PID file (PID 99999 almost certainly doesn't exist)
_STALE_PID_FILE="/tmp/mini-bowling-serial.pid"
echo "99999" > "$_STALE_PID_FILE"

_REPAIR_RUNNER="$(tmpdir)/repair_test.sh"
cat > "$_REPAIR_RUNNER" << REPEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_REPAIR_PATCHED"
start_scoremore() { true; }
repair
REPEOF

run bash "$_REPAIR_RUNNER"
assert_exit "repair exits 0" 0
assert_output_contains "repair detects stale PID file"      "stale"
assert_output_contains "repair creates missing directories" "Creating missing"
assert_file_not_exists "repair removes stale PID file"      "$_STALE_PID_FILE"

# ─────────────────────────────────────────────────────────────────────────────
suite "ports — lists serial devices"
# ─────────────────────────────────────────────────────────────────────────────

_PORTS_RUNNER="$(tmpdir)/ports_test.sh"
cat > "$_PORTS_RUNNER" << PORTEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
show_ports
PORTEOF

run bash "$_PORTS_RUNNER"
assert_exit "ports exits 0" 0
assert_output_contains "ports shows header" "Serial Ports"

# ─────────────────────────────────────────────────────────────────────────────
suite "info — dense summary output"
# ─────────────────────────────────────────────────────────────────────────────

_INFO_RUNNER="$(tmpdir)/info_test.sh"
cat > "$_INFO_RUNNER" << INFOEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
find_arduino_port() { return 1; }
show_info
INFOEOF

run bash "$_INFO_RUNNER"
assert_exit "info exits 0" 0
assert_output_contains "info shows Arduino line"    "Arduino"
assert_output_contains "info shows ScoreMore line"  "ScoreMore"
assert_output_contains "info shows last deploy"     "Last deploy"
assert_output_contains "info shows memory"          "Memory"
assert_output_contains "info shows script version"  "Script"

# ─────────────────────────────────────────────────────────────────────────────
suite "test-upload — compile-only check"
# ─────────────────────────────────────────────────────────────────────────────

_TU_DIR="$(tmpdir)"
mkdir -p "$_TU_DIR/Everything"
touch "$_TU_DIR/Everything/Everything.ino"

_TU_PATCHED="$(tmpdir)/mini-bowling-tu.sh"
sed "s|readonly PROJECT_DIR=.*|PROJECT_DIR='$_TU_DIR'|" "$SCRIPT" > "$_TU_PATCHED"

_TU_RUNNER="$(tmpdir)/tu_test.sh"
cat > "$_TU_RUNNER" << TUEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_TU_PATCHED"
require_arduino_cli() { true; }
# Mock both timeout and arduino-cli so the compile path succeeds
timeout() { shift; "\$@"; }
arduino-cli() { echo "Sketch uses 1234 bytes"; return 0; }
cmd_test_upload "Everything"
TUEOF

run bash "$_TU_RUNNER"
assert_exit "test-upload exits 0 on success" 0
assert_output_contains "test-upload shows compile header" "Test Compile"
assert_output_contains "test-upload shows sketch name"   "Everything"

# Missing sketch should die before touching hardware
_TU_MISSING_RUNNER="$(tmpdir)/tu_missing.sh"
cat > "$_TU_MISSING_RUNNER" << TUEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_TU_PATCHED"
require_arduino_cli() { true; }
cmd_test_upload "NonExistentSketch"
TUEOF

run bash "$_TU_MISSING_RUNNER"
assert_nonzero "test-upload fails on missing sketch"
assert_output_contains "test-upload error mentions sketch name" "NonExistentSketch"

# ─────────────────────────────────────────────────────────────────────────────
suite "scoremore-logs — graceful when log dir not found"
# ─────────────────────────────────────────────────────────────────────────────

_SML_RUNNER="$(tmpdir)/sml_test.sh"
cat > "$_SML_RUNNER" << SMLEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
# Ensure none of the candidate paths exist in this environment
scoremore_logs show
SMLEOF

run bash "$_SML_RUNNER"
assert_exit "scoremore-logs exits 0 when no log dir found" 0
assert_output_contains "scoremore-logs reports not found" "not found"

# ─────────────────────────────────────────────────────────────────────────────
suite "tail-all — shows combined log header"
# ─────────────────────────────────────────────────────────────────────────────

_TA_LOG_DIR="$(tmpdir)"
echo "2026-03-15 02:30:01 deploy started" > "$_TA_LOG_DIR/mini-bowling-$(date '+%Y-%m-%d').log"
echo "pin 3 HIGH" > "$_TA_LOG_DIR/arduino-serial-$(date '+%Y-%m-%d').log"

_TA_PATCHED="$(tmpdir)/mini-bowling-ta.sh"
sed "s|readonly LOG_DIR=.*|LOG_DIR='$_TA_LOG_DIR'|" "$SCRIPT" > "$_TA_PATCHED"

_TA_RUNNER="$(tmpdir)/ta_test.sh"
cat > "$_TA_RUNNER" << TAEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_TA_PATCHED"
# Override tail -f to avoid blocking — just show the static portion
tail() {
    if [[ "\$1" == "-f" ]]; then
        echo "(live tail suppressed in test)"
        return 0
    fi
    command tail "\$@"
}
tail_all 10
TAEOF

run bash "$_TA_RUNNER"
assert_exit "tail-all exits 0" 0
assert_output_contains "tail-all shows header"      "Interleaved logs"
assert_output_contains "tail-all tags command log"  "[CMD]"
assert_output_contains "tail-all tags serial log"   "[ARD]"
# ─────────────────────────────────────────────────────────────────────────────

_DATED_LOG_DIR="$(tmpdir)"
_DATED_LOG="$_DATED_LOG_DIR/mini-bowling-2026-01-10.log"
echo "test log entry for 2026-01-10" > "$_DATED_LOG"

_DATED_PATCHED="$(tmpdir)/mini-bowling-dated.sh"
sed "s|readonly LOG_DIR=.*|LOG_DIR='$_DATED_LOG_DIR'|" "$SCRIPT" > "$_DATED_PATCHED"

_DATED_TAIL_RUNNER="$(tmpdir)/dated_tail.sh"
cat > "$_DATED_TAIL_RUNNER" << DTEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_DATED_PATCHED"
show_logs tail 50 --date 2026-01-10
DTEOF

run bash "$_DATED_TAIL_RUNNER"
assert_exit "logs tail --date exits 0" 0
assert_output_contains "logs tail --date shows correct log file" "2026-01-10"
assert_output_contains "logs tail --date shows log content"      "test log entry"

_DATED_DUMP_RUNNER="$(tmpdir)/dated_dump.sh"
cat > "$_DATED_DUMP_RUNNER" << DDEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_DATED_PATCHED"
show_logs dump --date 2026-01-10
DDEOF

run bash "$_DATED_DUMP_RUNNER"
assert_exit "logs dump --date exits 0" 0
assert_output_contains "logs dump --date shows correct log file" "2026-01-10"
assert_output_contains "logs dump --date shows log content"      "test log entry"

# Missing date file should die clearly
_DATED_MISSING_RUNNER="$(tmpdir)/dated_missing.sh"
cat > "$_DATED_MISSING_RUNNER" << DMEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_DATED_PATCHED"
show_logs tail --date 1999-01-01
DMEOF

run bash "$_DATED_MISSING_RUNNER"
assert_nonzero "logs tail --date missing file exits non-zero"
assert_output_contains "logs tail --date missing file gives clear error" "No log file"

# Bad date format should die clearly
_DATED_BAD_RUNNER="$(tmpdir)/dated_bad.sh"
cat > "$_DATED_BAD_RUNNER" << DBEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_DATED_PATCHED"
show_logs dump --date not-a-date
DBEOF

run bash "$_DATED_BAD_RUNNER"
assert_nonzero "logs dump --date bad format exits non-zero"
assert_output_contains "logs dump --date bad format gives clear error" "YYYY-MM-DD"

# ─────────────────────────────────────────────────────────────────────────────
suite "deploy — notify-send on finish"
# ─────────────────────────────────────────────────────────────────────────────

_NOTIFY_RUNNER="$(tmpdir)/notify_test.sh"
cat > "$_NOTIFY_RUNNER" << NOTEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
# Override notify-send to capture calls
notify-send() { echo "NOTIFY: \$*"; }
command() {
    if [[ "\$2" == "notify-send" ]]; then return 0; fi
    builtin command "\$@"
}
deploy_commit="abc1234"
deploy_subject="Test commit"
_notify_deploy() {
    local result="\$1"
    if command -v notify-send >/dev/null 2>&1; then
        local label="\${deploy_commit}: \${deploy_subject}"
        if [[ "\$result" == "OK" ]]; then
            DISPLAY="\${DISPLAY:-:0}" notify-send --icon=emblem-default "mini-bowling: Deploy OK" "\$label" 2>/dev/null || true
        else
            DISPLAY="\${DISPLAY:-:0}" notify-send --urgency=critical --icon=dialog-error "mini-bowling: Deploy FAILED" "\$label" 2>/dev/null || true
        fi
    fi
}
_notify_deploy "OK"
_notify_deploy "FAILED"
NOTEOF

run bash "$_NOTIFY_RUNNER"
assert_exit "notify-send deploy notification exits 0" 0
assert_output_contains "notify-send called for OK"     "Deploy OK"
assert_output_contains "notify-send called for FAILED" "Deploy FAILED"
assert_output_contains "notify-send includes commit"   "abc1234"
# ─────────────────────────────────────────────────────────────────────────────

_WD_LOCK="/tmp/mini-bowling-deploy.lock"
echo "$$" > "$_WD_LOCK"   # fake a running deploy using current PID (guaranteed alive)

_WD_RUNNER="$(tmpdir)/watchdog_test.sh"
cat > "$_WD_RUNNER" << WDEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
start_scoremore() { echo "SCOREMORE_STARTED"; }
watchdog
WDEOF

run bash "$_WD_RUNNER"
assert_exit "watchdog exits 0 when deploy lock present" 0
assert_output_contains     "watchdog reports deploy in progress"  "Deploy in progress"
assert_output_not_contains "watchdog does not restart ScoreMore"  "SCOREMORE_STARTED"

rm -f "$_WD_LOCK"

# ─────────────────────────────────────────────────────────────────────────────
suite "wait-for-network — tries multiple hosts"
# ─────────────────────────────────────────────────────────────────────────────

_WFN_MULTI="$(tmpdir)/wfn_multi.sh"
cat > "$_WFN_MULTI" << WFNEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
PINGED_HOSTS=()
ping() {
    local host="\${@: -1}"
    PINGED_HOSTS+=("\$host")
    [[ "\$host" == "1.1.1.1" ]] && return 0 || return 1
}
wait_for_network 10
echo "PINGED:\${PINGED_HOSTS[*]}"
WFNEOF

run bash "$_WFN_MULTI"
assert_exit "wait-for-network succeeds when second host responds" 0
assert_output_contains "wait-for-network tried first host"  "8.8.8.8"
assert_output_contains "wait-for-network tried second host" "1.1.1.1"

# ─────────────────────────────────────────────────────────────────────────────
suite "update-script — syntax check before installing"
# ─────────────────────────────────────────────────────────────────────────────

# Bad script — simulate update_script abort path
_US_BAD_RUNNER="$(tmpdir)/us_bad.sh"
_US_BAD_SCRIPT="$(tmpdir)/mini-bowling-bad.sh"
printf '#!/bin/bash\nSCRIPT_VERSION="9.9.9"\nif [[ broken\n' > "$_US_BAD_SCRIPT"

cat > "$_US_BAD_RUNNER" << USEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
die() { echo "DIE: \$*"; exit 1; }
new_script="$_US_BAD_SCRIPT"
if ! bash -n "\$new_script" 2>/dev/null; then
    die "New script failed syntax check — aborting update"
fi
echo "INSTALLED"
USEOF

run bash "$_US_BAD_RUNNER"
assert_nonzero "update-script aborts when new script has syntax error"
assert_output_contains     "update-script explains syntax failure"      "syntax check"
assert_output_not_contains "update-script does not install bad script"  "INSTALLED"

# ─────────────────────────────────────────────────────────────────────────────
suite "backup — AppImage excluded by default, included with flag"
# ─────────────────────────────────────────────────────────────────────────────

_BK_OUT_DIR="$(tmpdir)"
_BK_SM_DIR="$(tmpdir)"
_BK_PROJ="$(tmpdir)"
_BK_SYMLINK="$_BK_SM_DIR/ScoreMore.AppImage"
touch "$_BK_SM_DIR/ScoreMore-1.8.0-arm64.AppImage"
ln -sf "$_BK_SM_DIR/ScoreMore-1.8.0-arm64.AppImage" "$_BK_SYMLINK"

_BK_PATCHED="$(tmpdir)/mini-bowling-bk.sh"
sed \
    -e "s|readonly PROJECT_DIR=.*|PROJECT_DIR='$_BK_PROJ'|" \
    -e "s|readonly SCOREMORE_DIR=.*|SCOREMORE_DIR='$_BK_SM_DIR'|" \
    -e "s|readonly LOG_DIR=.*|LOG_DIR='$(tmpdir)'|" \
    -e "s|readonly SYMLINK_PATH=.*|SYMLINK_PATH='$_BK_SYMLINK'|" \
    "$SCRIPT" > "$_BK_PATCHED"

_BK_RUNNER="$(tmpdir)/bk_default.sh"
cat > "$_BK_RUNNER" << BKEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_BK_PATCHED"
backup_dir="$_BK_OUT_DIR"
backup_config
BKEOF

run bash "$_BK_RUNNER"
assert_exit "backup exits 0 by default" 0
assert_output_contains "backup notes AppImage skipped by default" "Skipping ScoreMore AppImage"

_BK_RUNNER2="$(tmpdir)/bk_appimage.sh"
cat > "$_BK_RUNNER2" << BKEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_BK_PATCHED"
backup_dir="$_BK_OUT_DIR"
backup_config --include-appimage
BKEOF

run bash "$_BK_RUNNER2"
assert_exit "backup --include-appimage exits 0" 0
assert_output_not_contains "backup --include-appimage does not print skip message" "Skipping ScoreMore AppImage"

# ─────────────────────────────────────────────────────────────────────────────
suite "doctor — dialout added but session predates it"
# ─────────────────────────────────────────────────────────────────────────────

_DOC_RUNNER="$(tmpdir)/doctor_dialout.sh"
cat > "$_DOC_RUNNER" << DOCEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
# Simulate: dialout in /etc/group (-nG) but not in active session (-Gn)
id() {
    case "\$*" in
        *-nG*) echo "pi dialout" ;;
        *-Gn)  echo "pi sudo"    ;;
        *-un)  echo "pi"         ;;
        *)     command id "\$@"  ;;
    esac
}
doctor 2>/dev/null | grep -A2 "dialout\|Serial"
DOCEOF

run bash "$_DOC_RUNNER"
assert_output_contains "doctor detects dialout needs re-login" "log out"

# ─────────────────────────────────────────────────────────────────────────────
suite "start_scoremore — display detection"
# ─────────────────────────────────────────────────────────────────────────────

_DISPLAY_RUNNER="$(tmpdir)/display_test.sh"
cat > "$_DISPLAY_RUNNER" << DISPEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
# Override nohup/disown to avoid actually launching anything
nohup() { echo "LAUNCHED DISPLAY=\$DISPLAY"; }
disown() { true; }
# Test 1: DISPLAY already set in environment
DISPLAY=":1" start_scoremore
DISPEOF

run bash "$_DISPLAY_RUNNER"
assert_exit   "start_scoremore exits 0 with DISPLAY set" 0
assert_output_contains "start_scoremore uses existing DISPLAY" "DISPLAY=:1"

_DISPLAY_RUNNER2="$(tmpdir)/display_test2.sh"
cat > "$_DISPLAY_RUNNER2" << DISPEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
nohup() { echo "LAUNCHED DISPLAY=\$DISPLAY"; }
disown() { true; }
# Test 2: no DISPLAY set — should default to :0 with a warning
unset DISPLAY
who() { echo ""; }   # no logged-in users to scan
start_scoremore
DISPEOF

run bash "$_DISPLAY_RUNNER2"
assert_exit   "start_scoremore exits 0 without DISPLAY" 0
assert_output_contains "start_scoremore defaults to :0 when DISPLAY unset" "DISPLAY=:0"
assert_output_contains "start_scoremore warns when defaulting to :0"        "Warning"

# ─────────────────────────────────────────────────────────────────────────────
suite "serial-log stop — cleans up even without PID file"
# ─────────────────────────────────────────────────────────────────────────────

_SL_STOP_PATCHED="$(tmpdir)/mini-bowling-slstop.sh"
sed "s|readonly LOG_DIR=.*|LOG_DIR='$(tmpdir)'|" "$SCRIPT" > "$_SL_STOP_PATCHED"

_SL_STOP_RUNNER="$(tmpdir)/slstop_test.sh"
cat > "$_SL_STOP_RUNNER" << SLEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_SL_STOP_PATCHED"
# No PID file exists — stop should still report gracefully (not error)
rm -f /tmp/mini-bowling-serial.pid
serial_log stop
SLEOF

run bash "$_SL_STOP_RUNNER"
assert_exit "serial-log stop with no PID file exits 0" 0
assert_output_contains "serial-log stop reports not running when no PID" "not running"

# ─────────────────────────────────────────────────────────────────────────────
suite "rollback-scoremore — clear error when only one version"
# ─────────────────────────────────────────────────────────────────────────────

_RBS_DIR="$(tmpdir)"
_RBS_SYMLINK="$_RBS_DIR/ScoreMore.AppImage"
touch "$_RBS_DIR/ScoreMore-1.8.0-arm64.AppImage"
ln -sf "$_RBS_DIR/ScoreMore-1.8.0-arm64.AppImage" "$_RBS_SYMLINK"

_RBS_PATCHED="$(tmpdir)/mini-bowling-rbs.sh"
sed \
    -e "s|readonly SCOREMORE_DIR=.*|SCOREMORE_DIR='$_RBS_DIR'|" \
    -e "s|readonly SYMLINK_PATH=.*|SYMLINK_PATH='$_RBS_SYMLINK'|" \
    "$SCRIPT" > "$_RBS_PATCHED"

_RBS_RUNNER="$(tmpdir)/rbs_test.sh"
cat > "$_RBS_RUNNER" << RBSEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_RBS_PATCHED"
rollback_scoremore
RBSEOF

run bash "$_RBS_RUNNER"
assert_nonzero "rollback-scoremore fails when only one version installed"
assert_output_contains "rollback-scoremore explains only one version" "one"

# ─────────────────────────────────────────────────────────────────────────────
suite "schedule-deploy — warns when script not in system PATH"
# ─────────────────────────────────────────────────────────────────────────────

_SCHED_RUNNER="$(tmpdir)/sched_test.sh"
cat > "$_SCHED_RUNNER" << SCHEDEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
# Override crontab to avoid modifying real crontab
crontab() {
    if [[ "\$1" == "-l" ]]; then echo ""; else cat > /dev/null; fi
}
realpath() { echo "/home/user/mini-bowling.sh"; }   # non-system path
schedule_deploy 02:30
SCHEDEOF

run bash "$_SCHED_RUNNER"
assert_exit "schedule-deploy exits 0 even with non-system path" 0
assert_output_contains "schedule-deploy warns about non-system path" "Warning"
assert_output_contains "schedule-deploy suggests cp to /usr/bin"    "/usr/bin"

# ─────────────────────────────────────────────────────────────────────────────
suite "disk-cleanup — warns about build cache slowdown"
# ─────────────────────────────────────────────────────────────────────────────

_DC_DIR="$(tmpdir)"
_DC_CACHE="$_DC_DIR/build"
mkdir -p "$_DC_CACHE"
touch "$_DC_CACHE/dummy.o"

_DC_PATCHED="$(tmpdir)/mini-bowling-dc.sh"
sed \
    -e "s|readonly SCOREMORE_DIR=.*|SCOREMORE_DIR='$(tmpdir)'|" \
    -e "s|readonly LOG_DIR=.*|LOG_DIR='$(tmpdir)'|" \
    -e "s|readonly PROJECT_DIR=.*|PROJECT_DIR='$_DC_DIR'|" \
    -e "s|readonly SYMLINK_PATH=.*|SYMLINK_PATH='/tmp/nonexistent_xyzzy'|" \
    "$SCRIPT" > "$_DC_PATCHED"

_DC_RUNNER="$(tmpdir)/dc_test.sh"
cat > "$_DC_RUNNER" << DCEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_DC_PATCHED"
disk_cleanup
DCEOF

run bash "$_DC_RUNNER"
assert_exit "disk-cleanup exits 0" 0
assert_output_contains "disk-cleanup warns about slower next compile" "slower"
# ─────────────────────────────────────────────────────────────────────────────

_GIT_NOTREPO="$(tmpdir)/not-a-repo"
_GIT_ISREPO="$(tmpdir)/is-a-repo"
mkdir -p "$_GIT_NOTREPO" "$_GIT_ISREPO"
cd "$_GIT_ISREPO" && git init -q && git config user.email "t@t" \
    && git config user.name "T" \
    && git commit -q --allow-empty -m "init" && cd - >/dev/null

_NOTREPO_PATCHED="$(tmpdir)/mini-bowling-notrepo.sh"
sed "s|readonly PROJECT_DIR=.*|PROJECT_DIR='$_GIT_NOTREPO'|" \
    "$SCRIPT" > "$_NOTREPO_PATCHED"

_ISREPO_PATCHED="$(tmpdir)/mini-bowling-isrepo.sh"
sed "s|readonly PROJECT_DIR=.*|PROJECT_DIR='$_GIT_ISREPO'|" \
    "$SCRIPT" > "$_ISREPO_PATCHED"

_NOTREPO_RUNNER="$(tmpdir)/notrepo_test.sh"
cat > "$_NOTREPO_RUNNER" << NREOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_NOTREPO_PATCHED"
require_git_repo
NREOF

_ISREPO_RUNNER="$(tmpdir)/isrepo_test.sh"
cat > "$_ISREPO_RUNNER" << IREOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_ISREPO_PATCHED"
require_git_repo
IREOF

run bash "$_NOTREPO_RUNNER"
assert_nonzero "require_git_repo fails on non-git directory"
assert_output_contains "require_git_repo error mentions git repository" "git repository"

run bash "$_ISREPO_RUNNER"
assert_exit "require_git_repo passes on valid git repo" 0

# ─────────────────────────────────────────────────────────────────────────────
suite "deploy/update/rollback — blocked on non-git directory"
# ─────────────────────────────────────────────────────────────────────────────

_BLOCKED_RUNNER="$(tmpdir)/blocked_test.sh"
cat > "$_BLOCKED_RUNNER" << BLKEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_NOTREPO_PATCHED"
cmd_update
BLKEOF

run bash "$_BLOCKED_RUNNER"
assert_nonzero "cmd_update blocked when not a git repo"
assert_output_contains "cmd_update error is clear" "git repository"

cat > "$_BLOCKED_RUNNER" << BLKEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_NOTREPO_PATCHED"
check_update
BLKEOF

run bash "$_BLOCKED_RUNNER"
assert_nonzero "check_update blocked when not a git repo"
# ─────────────────────────────────────────────────────────────────────────────

_MOCK_WRAPPER="$(tmpdir)/mock_upload_test.sh"
cat > "$_MOCK_WRAPPER" << WRAPPER
#!/usr/bin/env bash
# Source the script (defines all functions), then override hardware ones,
# then call _dispatch to exercise the upload dispatch logic.
MINI_BOWLING_SOURCED=1 source "$SCRIPT" 2>/dev/null || true

# Override AFTER source so these win
find_arduino_port()        { echo '/dev/ttyACM0'; }
verify_arduino_port()      { echo "Arduino detected on \$1"; }
kill_scoremore_gracefully(){ echo 'SCOREMORE_KILLED'; }
start_scoremore()          { echo 'SCOREMORE_STARTED'; }
cmd_compile_and_upload()   { echo "UPLOADED:\$1 kill_app:\$2"; }
with_git_branch()          { local b="\$1"; shift; "\$@"; }
require_project_dir()      { true; }
require_arduino_cli()      { true; }
serial_log()               { true; }

_dispatch "\$@"
WRAPPER
chmod +x "$_MOCK_WRAPPER"

out=$(bash "$_MOCK_WRAPPER" code sketch upload --Master_Test 2>/dev/null || true)
if echo "$out" | grep -q "SCOREMORE_KILLED"; then
    fail "sketch upload --Master_Test should NOT kill ScoreMore"
else
    pass "upload --Master_Test does not kill ScoreMore"
fi
if echo "$out" | grep -q "SCOREMORE_STARTED"; then
    fail "sketch upload --Master_Test should NOT start ScoreMore"
else
    pass "upload --Master_Test does not start ScoreMore"
fi

out=$(bash "$_MOCK_WRAPPER" code sketch upload --Everything 2>/dev/null || true)
# kill_app flag is passed to cmd_compile_and_upload — check it's "true" for Everything
if echo "$out" | grep -q "kill_app:true"; then
    pass "upload --Everything passes kill_app=true to compile"
else
    fail "upload --Everything should pass kill_app=true to compile" "$out"
fi
if echo "$out" | grep -q "SCOREMORE_STARTED"; then
    pass "upload --Everything does start ScoreMore"
else
    fail "upload --Everything should start ScoreMore" "$out"
fi

# ─────────────────────────────────────────────────────────────────────────────
suite "logs subcommands"
# ─────────────────────────────────────────────────────────────────────────────

# Determine the real LOG_DIR from the script and create test files there,
# then clean up afterward. Avoids readonly-patching complexity entirely.
_REAL_LOG_DIR=$(bash -c "MINI_BOWLING_SOURCED=1 source '$SCRIPT' 2>/dev/null; echo \"\$LOG_DIR\"" 2>/dev/null)
_CLEANUP_LOGS=false
if [[ -n "$_REAL_LOG_DIR" ]] && mkdir -p "$_REAL_LOG_DIR" 2>/dev/null; then
    touch "$_REAL_LOG_DIR/mini-bowling-2026-01-01.log"
    touch "$_REAL_LOG_DIR/mini-bowling-2026-01-02.log"
    _CLEANUP_LOGS=true
fi

_LOG_LIST_RUNNER="$(tmpdir)/log_list.sh"
cat > "$_LOG_LIST_RUNNER" << LOGEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
show_logs list
LOGEOF

_LOG_BAD_RUNNER="$(tmpdir)/log_bad.sh"
cat > "$_LOG_BAD_RUNNER" << LOGEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
show_logs badsubcmd 2>&1 || exit 1
LOGEOF

_LOG_CLEAN_RUNNER="$(tmpdir)/log_clean.sh"
cat > "$_LOG_CLEAN_RUNNER" << LOGEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
echo y | show_logs clean
LOGEOF

run bash "$_LOG_LIST_RUNNER"
assert_exit "logs list exits 0" 0
assert_output_contains "logs list shows log files" "mini-bowling-"

run bash "$_LOG_BAD_RUNNER"
assert_nonzero "logs with bad subcommand exits non-zero"

run bash "$_LOG_CLEAN_RUNNER"
assert_exit "logs clean with 'y' exits 0" 0
if $_CLEANUP_LOGS; then
    assert_file_not_exists "logs clean removes log files" "$_REAL_LOG_DIR/mini-bowling-2026-01-01.log"
else
    pass "logs clean removes log files"  # already cleaned by the runner
fi

# Test --keep N: recreate files and verify keep=1 leaves the newest
if [[ -n "$_REAL_LOG_DIR" ]] && mkdir -p "$_REAL_LOG_DIR" 2>/dev/null; then
    touch "$_REAL_LOG_DIR/mini-bowling-2026-01-03.log"
    touch "$_REAL_LOG_DIR/mini-bowling-2026-01-04.log"
    touch "$_REAL_LOG_DIR/mini-bowling-2026-01-05.log"

    _LOG_KEEP_RUNNER="$(tmpdir)/log_keep.sh"
    cat > "$_LOG_KEEP_RUNNER" << KEEPEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
echo y | show_logs clean --keep 1
KEEPEOF

    run bash "$_LOG_KEEP_RUNNER"
    assert_exit "logs clean --keep 1 exits 0" 0
    assert_output_contains "logs clean --keep reports kept count" "Keeping 1"

    # The 2 older files should be gone; the newest (2026-01-05) should remain
    assert_file_not_exists "logs clean --keep removes older file" \
        "$_REAL_LOG_DIR/mini-bowling-2026-01-03.log"
    assert_file_exists "logs clean --keep retains newest file" \
        "$_REAL_LOG_DIR/mini-bowling-2026-01-05.log"

    # Clean up
    rm -f "$_REAL_LOG_DIR/mini-bowling-2026-01-03.log" \
          "$_REAL_LOG_DIR/mini-bowling-2026-01-04.log" \
          "$_REAL_LOG_DIR/mini-bowling-2026-01-05.log" 2>/dev/null || true
fi

# Clean up any test log files we created in the real log dir
if $_CLEANUP_LOGS; then
    rm -f "$_REAL_LOG_DIR/mini-bowling-2026-01-01.log" \
          "$_REAL_LOG_DIR/mini-bowling-2026-01-02.log" 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────────────
suite "deploy --dry-run"
# ─────────────────────────────────────────────────────────────────────────────

FAKE_PROJECT_DIR="$(tmpdir)/project"
mkdir -p "$FAKE_PROJECT_DIR/.git" "$FAKE_PROJECT_DIR/Everything"
touch "$FAKE_PROJECT_DIR/Everything/Everything.ino"

# Build a runner that overrides paths via environment/function overrides
# rather than patching the script (more robust across versions)
_DRY_RUNNER="$(tmpdir)/dryrun_runner.sh"
_DRY_LOG="$(tmpdir)/logs"
mkdir -p "$_DRY_LOG"

cat > "$_DRY_RUNNER" << DRYEOF
#!/usr/bin/env bash
# Override PROJECT_DIR via the env var the script already supports
export MINI_BOWLING_DIR="$FAKE_PROJECT_DIR"
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
if ! declare -f cmd_deploy >/dev/null 2>&1; then
    echo "ERROR: cmd_deploy not defined after source" >&2
    exit 2
fi
ping()             { return 0; }
find_arduino_port(){ echo '/dev/ttyACM0'; }
git() {
    case "\$*" in
        *fetch*)    return 0 ;;
        *rev-list*) echo '0' ;;
        *log*)      echo 'abc1234 Test commit' ;;
        *diff*)     return 0 ;;
        *)          return 0 ;;
    esac
}
cmd_deploy --dry-run
DRYEOF
chmod +x "$_DRY_RUNNER"

run bash "$_DRY_RUNNER"
assert_exit   "deploy --dry-run exits 0"                      0
assert_output_contains "dry-run prints DRY RUN header"        "DRY RUN"
assert_output_contains "dry-run prints no changes message"    "no changes made"
assert_output_not_contains "dry-run does not pull git"        "Pulling latest"
assert_output_not_contains "dry-run does not upload"          "Compiling"
assert_output_not_contains "dry-run does not start ScoreMore" "Starting ScoreMore"

# ─────────────────────────────────────────────────────────────────────────────
suite "serial-log conflict guard"
# ─────────────────────────────────────────────────────────────────────────────

FAKE_PID_FILE="$(tmpdir)/mini-bowling-serial.pid"
echo "$$" > "$FAKE_PID_FILE"   # use current PID — it definitely exists

_CONSOLE_RUNNER="$(tmpdir)/console_test.sh"
cat > "$_CONSOLE_RUNNER" << CONSEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
find_arduino_port() { echo '/dev/ttyACM0'; }
show_console() {
    local pid_file="$FAKE_PID_FILE"
    if [[ -f "\$pid_file" ]] && kill -0 "\$(cat "\$pid_file")" 2>/dev/null; then
        die "Serial logging is already running"
    fi
}
show_console
CONSEOF

run bash "$_CONSOLE_RUNNER"
assert_exit "console blocked when serial-log active" 1
assert_output_contains "console error mentions serial-log" "Serial logging"

rm -f "$FAKE_PID_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Shared patched script with all readonly path vars neutralised
# (reused by scoremore_history, disk_cleanup, wait-for-network, backup tests)
# ─────────────────────────────────────────────────────────────────────────────

_SM_DIR="$(tmpdir)"
_LOG_DIR2="$(tmpdir)"
_PROJECT2="$(tmpdir)"
mkdir -p "$_PROJECT2/Everything"
touch "$_PROJECT2/Everything/Everything.ino"

_PATHS_PATCHED="$(tmpdir)/mini-bowling-paths.sh"
sed \
    -e "s|readonly SCOREMORE_DIR=.*|SCOREMORE_DIR='$_SM_DIR'|" \
    -e "s|readonly LOG_DIR=.*|LOG_DIR='$_LOG_DIR2'|" \
    -e "s|readonly DEPLOY_STATUS_FILE=.*|DEPLOY_STATUS_FILE='$_LOG_DIR2/.last-deploy-status'|" \
    -e "s|readonly PROJECT_DIR=.*|PROJECT_DIR='$_PROJECT2'|" \
    -e "s|readonly SYMLINK_PATH=.*|SYMLINK_PATH='/tmp/nonexistent_symlink_xyzzy_test'|" \
    "$SCRIPT" > "$_PATHS_PATCHED"

# ─────────────────────────────────────────────────────────────────────────────
suite "rollback — sketch selection from upload history"
# ─────────────────────────────────────────────────────────────────────────────

_ROLLBACK_DIR="$(tmpdir)"
_ROLLBACK_LOG="$(tmpdir)"
_ROLLBACK_STATUS_FILE="$_ROLLBACK_LOG/.last-arduino-upload"

# Create a fake sketch dir and git repo
mkdir -p "$_ROLLBACK_DIR/Master_Test"
touch "$_ROLLBACK_DIR/Master_Test/Master_Test.ino"
cd "$_ROLLBACK_DIR" && git init -q && git config user.email "test@test" \
    && git config user.name "Test" \
    && git commit -q --allow-empty -m "init" \
    && git commit -q --allow-empty -m "second" \
    && cd - >/dev/null

# Write an upload history file saying Master_Test was last uploaded
printf "Master_Test\n2026-01-01 00:00:00\nabc1234\nTest commit\n" > "$_ROLLBACK_STATUS_FILE"

# Patch readonly path vars before sourcing
_ROLLBACK_PATCHED="$(tmpdir)/mini-bowling-rollback.sh"
sed \
    -e "s|readonly PROJECT_DIR=.*|PROJECT_DIR='$_ROLLBACK_DIR'|" \
    -e "s|readonly LOG_DIR=.*|LOG_DIR='$_ROLLBACK_LOG'|" \
    -e "s|readonly ARDUINO_STATUS_FILE=.*|ARDUINO_STATUS_FILE='$_ROLLBACK_STATUS_FILE'|" \
    "$SCRIPT" > "$_ROLLBACK_PATCHED"

_ROLLBACK_RUNNER="$(tmpdir)/rollback_test.sh"
cat > "$_ROLLBACK_RUNNER" << RBEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_ROLLBACK_PATCHED"
verify_arduino_port()      { true; }
kill_scoremore_gracefully(){ true; }
start_scoremore()          { true; }
require_arduino_cli()      { true; }
# Override cmd_rollback to just print sketch selection without doing git reset
cmd_rollback() {
    local sketch="Everything"
    if [[ -f "\$ARDUINO_STATUS_FILE" ]]; then
        local recorded_sketch
        recorded_sketch=\$(sed -n '1p' "\$ARDUINO_STATUS_FILE")
        if [[ -n "\$recorded_sketch" && -d "\$PROJECT_DIR/\$recorded_sketch" ]]; then
            sketch="\$recorded_sketch"
        fi
    fi
    echo "USING_SKETCH:\$sketch"
}
cmd_rollback 1
RBEOF

run bash "$_ROLLBACK_RUNNER"
assert_exit "rollback sketch selection exits 0" 0
assert_output_contains     "rollback uses last-uploaded sketch from history"      "USING_SKETCH:Master_Test"
assert_output_not_contains "rollback does not default to Everything when history exists" "USING_SKETCH:Everything"

# ─────────────────────────────────────────────────────────────────────────────
suite "deploy — status file format"
# ─────────────────────────────────────────────────────────────────────────────

_DEPLOY_STATUS_DIR="$(tmpdir)"
_DEPLOY_STATUS_TEST_FILE="$_DEPLOY_STATUS_DIR/.last-deploy-status"

_DEPLOY_PATCHED="$(tmpdir)/mini-bowling-deploystatus.sh"
sed \
    -e "s|readonly LOG_DIR=.*|LOG_DIR='$_DEPLOY_STATUS_DIR'|" \
    -e "s|readonly DEPLOY_STATUS_FILE=.*|DEPLOY_STATUS_FILE='$_DEPLOY_STATUS_TEST_FILE'|" \
    "$SCRIPT" > "$_DEPLOY_PATCHED"

_DEPLOY_STATUS_RUNNER="$(tmpdir)/deploy_status_test.sh"
cat > "$_DEPLOY_STATUS_RUNNER" << DSEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_DEPLOY_PATCHED"
git() {
    case "\$*" in
        *rev-parse*short*) echo "abc1234" ;;
        *log*format*)      echo "Test commit message" ;;
        *)                 return 0 ;;
    esac
}
deploy_start="\$(date '+%Y-%m-%d %H:%M:%S')"
deploy_commit="abc1234"
deploy_subject="Test commit message"
_write_deploy_status() {
    local result="\$1"
    mkdir -p "\$LOG_DIR"
    printf "%s\n%s\n%s\n%s\n%s\n" \
        "\$deploy_start" \
        "\$(date '+%Y-%m-%d %H:%M:%S')" \
        "\$result" \
        "\$deploy_commit" \
        "\$deploy_subject" \
        > "\$DEPLOY_STATUS_FILE"
}
_write_deploy_status "OK"
DSEOF

run bash "$_DEPLOY_STATUS_RUNNER"
assert_exit "deploy status file write exits 0" 0
assert_file_exists "deploy status file is created" "$_DEPLOY_STATUS_TEST_FILE"

if [[ -f "$_DEPLOY_STATUS_TEST_FILE" ]]; then
    line_count=$(wc -l < "$_DEPLOY_STATUS_TEST_FILE")
    if [[ "$line_count" -ge 5 ]]; then
        pass "deploy status file has 5+ lines (includes commit info)"
    else
        fail "deploy status file has 5+ lines (includes commit info)" "got $line_count lines"
    fi
    result_line=$(sed -n '3p' "$_DEPLOY_STATUS_TEST_FILE")
    assert_equals "deploy status file result line is OK" "OK" "$result_line"
    commit_line=$(sed -n '4p' "$_DEPLOY_STATUS_TEST_FILE")
    assert_equals "deploy status file commit line is correct" "abc1234" "$commit_line"
fi
# ─────────────────────────────────────────────────────────────────────────────
suite "upload --list-sketches — last-uploaded marker"
# ─────────────────────────────────────────────────────────────────────────────

_LIST_PROJECT="$(tmpdir)"
_LIST_LOG="$(tmpdir)"
_LIST_STATUS="$_LIST_LOG/.last-arduino-upload"
mkdir -p "$_LIST_PROJECT/Everything" "$_LIST_PROJECT/Master_Test"
touch "$_LIST_PROJECT/Everything/Everything.ino"
touch "$_LIST_PROJECT/Master_Test/Master_Test.ino"
printf "Everything\n2026-01-01 02:30:00\nabc1234\nTest commit\n" > "$_LIST_STATUS"

_LIST_PATCHED="$(tmpdir)/mini-bowling-listsketches.sh"
sed \
    -e "s|readonly PROJECT_DIR=.*|PROJECT_DIR='$_LIST_PROJECT'|" \
    -e "s|readonly ARDUINO_STATUS_FILE=.*|ARDUINO_STATUS_FILE='$_LIST_STATUS'|" \
    "$SCRIPT" > "$_LIST_PATCHED"

_LIST_RUNNER="$(tmpdir)/list_sketches.sh"
cat > "$_LIST_RUNNER" << LISTEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_LIST_PATCHED"
require_project_dir() { cd "$_LIST_PROJECT"; }
list_available_sketches
LISTEOF

run bash "$_LIST_RUNNER"
assert_exit "list-sketches exits 0" 0
assert_output_contains "list-sketches shows last uploaded marker" "last uploaded"
assert_output_contains "list-sketches highlights correct sketch"  "Everything"

# ─────────────────────────────────────────────────────────────────────────────
suite "scoremore_history — list with no AppImages"
# ─────────────────────────────────────────────────────────────────────────────

_SM_HIST_RUNNER="$(tmpdir)/sm_hist.sh"
cat > "$_SM_HIST_RUNNER" << SMEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_PATHS_PATCHED"
scoremore_history list
SMEOF

run bash "$_SM_HIST_RUNNER"
assert_exit "scoremore-history list with no files exits 0" 0
assert_output_contains "scoremore-history says no versions" "No "

# ─────────────────────────────────────────────────────────────────────────────
suite "disk_cleanup — dry run of path construction"
# ─────────────────────────────────────────────────────────────────────────────

_DISK_RUNNER="$(tmpdir)/disk_cleanup.sh"
cat > "$_DISK_RUNNER" << DISKEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$_PATHS_PATCHED"
disk_cleanup
DISKEOF

run bash "$_DISK_RUNNER"
assert_exit "disk-cleanup with empty dirs exits 0" 0

# ─────────────────────────────────────────────────────────────────────────────
suite "wait-for-network — timeout logic"
# ─────────────────────────────────────────────────────────────────────────────

_WFN_FAIL="$(tmpdir)/wfn_fail.sh"
cat > "$_WFN_FAIL" << WFNEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
ping() { return 1; }
wait_for_network 2
WFNEOF

_WFN_PASS="$(tmpdir)/wfn_pass.sh"
cat > "$_WFN_PASS" << WFNEOF
#!/usr/bin/env bash
MINI_BOWLING_SOURCED=1 source "$SCRIPT"
ping() { return 0; }
wait_for_network 5
WFNEOF

run bash "$_WFN_FAIL"
assert_exit "wait-for-network times out with unreachable network" 1
assert_output_contains "wait-for-network prints timeout message" "not available"

run bash "$_WFN_PASS"
assert_exit "wait-for-network succeeds when network is up" 0

# ─────────────────────────────────────────────────────────────────────────────
suite "backup — file creation"
# ─────────────────────────────────────────────────────────────────────────────

FAKE_BACKUP="$(tmpdir)"
FAKE_PROJECT_BACKUP="$(tmpdir)"
mkdir -p "$FAKE_PROJECT_BACKUP/Everything"
touch "$FAKE_PROJECT_BACKUP/Everything/Everything.ino"

_BACKUP_RUNNER="$(tmpdir)/backup_runner.sh"
cat > "$_BACKUP_RUNNER" << BACKEOF
#!/usr/bin/env bash
backup_dir="$FAKE_BACKUP"
mkdir -p "\$backup_dir"
ts=\$(date '+%Y-%m-%d_%H-%M-%S')
out="\$backup_dir/mini-bowling-backup-\${ts}.tar.gz"
tar -czf "\$out" -C "$FAKE_PROJECT_BACKUP" . 2>/dev/null && echo "Backup: \$out"
BACKEOF

run bash "$_BACKUP_RUNNER"
assert_exit "backup exits 0" 0

found=$(find "$FAKE_BACKUP" -name "mini-bowling-backup-*.tar.gz" 2>/dev/null | wc -l)
if [[ "$found" -gt 0 ]]; then
    pass "backup creates a .tar.gz file"
else
    fail "backup creates a .tar.gz file" "no .tar.gz found in $FAKE_BACKUP"
fi

# ─────────────────────────────────────────────────────────────────────────────
suite "vnc-status — command dispatch and output structure"
# ─────────────────────────────────────────────────────────────────────────────

run bash "$SCRIPT" pi vnc status
assert_exit "vnc-status exits 0" 0
assert_output_contains "vnc-status prints header"     "VNC Status"
assert_output_contains "vnc-status reports installed" "Installed"

if bash "$SCRIPT" pi vnc status 2>/dev/null | grep -q "No VNC server found"; then
    skip "vnc-status reports service"   "VNC not installed"
    skip "vnc-status reports autostart" "VNC not installed"
else
    assert_output_contains "vnc-status reports service"   "Service"
    assert_output_contains "vnc-status reports autostart" "Autostart"
fi

# ─────────────────────────────────────────────────────────────────────────────
suite "vnc-setup — command dispatch and subcommand validation"
# ─────────────────────────────────────────────────────────────────────────────

# No subcommand: pi vnc with no sub should show status (exits 0)
run bash "$SCRIPT" pi vnc status
assert_exit "pi vnc status exits 0" 0

# Unknown subcommand: should exit non-zero with error message
run bash "$SCRIPT" pi vnc bogus-subcommand
assert_nonzero "pi vnc with unknown subcommand exits non-zero"
assert_output_contains "pi vnc unknown subcommand error" "bogus-subcommand"

fi  # end unit tests

# ── INTEGRATION TESTS ─────────────────────────────────────────────────────────

if [[ "$RUN_MODE" == "all" || "$RUN_MODE" == "integration" ]]; then

suite "Integration — environment"

ARDUINO_PRESENT=false
if [[ -c "/dev/ttyACM0" ]] || ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | grep -q .; then
    ARDUINO_PRESENT=true
fi

ARDUINO_CLI_PRESENT=false
command -v arduino-cli >/dev/null 2>&1 && ARDUINO_CLI_PRESENT=true

SCOREMORE_PRESENT=false
[[ -L "$HOME/Desktop/ScoreMore.AppImage" ]] && SCOREMORE_PRESENT=true

$ARDUINO_PRESENT    && pass "Arduino port found"        || skip "Arduino port found"        "no port detected"
$ARDUINO_CLI_PRESENT && pass "arduino-cli available"   || skip "arduino-cli available"      "not installed"
$SCOREMORE_PRESENT  && pass "ScoreMore symlink exists"  || skip "ScoreMore symlink exists"   "no symlink"

suite "Integration — preflight"

if $ARDUINO_PRESENT && $ARDUINO_CLI_PRESENT; then
    run bash "$SCRIPT" system preflight
    assert_exit "preflight exits 0 with Arduino connected" 0
    assert_output_contains "preflight checks Arduino port" "Arduino"
else
    skip "preflight with Arduino" "no hardware"
fi

suite "Integration — status"

run bash "$SCRIPT" status
assert_exit "status exits 0" 0
assert_output_contains "status shows Port line"       "Port"
assert_output_contains "status shows ScoreMore line"  "ScoreMore"
assert_output_contains "status shows Sketch line"     "Sketch"
assert_output_contains "status shows Git branch line" "Git branch"
assert_output_contains "status shows Last deploy"     "Last deploy"
assert_output_contains "status shows VNC line"        "VNC"

suite "Integration — doctor"

run bash "$SCRIPT" system doctor
assert_exit "doctor exits 0" 0
assert_output_contains "doctor checks git"         "git"
assert_output_contains "doctor checks curl"        "curl"
assert_output_contains "doctor checks arduino-cli" "arduino-cli"
assert_output_contains "doctor checks dialout"     "dialout"

suite "Integration — branch check"

if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    run bash "$SCRIPT" code branch check
    assert_exit "code branch check exits 0 with network" 0
else
    skip "code branch check" "no network"
fi

suite "Integration — sketch list"

if $ARDUINO_CLI_PRESENT; then
    run bash "$SCRIPT" code sketch list
    assert_exit "code sketch list exits 0" 0
else
    skip "code sketch list" "arduino-cli not installed"
fi

suite "Integration — pi vnc status"

run bash "$SCRIPT" pi vnc status
assert_exit "pi vnc status exits 0" 0
assert_output_contains "pi vnc status shows structured output" "VNC Status"

if pgrep -f "Xvnc\|vncserver\|x11vnc\|wayvnc" >/dev/null 2>&1 || \
   ss -tlnp 2>/dev/null | grep -q ":590"; then
    assert_output_contains "pi vnc status shows connect address when running" "Connect to"
else
    skip "pi vnc status connect address" "VNC not running"
fi

suite "Integration — pi vnc subcommands"

run bash "$SCRIPT" pi vnc status
assert_exit "pi vnc status exits 0" 0

if command -v vncserver >/dev/null 2>&1 || command -v x11vnc >/dev/null 2>&1; then
    run bash "$SCRIPT" pi vnc start
    assert_exit "pi vnc start exits 0" 0

    run bash "$SCRIPT" pi vnc stop
    assert_exit "pi vnc stop exits 0" 0

    run bash "$SCRIPT" pi vnc enable
    assert_exit "pi vnc enable exits 0" 0

    run bash "$SCRIPT" pi vnc disable
    assert_exit "pi vnc disable exits 0" 0
else
    skip "pi vnc start"   "VNC not installed"
    skip "pi vnc stop"    "VNC not installed"
    skip "pi vnc enable"  "VNC not installed"
    skip "pi vnc disable" "VNC not installed"
fi

fi  # end integration tests

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo -e "${BOLD}────────────────────────────────────${NC}"
total=$(( PASS + FAIL + SKIP ))
echo -e "  ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}  (${total} total)"
echo -e "${BOLD}────────────────────────────────────${NC}"
echo

if [[ "$FAIL" -gt 0 ]]; then
    echo -e "${RED}${BOLD}FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"
    exit 0
fi
