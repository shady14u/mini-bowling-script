# mini-bowling.sh

Helper script for **mini-bowling.sh** Arduino + ScoreMore development workflow  
(Raspberry Pi / Linux focused)

This script simplifies common tasks when developing and deploying code for a mini-bowling setup that uses:

- Arduino Mega (`arduino:avr:mega`) for hardware control
- ScoreMore bowling scoring software (Linux AppImage version)

## Command Structure

Commands are grouped by area. Run `mini-bowling.sh` with no arguments for the interactive menu, or `mini-bowling.sh help [command]` for focused help.

```text
status [--watch [N]]                 Show system status (auto-refresh every N seconds)
info                                 Dense single-screen summary
version                              Show version + check GitHub for updates
help [command]                       Show full help or per-command detail

deploy [--flags]                     Pull latest -> upload Everything -> restart ScoreMore
deploy reset                         Delete local repo, clone fresh, then deploy
deploy schedule HH:MM                Schedule daily deploy
deploy unschedule                    Remove scheduled deploy
deploy history [N]                   Show last N deploys from logs

code status                          Show script repo + project repo status
code board                           Show Arduino board and upload target info
code sketch upload [--Name]          Compile + upload sketch (default: Everything)
code sketch list                     List available sketches
code sketch test [--Name]            Compile-only check
code sketch rollback [N]             Roll back N git commits and re-upload
code sketch info                     Show sketch, branch, and commit currently on Arduino
code compile [--Name]                Compile without uploading
code pull [branch]                   Pull latest for current branch or switch+pull
code switch [branch]                 Permanently switch branch
code console                         Open interactive serial console
code config                          Open Arduino config tool in browser
code reset                           Delete local repo and clone fresh from remote
code branch list|checkout|switch|update|check

scoremore start|stop|restart         Manage ScoreMore process
scoremore download <ver|latest>      Download a ScoreMore AppImage
scoremore update                     Download newer version and relaunch if needed
scoremore version                    Show active version details
scoremore check-update               Check scoremorebowling.com for updates
scoremore history                    Manage downloaded versions
scoremore rollback                   Switch to previous downloaded version
scoremore autostart enable|disable|status
scoremore logs [show|list|tail|dump]
scoremore watchdog run|enable|disable|status

pi status|sysinfo|temp|cpu|disk|wifi|update|reboot|shutdown
pi vnc status|start|stop|enable|disable

logs [list|follow|dump|tail|clean]

system check                         Quick "ready to bowl?" check
system health                        Full health dashboard
system report                        Generate timestamped report file
system support                       Generate compressed diagnostic bundle
system cron                          Show all mini-bowling cron jobs
system doctor                        Check dependencies, platform, groups, session
system preflight [--quick]           Pre-deploy checks without making changes
system backup [--include-appimage]   Archive sketches + config
system repair                        Auto-fix common broken states
system cleanup                       Remove old AppImages, caches, old logs
system ports                         List serial devices with USB info
system tail-all [N]                  Interleave command + Arduino logs live
system serial start|stop|status|tail|console
system wait-for-network [N]
system os-updates enable [HH:MM]     Schedule daily apt update
system os-updates disable|status
system scoremore-update enable [HH:MM]
system scoremore-update disable|status
system script-update enable [HH:MM]
system script-update disable|status

install setup|create-dir|cli
script version|update
```

## Features

**Arduino and Deploy**

- Full deploy cycle: wait for network -> pull latest -> upload `Everything` -> restart ScoreMore
- `deploy --dry-run` previews the whole deploy without making changes
- `deploy reset` wipes the local Arduino repo, clones a fresh copy, and immediately deploys
- `code reset` wipes and re-clones the local Arduino repo without deploying (prompts for confirmation)
- `code sketch test` compiles without touching hardware
- Deploy lock prevents the watchdog from restarting ScoreMore mid-upload
- Port and sketch checks happen before ScoreMore is stopped
- `code sketch rollback` rolls back git commits and re-uploads the last-used sketch
- `code config` opens the Arduino config tool in the Pi's browser

**ScoreMore**

- Download and verify any AppImage version with `scoremore download`
- `scoremore download` updates the desktop symlink and only relaunches if ScoreMore was already running
- `scoremore update` downloads a newer version and restarts if needed
- `scoremore restart` kills and relaunches ScoreMore in one command
- Wayland/Xwayland/X11-aware launch handling for Raspberry Pi 5 and newer Pi OS desktop sessions
- Automatic `APPIMAGE_EXTRACT_AND_RUN=1` fallback when classic AppImage FUSE support is missing
- `scoremore watchdog` restarts the app after crashes while respecting active deploy locks

**Diagnostics and Monitoring**

- `status --watch`, `info`, `system check`, and `system health` cover fast and deep health views
- `code status` shows script repo + Arduino repo branch/dirty/ahead-behind state
- `code sketch info` compares repo HEAD to what is flashed on the Arduino
- `system doctor` checks dependencies, platform compatibility, GUI session visibility, and serial access
- `system preflight` validates deploy readiness without changing anything
- `system repair` fixes common stale-state problems automatically
- `system support` builds a shareable support bundle

**Pi Operations**

- `pi temp` and `pi cpu` provide thermal and CPU monitoring
- `pi disk`, `pi wifi`, and `pi vnc` help with day-to-day Pi support
- `pi update`, `pi reboot`, and `pi shutdown` include sudo safety checks
- Scheduled maintenance exists for OS updates, ScoreMore updates, and script updates

## Requirements

- Raspberry Pi OS 64-bit on ARM64 is the intended ScoreMore target
- `arduino-cli`, `git`, `curl`, `realpath`, `pgrep`, `pkill`, and `nohup`
- Write access to `~/Desktop` and `~/.config/autostart`
- A desktop session for launching ScoreMore
- If `libfuse2` is not installed, the script falls back to `APPIMAGE_EXTRACT_AND_RUN=1`

**Arduino requirements**

The script manages the following Arduino core and libraries automatically via `install setup` and `install cli`:

| Component | Type | Install command |
|---|---|---|
| `arduino:avr` | Core | `arduino-cli core install arduino:avr` |
| `Adafruit NeoPixel` | Library | `arduino-cli lib install "Adafruit NeoPixel"` |
| `AccelStepper` | Library | `arduino-cli lib install AccelStepper` |
| `Servo` | Library | `arduino-cli lib install Servo` |
| `Accessories` | Library | `arduino-cli lib install Accessories` |
| `Servo Hardware PWM` | Library | `arduino-cli lib install "Servo Hardware PWM"` |

`install cli` runs `arduino-cli update` and `arduino-cli upgrade` to keep installed cores and libraries up to date. `system doctor`, `system preflight`, and `system check` all report any missing libraries and the installed `arduino-cli` version.

## Installation / Configuration

Clone the script repo:

```bash
git clone https://github.com/glenpekarcsik/mini-bowling-script.git
cd mini-bowling-script
chmod +x mini-bowling.sh
```

Run the guided setup wizard:

```bash
./mini-bowling.sh install setup
```

The setup wizard:

1. Creates required directories
2. Installs `arduino-cli`
3. Clones or updates the Arduino project repo
4. Downloads the latest ScoreMore AppImage
5. Installs `mini-bowling.sh` and bash completion
6. Configures ScoreMore autostart
7. Runs `system doctor`
8. Offers to enable the ScoreMore watchdog
9. Offers to schedule daily deploy

For Raspberry Pi 5, use Raspberry Pi OS 64-bit. The script checks architecture, AppImage runtime readiness, and GUI visibility during setup, `system doctor`, and `system preflight`.

After setup, verify the Arduino board/port and run preflight:

```bash
mini-bowling.sh system ports
mini-bowling.sh code board
mini-bowling.sh system preflight
```

If your Arduino port or board differs from the defaults, update these constants near the top of the installed script:

```bash
readonly DEFAULT_PORT="/dev/ttyACM0"
readonly BOARD="arduino:avr:mega"
```

## Available Commands

| Command | Description | Options | Example |
|---|---|---|---|
| `status` | Full system status | `--watch [N]` | `mini-bowling.sh status --watch` |
| `info` | Dense single-screen summary | - | `mini-bowling.sh info` |
| `version` | Script version + update check | - | `mini-bowling.sh version` |
| `help` | Full help or per-command help | `[command]` | `mini-bowling.sh help deploy` |
| `deploy` | Pull latest -> upload `Everything` -> restart ScoreMore | `--dry-run` \| `--no-kill` \| `--branch <name>` | `mini-bowling.sh deploy` |
| `deploy reset` | Delete local repo, clone fresh, then deploy | - | `mini-bowling.sh deploy reset` |
| `deploy schedule` | Schedule daily deploy | `HH:MM` | `mini-bowling.sh deploy schedule 02:30` |
| `deploy unschedule` | Remove scheduled deploy | - | `mini-bowling.sh deploy unschedule` |
| `deploy history` | Show deploy history from logs | `[N]` | `mini-bowling.sh deploy history 10` |
| `code status` | Show script repo + project repo state | - | `mini-bowling.sh code status` |
| `code board` | Show Arduino board and port details | - | `mini-bowling.sh code board` |
| `code sketch upload` | Compile + upload sketch | `[--Name]` \| `--branch <name>` \| `--no-kill` | `mini-bowling.sh code sketch upload --Everything` |
| `code sketch list` | List available sketches | - | `mini-bowling.sh code sketch list` |
| `code sketch test` | Compile-only sketch check | `[--Name]` | `mini-bowling.sh code sketch test --Everything` |
| `code sketch rollback` | Roll back git commits and re-upload | `[N]` | `mini-bowling.sh code sketch rollback 2` |
| `code sketch info` | Show flashed sketch/branch/commit | - | `mini-bowling.sh code sketch info` |
| `code compile` | Compile without uploading | `[--Name]` | `mini-bowling.sh code compile --Master_Test` |
| `code pull` | Pull current branch or switch+pull | `[branch]` | `mini-bowling.sh code pull feature/new-sensor` |
| `code switch` | Permanently switch branches | `[branch]` | `mini-bowling.sh code switch main` |
| `code console` | Interactive serial console | - | `mini-bowling.sh code console` |
| `code config` | Open browser-based config tool | - | `mini-bowling.sh code config` |
| `code reset` | Delete local Arduino repo and clone fresh from remote | `--force` | `mini-bowling.sh code reset` |
| `code branch list` | List local + remote branches | - | `mini-bowling.sh code branch list` |
| `code branch checkout` | Temporary branch checkout/upload | `<branch> [--Sketch]` | `mini-bowling.sh code branch checkout feature/new-sensor --Master_Test` |
| `code branch switch` | Permanent branch switch with fetch/pull | `<branch>` | `mini-bowling.sh code branch switch feature/new-sensor` |
| `code branch update` | Pull latest for current branch | - | `mini-bowling.sh code branch update` |
| `code branch check` | Check remote for new commits | - | `mini-bowling.sh code branch check` |
| `scoremore start` | Launch ScoreMore | - | `mini-bowling.sh scoremore start` |
| `scoremore stop` | Stop ScoreMore | - | `mini-bowling.sh scoremore stop` |
| `scoremore restart` | Restart ScoreMore | - | `mini-bowling.sh scoremore restart` |
| `scoremore download` | Download and verify AppImage | `<ver>` \| `latest` | `mini-bowling.sh scoremore download latest` |
| `scoremore update` | Download newer version and relaunch if needed | - | `mini-bowling.sh scoremore update` |
| `scoremore version` | Show active version details | - | `mini-bowling.sh scoremore version` |
| `scoremore check-update` | Check for upstream updates | - | `mini-bowling.sh scoremore check-update` |
| `scoremore history` | Manage downloaded versions | `list` \| `use <ver>` \| `clean` | `mini-bowling.sh scoremore history use 1.8.0` |
| `scoremore rollback` | Switch to previous version | - | `mini-bowling.sh scoremore rollback` |
| `scoremore autostart` | Manage desktop autostart | `enable` \| `disable` \| `status` | `mini-bowling.sh scoremore autostart status` |
| `scoremore logs` | Show/list/tail/dump ScoreMore logs | `show` \| `list` \| `tail` \| `dump` | `mini-bowling.sh scoremore logs tail` |
| `scoremore watchdog` | Crash watchdog | `run` \| `enable` \| `disable` \| `status` | `mini-bowling.sh scoremore watchdog enable` |
| `pi status` | Pi health overview | - | `mini-bowling.sh pi status` |
| `pi sysinfo` | Full system identity | - | `mini-bowling.sh pi sysinfo` |
| `pi temp` | CPU temperature monitor | `--watch [N]` | `mini-bowling.sh pi temp --watch` |
| `pi cpu` | CPU load and per-core usage | `--watch [N]` | `mini-bowling.sh pi cpu --watch 3` |
| `pi disk` | Disk usage by key directory | - | `mini-bowling.sh pi disk` |
| `pi wifi` | Wi-Fi diagnostics | - | `mini-bowling.sh pi wifi` |
| `pi update` | Run apt update + upgrade | - | `mini-bowling.sh pi update` |
| `pi reboot` | Reboot with countdown | - | `mini-bowling.sh pi reboot` |
| `pi shutdown` | Shut down with countdown | - | `mini-bowling.sh pi shutdown` |
| `pi vnc` | VNC management | `status` \| `start` \| `stop` \| `enable` \| `disable` | `mini-bowling.sh pi vnc status` |
| `logs` | List log files | - | `mini-bowling.sh logs` |
| `logs list` | List log files explicitly | - | `mini-bowling.sh logs list` |
| `logs follow` | Live tail today's command log | - | `mini-bowling.sh logs follow` |
| `logs dump` | Dump a day's command log | `--date YYYY-MM-DD` | `mini-bowling.sh logs dump --date 2026-03-06` |
| `logs tail` | Tail a day's command log | `[N]` \| `--date YYYY-MM-DD` | `mini-bowling.sh logs tail 100` |
| `logs clean` | Delete old logs | `--keep N` | `mini-bowling.sh logs clean --keep 7` |
| `system check` | Quick ready-to-bowl check | - | `mini-bowling.sh system check` |
| `system health` | Full health dashboard | - | `mini-bowling.sh system health` |
| `system report` | Generate timestamped report | - | `mini-bowling.sh system report` |
| `system support` | Generate compressed support bundle | - | `mini-bowling.sh system support` |
| `system cron` | Show installed mini-bowling cron jobs | - | `mini-bowling.sh system cron` |
| `system doctor` | Dependency/platform/session checks | - | `mini-bowling.sh system doctor` |
| `system preflight` | Pre-deploy checks | `--quick` \| `-q` | `mini-bowling.sh system preflight --quick` |
| `system backup` | Archive sketches + config | `--include-appimage` | `mini-bowling.sh system backup` |
| `system repair` | Auto-fix common broken states | - | `mini-bowling.sh system repair` |
| `system cleanup` | Remove old AppImages, caches, old logs | - | `mini-bowling.sh system cleanup` |
| `system ports` | List serial devices with USB info | - | `mini-bowling.sh system ports` |
| `system tail-all` | Interleave command + Arduino logs | `[N]` | `mini-bowling.sh system tail-all` |
| `system serial` | Background serial logging + console | `start` \| `stop` \| `status` \| `tail` \| `console` | `mini-bowling.sh system serial start` |
| `system wait-for-network` | Wait for internet connectivity | `[N]` | `mini-bowling.sh system wait-for-network 60` |
| `system os-updates` | Schedule daily apt updates | `enable [HH:MM]` \| `disable` \| `status` | `mini-bowling.sh system os-updates enable 03:00` |
| `system scoremore-update` | Schedule daily ScoreMore update check | `enable [HH:MM]` \| `disable` \| `status` | `mini-bowling.sh system scoremore-update status` |
| `system script-update` | Schedule daily script update | `enable [HH:MM]` \| `disable` \| `status` | `mini-bowling.sh system script-update enable 04:00` |
| `install setup` | Guided setup wizard | - | `mini-bowling.sh install setup` |
| `install create-dir` | Create required directories | - | `mini-bowling.sh install create-dir` |
| `install cli` | Install `arduino-cli` | - | `mini-bowling.sh install cli` |
| `script version` | Show script version + update check | - | `mini-bowling.sh script version` |
| `script update` | Update script from GitHub | - | `mini-bowling.sh script update` |

## Usage Examples

```bash
# Quick admin
mini-bowling.sh status
mini-bowling.sh info
mini-bowling.sh system check
mini-bowling.sh system health
mini-bowling.sh system repair
mini-bowling.sh help deploy

# Deploy
mini-bowling.sh deploy --dry-run
mini-bowling.sh deploy
mini-bowling.sh deploy --branch testing
mini-bowling.sh deploy reset
mini-bowling.sh deploy schedule 02:30
mini-bowling.sh deploy history 20

# Arduino workflow
mini-bowling.sh code status
mini-bowling.sh code board
mini-bowling.sh code sketch list
mini-bowling.sh code sketch test --Everything
mini-bowling.sh code sketch upload --Everything
mini-bowling.sh code sketch rollback 2
mini-bowling.sh code sketch info
mini-bowling.sh code reset
mini-bowling.sh code branch list
mini-bowling.sh code branch checkout feature/new-sensor --Master_Test

# ScoreMore
mini-bowling.sh scoremore download latest
mini-bowling.sh scoremore update
mini-bowling.sh scoremore version
mini-bowling.sh scoremore logs tail
mini-bowling.sh scoremore watchdog status

# Pi and diagnostics
mini-bowling.sh pi temp --watch
mini-bowling.sh pi cpu --watch 3
mini-bowling.sh pi disk
mini-bowling.sh system preflight --quick
mini-bowling.sh system doctor
mini-bowling.sh system support
```

## Deploy Cycle

Run `deploy --dry-run` first if you want a preview. A real `deploy`:

1. Verifies the project repo is present
2. Writes the deploy lock so the watchdog stays out of the way
3. Waits for network connectivity
4. Warns if the repo is dirty
5. Pulls latest from the default git branch
6. Verifies the Arduino port and target sketch
7. Stops serial logging if needed
8. Stops ScoreMore
9. Compiles and uploads `Everything`
10. Restarts serial logging if it was previously running
11. Starts ScoreMore again
12. Records pass/fail status and commit info
13. Sends a desktop notification if `notify-send` is available

## Deploy Status Tracking

Every deploy updates `~/Documents/Bowling/logs/.last-deploy-status`, which is shown in `status`.

Example:

```text
Last deploy : OK at 2026-03-06 02:30:14 -> a1b2c3d: Fix pin debounce timing
Last deploy : FAILED (started 2026-03-06 02:30:01) -> a1b2c3d: Fix pin debounce timing
```

## Deploy Dry Run

`deploy --dry-run` reports what would happen without making changes.

Typical checks include:

- Network reachable
- Current commit and whether the remote is ahead
- Repo clean/dirty state
- Arduino port visibility
- Whether ScoreMore is running
- Whether the sketch exists
- Free disk space

## Code Reset

Use `code reset` to recover from a corrupted or broken local Arduino repo. It removes the entire `$PROJECT_DIR` and clones a fresh copy from `$PROJECT_REPO`.

```bash
mini-bowling.sh code reset
```

The command shows the directory that will be deleted and the remote URL, then prompts for confirmation before proceeding. Pass `--force` to skip the prompt (useful in scripts):

```bash
mini-bowling.sh code reset --force
```

`deploy reset` combines reset and deploy into a single non-interactive command — no confirmation prompt:

```bash
mini-bowling.sh deploy reset
```

This is the go-to recovery command when the local repo is in an unrecoverable state (bad merge, corrupted objects, wrong remote, etc.). It clones from scratch and immediately compiles, uploads, and restarts ScoreMore.

## Branch Management

Use `code branch list` to inspect branches, `code branch switch` to move the repo permanently, and `code branch checkout` or `code sketch upload --branch` for temporary branch uploads.

```bash
mini-bowling.sh code branch list
mini-bowling.sh code branch switch feature/new-sensor
mini-bowling.sh code branch checkout feature/new-sensor --Master_Test
mini-bowling.sh code sketch upload --Everything --branch feature/new-sensor
```

Temporary branch upload flows return to the original branch after the compile/upload step finishes.

## ScoreMore Management

```bash
mini-bowling.sh scoremore download latest
mini-bowling.sh scoremore download 1.8.0
mini-bowling.sh scoremore update
mini-bowling.sh scoremore check-update
mini-bowling.sh scoremore version
mini-bowling.sh scoremore history list
mini-bowling.sh scoremore history use 1.7.0
mini-bowling.sh scoremore history clean
mini-bowling.sh scoremore rollback
```

`scoremore download` is package management, not a forced restart. It updates the active symlink and only relaunches ScoreMore if it was already running. By contrast, deploy and upload flows bring ScoreMore back up after they finish.

## ScoreMore Process Management

ScoreMore runs as an Electron AppImage. The script kills the AppImage launcher and then cleans up any leftover child processes.

On Raspberry Pi 5 and newer Raspberry Pi OS desktop releases, the script prepares GUI launch variables for X11, Xwayland, and Wayland sessions. It prefers existing `DISPLAY`, `XDG_RUNTIME_DIR`, and `WAYLAND_DISPLAY`, falls back to `/run/user/<uid>` when needed, and only then falls back to `:0`.

If `libfuse2` is not installed, the script automatically uses `APPIMAGE_EXTRACT_AND_RUN=1`.

## ScoreMore Watchdog

```bash
mini-bowling.sh scoremore watchdog run
mini-bowling.sh scoremore watchdog enable
mini-bowling.sh scoremore watchdog disable
mini-bowling.sh scoremore watchdog status
```

The watchdog skips restart attempts when a deploy lock exists. It also restarts background serial logging if the device was unplugged and the monitor process died.

## Scheduled Maintenance

```bash
mini-bowling.sh deploy schedule 02:30
mini-bowling.sh system os-updates enable 03:00
mini-bowling.sh system scoremore-update enable 03:30
mini-bowling.sh system script-update enable 04:00
```

Re-running an `enable` command replaces the existing schedule for that task.

## System Check, Preflight, Doctor, and Repair

- `system check` is the quick "can this bowl right now?" command
- `system preflight` validates deploy readiness without making changes
- `system preflight --quick` skips network-heavy checks
- `system doctor` goes deeper on dependencies, architecture, session visibility, and serial permissions
- `system repair` cleans up stale PID files, stale deploy locks, missing directories, and autostart-related issues

## Logging

```bash
mini-bowling.sh logs
mini-bowling.sh logs list
mini-bowling.sh logs follow
mini-bowling.sh logs dump --date 2026-03-06
mini-bowling.sh logs tail 100 --date 2026-03-06
mini-bowling.sh logs clean --keep 7
mini-bowling.sh scoremore logs list
mini-bowling.sh scoremore logs tail
```

The `--date` flag is especially useful the morning after an overnight deploy because the deploy may have completed in the previous day's log.

## Arduino Config Tool

The Arduino project includes a browser-based config tool at `config-tool/index.html`.

```bash
mini-bowling.sh code config
```

The script opens the tool in the default browser on the Pi. Browser detection prefers `chromium-browser`, then `chromium`, `firefox`, `epiphany`, and finally `xdg-open`.

## System Serial

```bash
mini-bowling.sh system serial start
mini-bowling.sh system serial status
mini-bowling.sh system serial tail
mini-bowling.sh system serial stop
mini-bowling.sh system serial console
```

Serial logs auto-rotate at 10 MB. The interactive console is blocked while background serial logging owns the port.

## Raspberry Pi Management

```bash
mini-bowling.sh pi status
mini-bowling.sh pi sysinfo
mini-bowling.sh pi temp --watch
mini-bowling.sh pi cpu --watch 5
mini-bowling.sh pi disk
mini-bowling.sh pi wifi
mini-bowling.sh pi vnc status
mini-bowling.sh pi update
```

## Tab Completion

`mini-bowling-completion.bash` provides completion for commands, subcommands, flags, sketch names, git branches, log options, schedules, and downloaded ScoreMore versions.

Examples:

```bash
mini-bowling.sh <TAB>
# status info version help deploy code scoremore pi logs system install script

mini-bowling.sh code <TAB>
# status board sketch branch compile pull switch console config reset

mini-bowling.sh scoremore <TAB>
# start stop restart download update version check-update history rollback autostart logs watchdog

mini-bowling.sh pi <TAB>
# status sysinfo temp cpu disk update reboot shutdown wifi vnc

mini-bowling.sh system <TAB>
# check health report support cron doctor preflight backup repair cleanup ports tail-all serial wait-for-network os-updates scoremore-update script-update
```

Install it with:

```bash
sudo cp mini-bowling-completion.bash /etc/bash_completion.d/mini-bowling.sh
source /etc/bash_completion.d/mini-bowling.sh
```

## Updating the Script

```bash
mini-bowling.sh script update
```

The updater clones `~/.local/share/mini-bowling-script` on first run and pulls latest on later runs. It validates with `bash -n` before installing so a broken update does not get copied into place.

## Quick Reference

```bash
mini-bowling.sh scoremore restart
mini-bowling.sh status --watch
mini-bowling.sh system check
mini-bowling.sh system health
mini-bowling.sh code sketch info
mini-bowling.sh deploy history
mini-bowling.sh system repair
mini-bowling.sh system preflight --quick
mini-bowling.sh system tail-all
mini-bowling.sh scoremore logs tail
mini-bowling.sh pi cpu --watch
mini-bowling.sh system support
```

## System Support Bundle

`system support` collects the diagnostic files needed for support into `~/Documents/Bowling/support/mini-bowling-support-TIMESTAMP.tar.gz`.

Bundle contents include:

- `info.txt`
- `status.txt`
- `system-check.txt`
- `doctor.txt`
- `environment.txt`
- `crontab.txt`
- `arduino.txt`
- `scoremore.txt`
- `git.txt`
- `dmesg-usb.txt`
- `pi-health.txt`
- `deploy-status.txt`
- recent mini-bowling logs
- recent ScoreMore logs

To inspect a bundle without extracting:

```bash
tar -tzf mini-bowling-support-*.tar.gz
```

## Changelog

### v5.1.0

- Added `code reset` — deletes the local Arduino project directory and clones a fresh copy from the remote, with a confirmation prompt
- Added `deploy reset` — non-interactive reset (no prompt) followed immediately by a full deploy
- `install cli` and `install setup` now install and upgrade all required Arduino libraries (`Adafruit NeoPixel`, `AccelStepper`, `Servo`, `Accessories`, `Servo Hardware PWM`) and run `arduino-cli update` + `arduino-cli upgrade`
- `system check`, `system doctor`, `system preflight`, `system health`, and `system report` now verify all required Arduino libraries are installed and report any missing ones
- `info`, `system check`, `system health`, `system report`, `system doctor`, and `system preflight` now display the installed `arduino-cli` version

### v5.0.0

- Internal refactors with no intended behavior change
- Extracted shared helpers for ScoreMore version parsing and Arduino upload metadata reads
- `system tail-all` sort behavior cleaned up
- General logging and project-dir helper cleanup

### v4.9.0

- Added `system support` compressed diagnostic bundles

### v4.8.0

- Fixed `deploy history` under `set -e`
- Fixed `system check` warning/failure counters
- Fixed `pi cpu` parsing and per-core reporting
- Removed fragile working-directory side effects from `scoremore download`

### v4.6.0

- Added `system check`
- Added `code status`
- Added `pi cpu`
- Added `help [topic]`
- Updated tab completion for the newer command surface

### v4.5.0

- Added `code config`
- Made `install setup` install the script and completion automatically

### v4.4.0

- Added `system health`, `system cron`, `deploy history`, `pi temp`, and `pi disk`

### v4.0.0

- Moved watchdog under `scoremore watchdog`
- Changed ScoreMore autostart commands to `scoremore autostart enable|disable|status`
- Added `code pull`, `code switch`, `code compile`, and `code sketch info`

## Configuration Reference

| Variable | Default | Description |
|---|---|---|
| `SCRIPT_VERSION` | `5.1.0` | Script version; bump when deploying updates |
| `DEFAULT_GIT_BRANCH` | `main` | Branch used by `deploy` and `code branch update` |
| `PROJECT_DIR` | `~/Documents/Bowling/Arduino/mini-bowling` | Arduino sketch root; override with `$MINI_BOWLING_DIR` |
| `DEFAULT_PORT` | `/dev/ttyACM0` | Arduino serial port; override with `$PORT` |
| `BOARD` | `arduino:avr:mega` | `arduino-cli` FQBN |
| `SCOREMORE_DIR` | `~/Documents/Bowling/ScoreMore` | Location for downloaded AppImages |
| `LOG_DIR` | `~/Documents/Bowling/logs` | Daily command log directory |
| `SYMLINK_PATH` | `~/Desktop/ScoreMore.AppImage` | Active ScoreMore desktop symlink |
| `BAUD_RATE` | `9600` | Serial baud rate; must match `Serial.begin()` in the sketch |
| `ARCH` | `arm64` | AppImage architecture suffix; Raspberry Pi OS 64-bit is the intended target |

## Project Structure

```text
~/Documents/Bowling/
|-- Arduino/
|   `-- mini-bowling/
|       |-- Everything/
|       |   `-- Everything.ino
|       |-- Master_Test/
|       |   `-- Master_Test.ino
|       `-- config-tool/
|-- ScoreMore/
|   `-- ScoreMore-<version>-arm64.AppImage
|-- logs/
|   `-- YYYY-MM-DD.log
|-- support/
|   `-- mini-bowling-support-<timestamp>.tar.gz
`-- backups/

~/Desktop/ScoreMore.AppImage          <- symlink to active AppImage
~/.config/autostart/scoremore.desktop <- desktop autostart entry when enabled

mini-bowling-script/
|-- mini-bowling.sh
|-- mini-bowling-test.sh
|-- mini-bowling-completion.bash
`-- README.md
```
