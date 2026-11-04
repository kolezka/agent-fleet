# Watchdog

`scripts/watchdog.sh` runs on the agent host. It needs Linux (GNU `date -d`, `/proc`, `ps --ppid`, `md5sum`), plus `tmux` and `rg`. It reads `fleet.conf` from its own directory.

## What it detects, per agent, every 60 s

- **dead**: no `claude` process in the session's panes. After 3 checks the agent is replaced.
- **stalled**: the spinner is visible, the screen is unchanged apart from timers, and no tool process runs. The limit is 3 checks, or 10 while "thinking". The first response is Esc plus a nudge, then a replacement.
- **waiting** (idle): one nudge per idle period, at most every 15 min. It is re-armed only after 3 or more checks of work, so a blocked agent does not loop on "still waiting".
- **dialog**: a permission dialog is open. It is denied after 2 checks for a protected push and after 3 for anything else. It is never approved.
- **context**: at `CTX_MAX`% it pastes `ctx-handoff.txt` once. When the lead prints `● CONTEXT-HANDOFF-READY` and is idle, it is replaced (`REPLACED ... (context)`).
- **missing tmux session**: recreated with a replacement.
- **disk**: under `DISK_MIN_G` it asks agents to clean up, at most every 6 h.

A replacement gets: its prompt file, `autonomy.txt`, an optional `where-<session>.txt`, and a resume instruction (phased-delivery `references/resume.md`, same worktree, handoff session log).

## Limits

- It sees only each lead's screen, not in-process subagents. A hung subagent looks like `waiting`.
- The screen parsing depends on Claude Code's TUI text (`❯`, `bypass permissions on`, `Do you want to proceed?`, the `/1.0M (N%)` status line). A TUI change can break detection. Run `fleet watchdog dry` after a Claude Code update.
- The `user_typing` check treats any non-dim text after `❯` as typed input. A false positive only skips one nudge.

## Changing it

1. Edit `scripts/watchdog.sh` in the plugin repo, not the copy on the host.
2. `bash -n` and `shellcheck`.
3. Test a helper by sourcing it: `cd $FLEET_DIR && . ./watchdog.sh && <function> ...`. Sourcing loads the helpers and returns before the loop.
4. `fleet sync`, `fleet watchdog dry`, read the output, then `fleet watchdog stop && fleet watchdog start`.
5. Check the log for bash errors after the restart.
