# Supervisor handoff

## The handoff file

The first supervisor writes `HANDOFF.md` in the fleet dir. Each later supervisor adds `HANDOFF-<name>.md` with only what changed, and tells its successor to read them in order. Sections:

1. **Where things run.** Host access, fleet dir, agent table (tmux session, scope, repo or PR, ticket), and where each agent works (worktree or own clone).
2. **Watchdog.** How it was started, its end time, and how to restart it after a reboot.
3. **Monitor.** The exact `fleet monitor-cmd` output.
4. **Owner decisions.** Each decision with its time, and which agents it was sent to (message file names). Mark anything not decided by the owner as "agent decision" or "supervisor suggestion".
5. **Verified state.** PR numbers, heads (SHA), checks, mergeability, each with the time you checked it.
6. **Pending.** Open items, in priority order.
7. **Human steps.** What only the owner can do, per agent, and where the exact steps are written.
8. **Warnings.** Unexplained changes you found (do not revert them, report them), tokens to rotate, shell pitfalls.
9. **Transcript.** The path to your session transcript (`~/.claude/projects/.../<session id>.jsonl` or under `CLAUDE_CONFIG_DIR`).

Never put secrets in it.

## Rotation protocol

Trigger at about 700k context when auto-compact is at 800k, or when the owner asks.

1. Write `HANDOFF-<next>.md`.
2. Get the next session (name it, e.g. `<fleet>-sup-3`). Confirm with `ListAgents`.
3. SendMessage to it. Make the first line self-contained: "Handoff from <you>: you are now the supervisor of the <fleet> agents." Then list the files to read in order. Tell it the first step is to arm the Monitor from section 3 and reply "monitor armed".
4. Wait for "monitor armed". Only then TaskStop your own Monitor and any pollers.
5. Tell it you are its advisor. List the open questions the owner asked you that it now owns.
6. From now on: advisor mode. You do not touch the host or the agents unless asked. You relay the owner's new decisions from your chat to the supervisor immediately.

Two supervisors must never both send to the agents. One must never stop monitoring before the other confirmed.
