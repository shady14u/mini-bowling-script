# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

## Repository Overview

This is a single-file Bash script (`mini-bowling.sh`) that manages a mini-bowling setup running on Raspberry Pi. It orchestrates three components:

- **Arduino Mega** — hardware controller; compiled/uploaded via `arduino-cli`
- **ScoreMore** — Linux AppImage bowling scoring software
- **Raspberry Pi** — the host running everything

Supporting files:
- `mini-bowling-completion.bash` — bash tab completion for all commands and subcommands
- `mini-bowling-test.sh` — unit and integration test suite

## Running Tests

```bash
# All tests (unit + integration)
./mini-bowling-test.sh

# Unit tests only (no hardware required — runs in CI)
./mini-bowling-test.sh unit

# Integration tests (requires connected Arduino)
./mini-bowling-test.sh integration

# Verbose output on failure
./mini-bowling-test.sh unit -v
```

Syntax check only:
```bash
bash -n mini-bowling.sh
```

## Script Architecture

`mini-bowling.sh` is ~7000 lines of Bash organized as:

1. **Configuration block** (top) — `readonly` vars for paths, versions, Arduino board/port defaults, color codes. All paths default to `~/Documents/Bowling/...` but can be overridden with env vars (`MINI_BOWLING_DIR`, `PORT`, `BOARD`).

2. **Shared helpers** — `die()`, `setup_logging()`, `_scoremore_pid()`, `_current_branch()`, `_cron_manage()`, `_read_crontab()`, and others prefixed with `_`. These are extracted top-level functions to avoid Bash global scope pollution from nested function definitions.

3. **Feature functions** — one function (or small cluster) per command: `cmd_deploy()`, `cmd_compile_and_upload()`, `cmd_code_reset()`, `start_scoremore()`, `kill_scoremore_gracefully()`, `doctor()`, `system_check()`, etc.

4. **`main()`** — handles no-argument interactive menu, determines whether to log the invocation, then calls `_dispatch()`.

5. **`_dispatch()`** — the top-level `case` statement that routes `$1` (the command) to the right function. Subcommands are handled by nested `case` statements inside each `code`, `scoremore`, `pi`, `system` branch.

6. **Sourcing guard** (bottom) — `[[ "${MINI_BOWLING_SOURCED:-}" == "1" ]] || main "$@"` — allows the test suite to source the script without running `main()`.

## Key Conventions

**Command dispatch pattern** — every top-level command is a `case` arm in `_dispatch()`. Subcommands use a local variable (`subcmd`, `codecmd`, etc.) and another nested `case`. Adding a new command means: write a function, add a `case` arm in `_dispatch()`, and add completion entries in `mini-bowling-completion.bash`.

**Logging** — state-changing commands call `setup_logging` which writes to `~/Documents/Bowling/logs/mini-bowling-YYYY-MM-DD.log` and exports `$MINI_BOWLING_LOG`. `main()` then pipes `_dispatch()` output through `tee -a "$MINI_BOWLING_LOG"`. Read-only commands skip logging; the full skip list is maintained inside the `case` block near the top of `main()`.

**Deploy lock** — `cmd_deploy()` and `cmd_compile_and_upload()` write/remove a lock file so the ScoreMore watchdog cron job skips restart attempts during active uploads.

**Arduino status file** — `$ARDUINO_STATUS_FILE` (`~/.../logs/.last-arduino-upload`) stores the last-uploaded sketch name, branch, and commit hash. `cmd_sketch_info()` reads this to show what is currently flashed.

**Deploy status file** — `$DEPLOY_STATUS_FILE` (`~/.../logs/.last-deploy-status`) is written by `_write_deploy_status()` and shown by `print_status()`.

**ScoreMore GUI launch** — `prepare_scoremore_launch_env()` detects the desktop session type (X11/Xwayland/Wayland) for Pi 5 compatibility and sets `APPIMAGE_EXTRACT_AND_RUN=1` automatically when `libfuse2` is missing.

**Branch handling** — temporary branch operations (`code branch checkout`, `deploy --branch`, `code sketch upload --branch`) use `with_git_branch()` to stash the current branch, run the upload, and restore it. Permanent switches go through `switch_branch()`.

**`code reset` config preservation** — before wiping `$PROJECT_DIR`, the function saves `Everything/general_config.user.h` and `Everything/pin_config.user.h` to a temp location, then restores them after a fresh clone.

## Test Framework

`mini-bowling-test.sh` ships its own lightweight test framework (no external dependencies):
- `suite "name"` — groups tests and prints a header
- `run cmd args...` — captures output and exit code into `$_run_out` / `$_run_exit`
- `assert_exit`, `assert_output_contains`, `assert_output_not_contains`, `assert_equals`, `assert_file_exists`, `assert_nonzero`, `assert_file_not_exists`
- `source_script` — sources `mini-bowling.sh` with `MINI_BOWLING_SOURCED=1` to test internal functions directly
- `tmpdir` — creates a temp directory under a root that is cleaned up on EXIT

Integration tests are guarded with hardware/environment checks using `skip()` when prerequisites are absent.

## Configuration Reference

| Variable | Default | Override env var |
|---|---|---|
| `PROJECT_DIR` | `~/Documents/Bowling/Arduino/mini-bowling` | `MINI_BOWLING_DIR` |
| `DEFAULT_PORT` | `/dev/ttyACM0` | `PORT` |
| `BOARD` | `arduino:avr:mega` | `BOARD` |
| `SCOREMORE_DIR` | `~/Documents/Bowling/ScoreMore` | — |
| `LOG_DIR` | `~/Documents/Bowling/logs` | — |
| `BAUD_RATE` | `9600` | — |
