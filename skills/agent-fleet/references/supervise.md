# Supervising a fleet

## Monitor

`fleet monitor-cmd` prints a pipeline that tails `watchdog.log` on the host, passes actionable lines through, and prints a routine state line only when an agent's state changes. Arm it with the Monitor tool, timeout 1800000 ms, and re-arm on every expiry. The ssh options `ServerAliveInterval=30` and `ServerAliveCountMax=6` keep a quiet link from being dropped. If the ssh still drops, the awk filter prints the error. Re-arm, and check the host with `fleet status` before assuming anything about the agents.

## Events

| Log line | Meaning | Do |
|---|---|---|
| `state=stalled strike=n/3` | Screen unchanged and no tool running | Nothing at first: the watchdog nudges, then replaces. Look at `fleet screen` if it repeats. |
| `nudged (Esc + continue)` | Stall recovery step 1 | Check the screen in a few minutes. |
| `REPLACED ... (hung)` | Agent killed, a fresh one resumes from the run file | Confirm that the replacement printed its two-line resume statement and is in the right worktree. |
| `REPLACED ... (context)` | Context rotation finished | Same as above. |
| `CTXROTATE asked for handoff at N%` | Agent was asked to save state | Watch for its `CONTEXT-HANDOFF-READY` line. |
| `state=dialog` / `DENIED` | A permission dialog opened. The watchdog denies it after 2 to 3 checks. | Read what the agent tried. When it touched a hard limit, tell it the limit and the allowed path. Never approve a dialog for an agent. |
| `tmux session missing` | Session gone, being recreated | Check that `fleet status` shows it again. |
| `LOWDISK` | Disk under `DISK_MIN_G` | Check which agent fills it (`du` on worktrees, emulator images). |
| `end time reached` | Watchdog exited, agents still run | Tell the owner. Restart only if they want. |
| ssh `Timeout` / `closed` | Monitor link dropped | Re-arm, then `fleet status`. |

## Verify claims

Agent reports, subagent reports and reviews from other model families are claims until you check them:

- Push: `git ls-remote origin <branch>` matches the SHA the agent quoted.
- PR: `gh pr view N --json headRefOid,state,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup`.
- Stacked PRs: `gh api repos/O/R/compare/<base>...<head> --jq .behind_by` must be 0 for each PR before a bottom-up merge.
- CI failure: `gh run view <id> --log-failed`, then quote the exact failing assertion to the agent.
- Tell the owner what is verified and what is inferred, in separate words.

## Common incidents

- An agent cannot commit from a worktree because of root-owned files in the main checkout's `.git`: move it to its own clone and record the `chown` as a human step.
- An agent waits on a merge, review or deploy: the standing rule says to branch from the blocked branch and keep building. Re-send that rule only when the owner confirmed it for this run.
- An agent is idle on its own subagent: the watchdog sees only the lead's screen, so a hung subagent looks like `waiting`. Look at `fleet screen`, and tell the lead to check or restart its worker.
- An agent near full context: the watchdog's rotation handles it at `CTX_MAX`. Check that the replacement resumed in the same worktree.
