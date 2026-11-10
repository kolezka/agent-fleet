import test from 'node:test'
import assert from 'node:assert/strict'
import { cpSync, existsSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'

const root = resolve(import.meta.dirname, '..')

test('standalone DSH adapter installs its pinned runtime and registers the fleet skill', () => {
  assert.ok(existsSync(join(root, 'dsh/package.json')), 'DSH adapter manifest exists')
  const dir = mkdtempSync(join(realpathSync(tmpdir()), 'agent-fleet-dsh-'))
  try {
    cpSync(root, dir, {
      recursive: true,
      filter: (path) => !['.git', 'node_modules'].includes(path.split('/').at(-1)),
    })
    const manifest = JSON.parse(readFileSync(join(dir, 'dsh/package.json'), 'utf8'))
    assert.equal(manifest.dependencies['claude-plugin-dsh'], '0.1.0')
    assert.ok(!existsSync(join(dir, 'dsh/claude-compat.js')), 'runtime is not vendored')
    const install = spawnSync('bun', ['install', '--frozen-lockfile'], { cwd: join(dir, 'dsh'), encoding: 'utf8' })
    assert.equal(install.status, 0, `frozen install failed: ${install.stderr}`)
    const probe = join(dir, 'dsh/probe.mjs')
    writeFileSync(probe, `
import { createRequire } from 'node:module'
const require = createRequire(new URL('./index.js', import.meta.url))
let runtime
try { runtime = require.resolve('claude-plugin-dsh/package.json') }
catch { console.error('DSH_RUNTIME_RESOLUTION_FAILED'); process.exit(12) }
const version = require('claude-plugin-dsh/package.json').version
const { name, apply } = await import('./index.js')
const providers = []
const ctx = { skills: { registerProvider: create => providers.push(create()) }, inject: (_services, callback) => callback(ctx), on() {} }
await apply(ctx, {})
const candidates = await providers[0].list({})
const candidate = candidates.find(item => item.name === 'agent-fleet')
const skill = candidate && await providers[0].get(candidate, {})
console.log(JSON.stringify({ runtime, version, name, candidate, content: skill?.content }))
`)
    const run = () => spawnSync('node', [probe], { cwd: dir, encoding: 'utf8' })
    const assertRuntimeLoads = (result) => assert.equal(result.status, 0, `runtime resolution failed: ${result.stderr}`)
    const result = run()
    assertRuntimeLoads(result)
    const registration = JSON.parse(result.stdout)
    assert.equal(registration.version, '0.1.0')
    assert.equal(registration.runtime, join(dir, 'dsh/node_modules/claude-plugin-dsh/package.json'))
    assert.equal(registration.name, 'claude-compat-agent-fleet')
    assert.equal(registration.candidate.name, 'agent-fleet')
    assert.match(registration.content, /fleet watchdog dry/)
    assert.match(registration.content, /Arm a Monitor with the output of `fleet monitor-cmd`/)
    console.log(`Installed runtime: ${registration.runtime} (version ${registration.version}); registered ${registration.candidate.name} with fleet watchdog and Monitor instructions`)

    renameSync(join(dir, 'dsh/node_modules/claude-plugin-dsh'), join(dir, 'dsh/node_modules/claude-plugin-dsh-disabled'))
    const missing = run()
    assert.equal(missing.status, 12, missing.stderr)
    assert.throws(() => assertRuntimeLoads(missing), /runtime resolution failed: DSH_RUNTIME_RESOLUTION_FAILED/)
    console.log('Negative control: missing dependency failed the runtime resolution assertion (exit 12)')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
