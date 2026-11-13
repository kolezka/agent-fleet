#!/usr/bin/env node
// dsh-agent.mjs: a terminal front end that lets the agent-fleet watchdog drive DeepSeek Harness.
// DSH has no interactive terminal UI, so this shows Claude Code's screen cues (ready line, ❯ input
// line, "… (12s" working line, "● " replies) and runs each message as one headless DSH turn
// in the same DSH session. No dependencies beyond Node 20+ and the dsh CLI.
// Usage: node dsh-agent.mjs [--name <title>] [--dsh <bin>] [--context-tokens <n>] [-- <dsh args>...]
import { spawn } from 'node:child_process'

const argv = process.argv.slice(2)
const opt = { name: 'dsh agent', dsh: 'dsh', contextTokens: 1000000, extra: [] }
for (let i = 0; i < argv.length; i++) {
  const a = argv[i]
  if (a === '--') { opt.extra = argv.slice(i + 1); break }
  else if (a === '--name') opt.name = argv[++i]
  else if (a === '--dsh') opt.dsh = argv[++i]
  else if (a === '--context-tokens') opt.contextTokens = Number(argv[++i])
  else { process.stderr.write('dsh-agent: unknown argument ' + a + '\n'); process.exit(2) }
}
if (!(opt.contextTokens > 0)) { process.stderr.write('dsh-agent: --context-tokens must be a positive number\n'); process.exit(2) }

const out = process.stdout
const cols = () => Math.max(20, (out.columns || 200) - 1)
let input = ''            // text in the input line, may hold newlines from a paste
let pastes = 0
let inPaste = false
let pasted = false        // the current input holds pasted text
let pend = ''             // an escape sequence cut off at the end of the last read
let pendTimer = null
let busy = null           // { child, started, step, stopped }
let footer = 0            // footer lines drawn under the scrollback
let sessionId = null
let ctxPct = null
let lastCtrlC = 0
const queue = []

// Terminal cells for one code point: wide CJK and emoji ranges take two.
const cellWidth = (cp) => (cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf) || (cp >= 0xac00 && cp <= 0xd7a3) ||
  (cp >= 0xf900 && cp <= 0xfaff) || (cp >= 0xfe30 && cp <= 0xfe4f) || (cp >= 0xff00 && cp <= 0xff60) ||
  (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1faff) || (cp >= 0x20000 && cp <= 0x3fffd) ? 2 : 1
const width = (s) => { let w = 0; for (const ch of s) w += cellWidth(ch.codePointAt(0)); return w }
function clip(s) {
  if (width(s) <= cols()) return s
  let w = 0, r = ''
  for (const ch of s) { const c = cellWidth(ch.codePointAt(0)); if (w + c > cols() - 1) break; r += ch; w += c }
  return r + '…'
}
const elapsed = (ms) => { const s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60
  return (h ? h + 'h ' : '') + (h || m ? m + 'm ' : '') + (s % 60) + 's' }
function inputShown() {
  // Pasted text that does not fit on the line shows as a placeholder, as in Claude Code,
  // so the watchdog can still tell its own paste apart from typing.
  if (!input.includes('\n') && !(pasted && width('❯ ' + input) > cols())) return input
  const n = input.split('\n').length - 1
  return '[Pasted text #' + pastes + ' +' + n + ' lines]'
}
function clearFooter() {
  if (!footer) return
  let s = '\r\x1b[2K'
  for (let i = 1; i < footer; i++) s += '\x1b[1A\r\x1b[2K'
  out.write(s); footer = 0
}
function drawFooter() {
  const lines = []
  // "thinking" tells the watchdog a model step is open: DSH streams no tokens, so the screen can stay still for minutes.
  // "tool" marks an open tool call: in-process and MCP tools have no child process to see.
  if (busy) lines.push(clip('✻ Working… (' + elapsed(Date.now() - busy.started) + ' · step ' + busy.step +
    (busy.inStep ? ' · thinking' : busy.tools.size ? ' · tool' : '') + ' · esc to interrupt)'))
  lines.push(clip('❯ ' + inputShown()))
  out.write(lines.join('\n')); footer = lines.length
}
function redraw() { clearFooter(); drawFooter() }
// Print lines into the scrollback above the footer.
function print(text) { clearFooter(); out.write(text.replace(/\n*$/, '') + '\n'); drawFooter() }
function reply(text, mark = '●') {
  const lines = String(text).replace(/\s+$/, '').split('\n')
  print(lines.map((l, i) => (i ? '  ' : mark + ' ') + l).join('\n'))
}
function status() {
  const parts = ['dsh session ' + (sessionId || 'new')]
  if (ctxPct !== null) parts.push('dsh context (' + ctxPct + '%)')
  print('  ' + parts.join(' · '))
}

function submit() {
  const msg = input
  input = ''; pasted = false
  if (!msg.trim()) { redraw(); return }
  // Echo only the first line: a long message would push it out of the scrollback,
  // and the watchdog looks for that line to confirm delivery.
  const lines = msg.split('\n'), rest = lines.length - 1
  print('> ' + lines[0] + (rest ? '\n  [+' + rest + ' lines]' : '') + (busy ? '\n  (queued)' : ''))
  queue.push(msg)
  if (!busy) next()
}

function next() {
  const msg = queue.shift()
  if (msg === undefined) return
  // Profile options such as --patch must come before the headless options.
  const args = ['--profile', 'headless', ...opt.extra, '--json']
  if (sessionId) args.push('--session-id', sessionId)
  args.push('-')
  // DSH runs its tools in their own process groups and stops them on SIGINT or SIGTERM,
  // so signals go to DSH itself. It stays in our process group, so closing the pane reaches it too.
  const child = spawn(opt.dsh, args, { stdio: ['pipe', 'pipe', 'pipe'] })
  busy = { child, started: Date.now(), step: 0, stopped: false, final: null, err: '', tools: new Set() }
  const run = busy
  child.stdin.end(msg)
  let buf = ''
  child.stdout.on('data', (d) => {
    buf += d
    let i
    while ((i = buf.indexOf('\n')) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 1); if (line.trim()) event(run, line) }
  })
  child.stderr.on('data', (d) => { run.err = (run.err + d).slice(-4000) })
  child.on('error', (e) => { run.err += String(e.message || e) })
  // A tool DSH left behind can hold the output pipe open; do not stay busy for it.
  child.on('exit', () => setTimeout(() => { child.stdout.destroy(); child.stderr.destroy() }, 2000).unref())
  child.on('close', (code, signal) => {
    if (buf.trim()) event(run, buf)
    busy = null
    if (/session\b.*\bdoes not exist/i.test(run.err)) {
      sessionId = null
      reply('dsh session not found, the next message starts a new session')
    }
    if (run.stopped) reply('Interrupted by user', '⎿')
    else if (!run.final) reply('dsh failed (exit ' + (code ?? signal) + '): ' + (run.err.trim().split('\n').slice(-3).join(' ') || 'no output'))
    else if (run.final.reason && !['completed', 'stop'].includes(run.final.reason.kind)) reply('dsh stopped: ' + run.final.reason.kind)
    status()
    next()
  })
}

function event(run, line) {
  let e
  try { e = JSON.parse(line) } catch { return }
  if (e.sessionId && !sessionId) sessionId = e.sessionId
  if (e.type === 'status' && e.phase === 'step_start') { run.step = e.step || run.step + 1; run.inStep = true; redraw() }
  else if (e.type === 'status' && e.phase === 'step_end') {
    run.inStep = false
    if (e.usage && e.usage.totalTokens) ctxPct = Math.min(100, Math.round(e.usage.totalTokens * 100 / opt.contextTokens))
  } else if (e.type === 'text' && e.text) reply(e.text)
  else if (e.type === 'tool_call') {
    run.inStep = false
    run.tools.add(e.callId || 'call')
    const d = e.input && (e.input.description || e.input.command || e.input.file_path || e.input.pattern)
    reply(e.tool + (d ? '(' + String(d).split('\n')[0] + ')' : ''))
  } else if (e.type === 'tool_result') {
    run.tools.delete(e.callId || 'call'); redraw()
    if (e.status && e.status !== 'completed') reply('tool ' + e.status, '  ⎿')
  }
  else if (e.type === 'final') run.final = e
  else if (e.type === 'error' && e.message) run.err += e.message + '\n'
}

function interrupt() {
  if (!busy || busy.stopped) return
  busy.stopped = true
  const child = busy.child
  try { child.kill('SIGINT') } catch {}
  setTimeout(() => { if (child.exitCode === null && child.signalCode === null) try { child.kill('SIGTERM') } catch {} }, 3000).unref()
}

let quitting = false
function quit() {
  if (quitting) return
  quitting = true
  clearFooter(); out.write('\x1b[?2004l')
  if (!busy) process.exit(0)
  // Wait for DSH to stop its tools, so it does not keep working beside a replacement.
  const child = busy.child
  child.on('close', () => process.exit(0))
  try { child.kill('SIGTERM') } catch {}
  setTimeout(() => { try { child.kill('SIGKILL') } catch {}; process.exit(0) }, 4000)
}

// A read can end in the middle of an escape sequence (a long paste arrives in several reads).
// Such a tail waits for the next read; a lone Esc counts as an interrupt only if nothing follows soon.
function incomplete(s, i) {
  if (i + 1 >= s.length) return true
  if (s[i + 1] !== '[' && s[i + 1] !== 'O') return false
  for (let j = i + 2; j < s.length; j++) if (/[@-~]/.test(s[j])) return false
  return true
}
function flushPending() {
  pendTimer = null
  // An unfinished CSI sequence keeps waiting for its end; only a lone Esc acts now.
  if (pend === '\x1b') { pend = ''; interrupt(); redraw() }
}
function key(chunk) {
  if (pendTimer) { clearTimeout(pendTimer); pendTimer = null }
  const s = pend + chunk
  pend = ''
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (c === '\x1b') {
      if (incomplete(s, i)) { pend = s.slice(i); pendTimer = setTimeout(flushPending, 50); break }
      if (s.startsWith('\x1b[200~', i)) { inPaste = true; pasted = true; pastes++; i += 5; continue }
      if (s.startsWith('\x1b[201~', i)) { inPaste = false; i += 5; continue }
      if (s[i + 1] === '[' || s[i + 1] === 'O') { // other CSI or SS3 sequence: skip it
        let j = i + 2; while (!/[@-~]/.test(s[j])) j++; i = j; continue }
      interrupt(); continue
    }
    if (inPaste) { input += c === '\r' ? '\n' : c; continue }
    if (c === '\r' || c === '\n') { submit(); continue }
    if (c === '\x15') { input = ''; pasted = false; continue }      // C-u
    if (c === '\x7f' || c === '\b') { input = input.slice(0, -1); continue }
    if (c === '\x03') {                                                  // C-c: clear, twice on empty exits
      if (input) { input = ''; pasted = false; continue }
      if (Date.now() - lastCtrlC < 2000) quit()
      lastCtrlC = Date.now(); print('  Press Ctrl-C again to exit'); continue
    }
    if (c === '\x04' && !input) quit()
    if (c >= ' ' || c === '\t') input += c
  }
  redraw()
}

if (!process.stdin.isTTY) { process.stderr.write('dsh-agent: needs a terminal (run it in a tmux pane)\n'); process.exit(2) }
process.stdin.setRawMode(true)
process.stdin.setEncoding('utf8')
process.stdin.on('data', key)
process.on('SIGHUP', quit)
process.on('SIGTERM', quit)
out.on('resize', redraw)
setInterval(() => { if (busy) redraw() }, 1000)
out.write('\x1b[?2004h')  // bracketed paste, so a pasted prompt arrives as one message
print('dsh-agent ready: ' + opt.name + ' (' + opt.dsh + ' ' + ['--profile', 'headless', ...opt.extra].join(' ') + ')')
status()
