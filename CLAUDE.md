# agent-fleet

A Claude Code plugin for supervising a fleet of autonomous Claude Code agents. The agents run in tmux on a Linux host. See `README.md` for what it does and `skills/agent-fleet/SKILL.md` for the supervisor workflow.

## Layout

- `scripts/fleet`: the CLI. It runs on the supervisor machine (macOS or Linux) and reaches the host through `rx` (bash script over stdin, optional `su - REMOTE_USER`).
- `scripts/watchdog.sh`: runs on the agent host only (Linux: GNU `date -d`, `/proc`, `ps --ppid`, `md5sum`). When sourced it loads the helpers and returns before the loop. `fleet send`, `fleet start` and `fleet status` depend on that.
- `templates/`: files copied by `fleet init`. `fleet.conf` is sourced by bash on both sides, so it must stay valid bash.
- `skills/agent-fleet/`: the skill and its references. Keep SKILL.md short and put details in `references/`.

## Rules for changes

- Shared logic lives in `watchdog.sh` helpers (`paste_file`, `start_agent`, `dialog_kind`, `user_typing`, `ctx_pct`). `fleet` calls them through `rx_helpers`. Do not copy the logic into `fleet`.
- Never paste into a pane before Claude Code's UI is detected (`launch` waits for the claude process and `bypass permissions on` or `for shortcuts`). A shell prompt such as starship also shows `❯` and would run the pasted text.
- `paste_file` must keep refusing when the message file is empty or blank (exit 6), a permission dialog is open (exit 3) or the input line has typed text (exit 4), and must confirm delivery (exit 5 if the first non-empty line is not in the pane).
- The watchdog never approves a permission dialog. It only denies.
- Hard limits belong in each fleet's `autonomy.txt`. Do not hardcode project names, hosts, users or branches in scripts or templates. Placeholders go in templates.
- No cron, launchd or systemd entries. Persistence is the owner's decision per fleet.
- No secrets in any file. `fleet.conf` holds host access, not credentials, and ssh uses keys.

## Checks before a commit

```sh
bash -n scripts/fleet && bash -n scripts/watchdog.sh
shellcheck -S warning scripts/fleet scripts/watchdog.sh
jq . .claude-plugin/*.json >/dev/null
rg -n '\x{2013}|\x{2014}' .   # must find nothing: no en or em dashes anywhere
```

A behaviour change also needs a smoke test on a real Linux host with a scratch fleet. Use its own `FLEET_DIR` and session names, and remove it afterwards:

1. `fleet init /tmp/fleet-test`, point `fleet.conf` at the host, one agent row.
2. `fleet sync` and `fleet watchdog dry`. Both must exit 0 with no bash errors.
3. `fleet send` to a plain tmux session (`tmux new-session -d -s <name> cat`) must deliver. With `Do you want to proceed?` on screen it must exit 3.
4. Kill the scratch session and delete the scratch dirs on the host.

Never test against a running fleet's sessions or `FLEET_DIR`. A live `fleet start` launches a real agent with `CLAUDE_ARGS`, so only run it when the owner agrees.

## Style

- Bash 4+, `set -u` in the watchdog, `set -euo pipefail` in `fleet`. Keep it simple: no new dependencies beyond tmux, rg, ssh and coreutils.
- Comments are short and say why. Docs and comments use plain English, short sentences, and no en or em dashes.
- Conventional Commits. Bump `version` in `.claude-plugin/plugin.json` on a user-visible change.
