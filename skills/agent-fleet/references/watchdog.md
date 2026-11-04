# Watchdog

`scripts/watchdog.sh` runs on the agent host. It needs Linux (GNU `date -d`, `/proc`, `ps --ppid`, `md5sum`), plus `tmux` and `rg`. It reads `fleet.conf` from its own directory.

## What it detects, per agent, every 60 s

- **dead**: no `claude` process in the session's panes. After 3 checks the agent is replaced.
- **stalled**: the spinner is visible, the screen is unchanged apart from timers, and no tool process runs. The limit is 3 checks, or 10 while "thinking". The first response is Esc plus a nudge, then a replacement.
- **waiting** (idle): one nudge per idle period, at most every 15 min. It is re-armed only after 3 or more checks of work, so a blocked agent does not loop on "still waiting".
- **dialog**: a permission dialog is open. It is denied after 2 checks for a protected push and after 3 for anything else. It is never approved.
- **trust dialog** (`state=dialog kind=trust`): Claude Code's workspace trust question for a new cwd. It is never typed into and never denied, because denying picks "No, exit" and ends the session. The supervisor tells the owner. A start or replacement that meets it fails within seconds and logs `START FAILED` or `REPLACE FAILED` with the reason.
- **context**: at `CTX_MAX`% it pastes `ctx-handoff.txt` once. When the lead prints `● CONTEXT-HANDOFF-READY` and is idle, it is replaced (`REPLACED ... (context)`).
- **missing tmux session**: recreated with a replacement.
- **disk**: under `DISK_MIN_G` it asks agents to clean up, at most every 6 h.

Replacements are numbered per session, and the count is kept in `FLEET_DIR/.repl-<session>`, so it survives a watchdog restart.

A replacement gets: its prompt file, `autonomy.txt`, an optional `where-<session>.txt`, and a resume instruction (phased-delivery `references/resume.md`, same worktree, handoff session log).

## Limits

- It sees only each lead's screen, not in-process subagents. A hung subagent looks like `waiting`.
- The screen parsing depends on Claude Code's TUI text (`❯`, `bypass permissions on`, `Do you want to proceed?`, the `/1.0M (N%)` status line). A TUI change can break detection. Run `fleet watchdog dry` after a Claude Code update.
- The `user_typing` check treats any non-dim text after `❯` as typed input. A false positive only skips one nudge.
- `paste_file` checks for a dialog and for typed text before the paste, and again after it, right before Enter. If either shows up after the paste, it does not press Enter. On typed text it clears the input line with `C-u` (Escape would interrupt a working agent, and `C-c` twice exits Claude Code), which also clears what the other person typed. On a dialog it sends no keys, so the pasted text may stay in the input. A dialog or keystroke that arrives in the sub-second gap before the paste, or between the last check and Enter, is not caught. Text typed after the paste, at the end of the input, is not caught either and is sent with the message.

## Changing it

1. Edit `scripts/watchdog.sh` in the plugin repo, not the copy on the host.
2. `bash -n` and `shellcheck`.
3. Test a helper by sourcing it: `cd $FLEET_DIR && . ./watchdog.sh && <function> ...`. Sourcing loads the helpers and returns before the loop.
4. Run `scripts/smoke-test.sh <REMOTE_SSH> [REMOTE_USER] [HOST_BASE_DIR]` against the host. It uses a scratch fleet and never starts claude.
5. `fleet sync`, `fleet watchdog dry`, read the output, then `fleet watchdog stop && fleet watchdog start`.
6. Check the log for bash errors after the restart.
