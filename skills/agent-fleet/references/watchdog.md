# Watchdog

`scripts/watchdog.sh` runs on the agent host. It runs on Linux or macOS and needs bash 4+, `tmux` and `rg`. It uses a tmux server of its own (`tmux -L fleet-<FLEET>`, no user config) unless `FLEET_TMUX_SOCKET=` is empty. It reads `fleet.conf` from its own directory.

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
- `paste_file` refuses a message that quotes permission or trust dialog text (exit 8). Without that rule a real dialog could not be told apart from the pasted quote, and Enter on a dialog can approve it.
- `paste_file` checks for a dialog and for typed text before the paste, and again after it, right before Enter. After the paste, any dialog text on screen is a real dialog: no keys are sent (exit 3) and the pasted text may stay in the input. The input line must hold exactly the message's first line or Claude Code's `[Pasted text #N ...]` placeholder. Anything else means someone typed: the line is cleared with `C-u` (Escape would interrupt a working agent, and `C-c` twice exits Claude Code), which also clears the other person's text, and the exit is 4. A failed pane read stops the send (exit 7) instead of counting as zero.
- Left open: a dialog or keystroke that arrives between the last check and Enter (well under a second) is not caught. For a multi-line paste shown inline, text typed on its continuation lines is not checked.
- With `AGENT_KIND=dsh` the same checks read `dsh-agent.mjs` instead: its process stands in for `claude`, tools are the children of the running `dsh` process, the ready line is `dsh-agent ready` and context comes from `dsh context (N%)`. There are no dialogs, so `dialog_kind` never fires and dialog-like text in a reply is just text. `tests/dsh-agent-stub.sh` covers this path with a stub `dsh`.
- `launch` sends all keys to the new pane by id. When a start fails, it closes that pane, so the claude it started (for example one waiting at the trust dialog) ends without an answer and a retry is not skipped as "already running". `CLAUDE_BIN` (default `claude`) lets tests point launch at a stub.

## Changing it

1. Edit `scripts/watchdog.sh` in the plugin repo, not the copy on the host.
2. `bash -n` and `shellcheck`.
3. Test a helper by sourcing it: `cd $FLEET_DIR && . ./watchdog.sh && <function> ...`. Sourcing loads the helpers and returns before the loop.
4. Run `scripts/smoke-test.sh <REMOTE_SSH> [REMOTE_USER] [HOST_BASE_DIR]` against the host. It uses a scratch fleet and never starts claude.
5. `fleet sync`, `fleet watchdog dry`, read the output, then `fleet watchdog stop && fleet watchdog start`.
6. Check the log for bash errors after the restart.
