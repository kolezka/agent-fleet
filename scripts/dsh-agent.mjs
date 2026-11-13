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
let busy = null           // { child, started, step, stopped }
let footer = 0            // footer lines drawn under the scrollback
let sessionId = null
let ctxPct = null
let lastCtrlC = 0
const queue = []

const clip = (s) => s.length > cols() ? s.slice(0, cols() - 1) + '…' : s
const elapsed = (ms) => { const s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60
  return (h ? h + 'h ' : '') + (h || m ? m + 'm ' : '') + (s % 60) + 's' }
function inputShown() {
  if (!input.includes('\n')) return input
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
  if (busy) lines.push(clip('✻ Working… (' + elapsed(Date.now() - busy.started) + ' · step ' + busy.step + (busy.inStep ? ' · thinking' : '') + ' · esc to interrupt)'))
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
  input = ''
  if (!msg.trim()) { redraw(); return }
  print(msg.split('\n').map((l) => '> ' + l).join('\n') + (busy ? '\n  (queued)' : ''))
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
  // Own process group, so an interrupt reaches the tools DSH started too.
  const child = spawn(opt.dsh, args, { stdio: ['pipe', 'pipe', 'pipe'], detached: true })
  busy = { child, started: Date.now(), step: 0, stopped: false, final: null, err: '' }
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
  child.on('close', (code, signal) => {
    if (buf.trim()) event(run, buf)
    busy = null
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
    const d = e.input && (e.input.description || e.input.command || e.input.file_path || e.input.pattern)
    reply(e.tool + (d ? '(' + String(d).split('\n')[0] + ')' : ''))
  } else if (e.type === 'tool_result' && e.status && e.status !== 'completed') reply('tool ' + e.status, '  ⎿')
  else if (e.type === 'final') run.final = e
  else if (e.type === 'error' && e.message) run.err += e.message + '\n'
}

function interrupt() {
  if (!busy || busy.stopped) return
  busy.stopped = true
  const pid = busy.child.pid
  try { process.kill(-pid, 'SIGINT') } catch {}
  setTimeout(() => { try { process.kill(-pid, 'SIGTERM') } catch {} }, 3000).unref()
}

function quit() {
  if (busy) { try { process.kill(-busy.child.pid, 'SIGTERM') } catch {} }
  clearFooter(); out.write('\x1b[?2004l'); process.exit(0)
}

function key(s) {
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (c === '\x1b') {
      if (s.startsWith('\x1b[200~', i)) { inPaste = true; pastes++; i += 5; continue }
      if (s.startsWith('\x1b[201~', i)) { inPaste = false; i += 5; continue }
      if (s[i + 1] === '[' || s[i + 1] === 'O') { // other CSI or SS3 sequence: skip it
        let j = i + 2; while (j < s.length && !/[@-~]/.test(s[j])) j++; i = j; continue }
      interrupt(); continue
    }
    if (inPaste) { input += c === '\r' ? '\n' : c; continue }
    if (c === '\r' || c === '\n') { submit(); continue }
    if (c === '\x15') { input = ''; continue }                       // C-u
    if (c === '\x7f' || c === '\b') { input = input.slice(0, -1); continue }
    if (c === '\x03') {                                                  // C-c: clear, twice on empty exits
      if (input) { input = ''; continue }
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
