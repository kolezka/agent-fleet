# agent-fleet

A Claude Code plugin for supervising a fleet of autonomous Claude Code agents. The agents run in tmux on a Linux or macOS host, or on this machine. See `README.md` for what it does and `skills/agent-fleet/SKILL.md` for the supervisor workflow.

## Layout

- `scripts/fleet`: the CLI. It runs on the supervisor machine (macOS or Linux) and reaches the host through `rx` (bash script over stdin, optional `su - REMOTE_USER`).
- `scripts/dsh-agent.mjs`: terminal front end for `AGENT_KIND=dsh`. Node 20+ built-ins only, no packages. It must keep printing the cues the watchdog reads: `dsh-agent ready`, the `❯` input line, the `Working… (Ns` line and `dsh context (N%)`.
- `scripts/watchdog.sh`: runs on the agent host only, Linux or macOS with bash 4+. Tools that differ between the two go through its portable helpers (`to_epoch`, `pid_cwd`, `disk_avail_g`, `tool_running`); do not add GNU-only flags. When sourced it loads the helpers and returns before the loop. `fleet send`, `fleet start` and `fleet status` depend on that.
- `scripts/smoke-test.sh`: the smoke test against a real host (see below).
- `scripts/test-local.sh`: local checks with a stub ssh and a private tmux server. Add a check there for every bug fix.
- `templates/`: files copied by `fleet init`. `fleet.conf` is sourced by bash on both sides, so it must stay valid bash.
- `skills/agent-fleet/`: the skill and its references. Keep SKILL.md short and put details in `references/`.

## Rules for changes

- Shared logic lives in `watchdog.sh` helpers (`paste_file`, `start_agent`, `dialog_kind`, `user_typing`, `ctx_pct`). `fleet` calls them through `rx_helpers`. Do not copy the logic into `fleet`.
- Never paste into a pane before Claude Code's UI is detected (`launch` waits for the claude process and `bypass permissions on` or `for shortcuts`). A shell prompt such as starship also shows `❯` and would run the pasted text.
- `paste_file` must keep refusing when the message file is empty or blank (exit 6), a permission dialog is open (exit 3) or the input line has typed text (exit 4), must check every tmux call (exit 7), must re-check for a dialog or typed text right before Enter, and must confirm delivery (exit 5 unless the first non-empty line shows up in the pane more often than before the paste).
- The watchdog never approves a permission dialog. It only denies.
- Hard limits belong in each fleet's `autonomy.txt`. Do not hardcode project names, hosts, users or branches in scripts or templates. Placeholders go in templates.
- No cron, launchd or systemd entries. Persistence is the owner's decision per fleet.
- No secrets in any file. `fleet.conf` holds host access, not credentials, and ssh uses keys.

## Checks before a commit

```sh
bash -n scripts/fleet && bash -n scripts/watchdog.sh && bash -n scripts/smoke-test.sh && bash -n scripts/test-local.sh
shellcheck -S warning scripts/fleet scripts/watchdog.sh scripts/smoke-test.sh scripts/test-local.sh
scripts/test-local.sh   # local checks with a stub ssh and a private tmux server, must exit 0
tests/dsh-agent-stub.sh # AGENT_KIND=dsh with a stub dsh, must exit 0
tests/agent-overrides-stub.sh # per-agent folder and arguments, private prompt copies, must exit 0
tests/agent-kind-stub.sh # per-agent AGENT_KIND and DSH_ARGS, must exit 0
node --check scripts/dsh-agent.mjs
jq . .claude-plugin/*.json >/dev/null
rg -n '\x{2013}|\x{2014}' .   # must find nothing: no en or em dashes anywhere
```

A behaviour change also needs a smoke test on a real Linux host with a scratch fleet, and `scripts/smoke-test.sh local` plus `tests/*.sh` on macOS:

```sh
scripts/smoke-test.sh "<REMOTE_SSH>" [REMOTE_USER] [HOST_BASE_DIR]
```

It creates a `fleetsmoke-<random>` fleet with its own `FLEET_DIR` and tmux sessions running `cat`, checks sync, watchdog dry, send (including exit 3, 2 and 6), the sync guard with pull and `--force`, broadcast, decide and handoff, and removes its sessions and dirs on exit. It must exit 0. It never starts claude. Add a check there when you add a command.

Never test against a running fleet's sessions or `FLEET_DIR`. A live `fleet start` launches a real agent with `CLAUDE_ARGS`, so only run it when the owner agrees.

## Style

- Bash 4+, `set -u` in the watchdog, `set -euo pipefail` in `fleet`. Keep it simple: no new dependencies beyond tmux, rg, ssh and coreutils.
- Comments are short and say why. Docs and comments use plain English, short sentences, and no en or em dashes.
- Conventional Commits. Bump `version` in `.claude-plugin/plugin.json` on a user-visible change.
