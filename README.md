# agent-fleet

A Claude Code plugin for running several autonomous Claude Code agents in parallel, one per platform, area or ticket. The agents run in tmux on this machine or on a remote host, Linux or macOS. One Claude session supervises them, and when its context fills up it hands the role to a fresh session. Earlier supervisors stay on as advisors.

It grew out of a 48 h run of four TV-platform agents (Apple TV, Android TV, Fire TV, Samsung TV). Inside each agent, use [phased-delivery](https://github.com/kolezka/phased-delivery).

## What is in it

- `skills/agent-fleet/SKILL.md`: the supervisor workflow (setup, supervise, relay, verify, hand off, advise).
- `scripts/fleet`: the CLI. It runs on the Mac or on the host, and reaches the host over ssh via `fleet.conf`.
- `scripts/smoke-test.sh`: tests the CLI against a real host with a scratch fleet. It never starts claude and cleans up after itself.
- `scripts/watchdog.sh`: runs on the agent host. Every 60 s it nudges idle agents, nudges and then replaces stalled ones, recreates missing sessions, denies permission dialogs, warns on low disk, rotates agents at `CTX_MAX`% context, and exits at `END_AT`.
- `templates/`: `fleet.conf`, `autonomy.txt` (the standing rule and hard limits appended to every agent prompt), `idle-nudge.txt`, `ctx-handoff.txt`, `agent.example.txt`.

## Quick start

```sh
fleet init ~/Development/myproj/myfleet && cd ~/Development/myproj/myfleet
# edit fleet.conf, write one prompt file per agent, edit hard limits in autonomy.txt
fleet sync && fleet watchdog dry
# once, by hand on the host: run claude in AGENT_CWD and answer the workspace trust question
fleet start && fleet watchdog start && fleet status
fleet monitor-cmd      # arm this with the Monitor tool in the supervisor session
fleet send agent-a msg.txt
fleet broadcast msg.txt                        # one message to every agent
fleet decide "Ship the tablet layout first"    # numbered rule in autonomy.txt, synced and broadcast
fleet handoff sup-2                            # HANDOFF-sup-2.md draft with live fleet data
```

`fleet sync` refuses when a file on the host was edited since the last sync (supervisors edit `autonomy.txt` there). Run `fleet pull <file>` to bring it back and merge, or `fleet sync --force` to overwrite it. A fleet last synced by version 0.1 has no sync manifest yet, so its first sync after the upgrade refuses for every host file that differs from the local copy. Sync checks the host files again in the same host-side step that installs the new copies and aborts if they changed. A host edit in the few milliseconds between that check and the install can still be lost.

## Requirements

- Agent host: Linux or macOS, bash 4+ (on macOS: `brew install bash`), tmux, ripgrep, Claude Code. GNU coreutils are not needed.
- Supervisor: bash, ssh access to the host (BatchMode, key-based).

## Install

The two machines need different things. The supervisor runs the CLI and the skill. The agents need phased-delivery, and `fleet sync` delivers the watchdog.

| What | Supervisor machine (e.g. your Mac) | Agent host |
|---|---|---|
| `agent-fleet` plugin | Install it. It gives the skill and `scripts/fleet`. | Not needed. Agents do not supervise. |
| `phased-delivery` plugin | Only if you also run phased work in this session. | Install it in the agents' Claude config dir (`CLAUDE_CONFIG_DIR` if set). Each agent uses it, and a replaced agent resumes from its `run.md`. |
| `watchdog.sh`, prompts, `autonomy.txt` | Edit them in the local fleet dir. | `fleet sync` copies them to `FLEET_DIR`. Do not install them by hand. |
| Tools | bash, ssh with a key to the host (BatchMode). `tmux` and `rg` for `scripts/test-local.sh`. | Linux or macOS, bash 4+, tmux, ripgrep, Claude Code. |
| One-time step | None. | Open `claude` once in `AGENT_CWD` and answer the workspace trust question. `fleet start` refuses until this is done. |

Steps:

1. On the supervisor machine, add the `kolezka` marketplace (github `kolezka/marketplace`) in Claude Code if it is not there yet, then install `agent-fleet`. This repo is private, so installing needs Git access to it.
2. On the agent host, as the user the agents run as, install `phased-delivery` from the same marketplace into the config dir the agents use.
3. On the agent host, trust `AGENT_CWD` once by hand, as in the table.
4. Back on the supervisor machine: `fleet init`, `fleet sync`, `fleet watchdog dry`, then `fleet start`. See Quick start.

During development you can load the plugin from a local checkout instead of the marketplace.

### Local only (one machine)

Agents, watchdog and supervisor can all run on one machine, for example your Mac:

- In `fleet.conf` leave `REMOTE_SSH=` and `REMOTE_USER=` empty, and set `FLEET_DIR` and `AGENT_CWD` to local paths. `FLEET_DIR` can be the local fleet dir itself.
- Install both plugins on that machine: `agent-fleet` for the supervisor and `phased-delivery` for the agents.
- macOS needs a bash 4+ for the watchdog (`brew install bash`). `fleet watchdog start` runs it under `caffeinate -i`, so the machine does not sleep while agents work.
- Trust `AGENT_CWD` once by hand, as on a remote host.

Switching between local and remote is only `fleet.conf`: set `REMOTE_SSH` (and `REMOTE_USER` if you ssh as another user) to run the same fleet on a host.

### The fleet's own tmux server

Each fleet runs on its own tmux server, `tmux -L fleet-<FLEET>`, started without your tmux config. Hooks in your config (for example ones that add sidebar panes to every new window) would otherwise put the watchdog on the wrong pane. So `tmux ls` and `tmux attach` do not show the agents. Use `fleet attach <agent>`, or `tmux -L fleet-<FLEET> attach -t <agent>`. `fleet attach --read-only <agent>` attaches with `tmux attach -f read-only,ignore-size`: keys other than detach are dropped and the agent window keeps its size, which suits viewers such as a web console. Set `FLEET_TMUX_SOCKET=` (empty) in `fleet.conf` to use your default tmux server instead.
