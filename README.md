# agent-fleet

A Claude Code plugin for running several autonomous Claude Code agents in parallel, one per platform, area or ticket. The agents run in tmux on a local or remote Linux host. One Claude session supervises them, and when its context fills up it hands the role to a fresh session. Earlier supervisors stay on as advisors.

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
fleet start && fleet watchdog start && fleet status
fleet monitor-cmd      # arm this with the Monitor tool in the supervisor session
fleet send agent-a msg.txt
fleet broadcast msg.txt                        # one message to every agent
fleet decide "Ship the tablet layout first"    # numbered rule in autonomy.txt, synced and broadcast
fleet handoff sup-2                            # HANDOFF-sup-2.md draft with live fleet data
```

`fleet sync` refuses when a file on the host was edited since the last sync (supervisors edit `autonomy.txt` there). Run `fleet pull <file>` to bring it back and merge, or `fleet sync --force` to overwrite it. A fleet last synced by version 0.1 has no sync manifest yet, so its first sync after the upgrade refuses for every host file that differs from the local copy. Sync checks the host files again in the same host-side step that installs the new copies and aborts if they changed. A host edit in the few milliseconds between that check and the install can still be lost.

## Requirements

- Agent host: Linux, bash 4+, tmux, ripgrep, GNU coreutils, Claude Code.
- Supervisor: bash, ssh access to the host (BatchMode, key-based).

## Install

Add this repo as a marketplace in Claude Code, then install `agent-fleet`. During development you can also load it from the local path.
