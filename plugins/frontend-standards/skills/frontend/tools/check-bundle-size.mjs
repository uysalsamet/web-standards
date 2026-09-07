#!/usr/bin/env node
// check-bundle-size.mjs: bundle budget gate ([PERF-03], [CI-06]).
//
// Usage:
//   node tools/check-bundle-size.mjs <distDir> <budgetFile> [--json]
//
// What it measures: the GZIPPED size of every emitted asset under <distDir>/assets,
// because that is what the browser downloads (nginx serves gzip_static/brotli_static,
// [NGX-07]). Raw byte size on disk is not a user-visible number.
//
// Classification:
//   entry  = the file is referenced from index.html (<script src>, <link href>,
//            <link rel="modulepreload">). It is on the critical path of the first paint.
//   chunk  = everything else: route chunks and shared chunks pulled in on demand.
//
// Budget file shape (see budget.example.json):
//   { "initial": <bytes>, "chunk": <bytes>, "total": <bytes>,
//     "entries": { "<chunk-name-without-hash>": <bytes> } }
//
// Exit codes: 0 = every budget met, 1 = at least one breach or a usage/IO error.
// No dependencies. Node 24 ESM ([VER-01]).

import { gzipSync } from 'node:zlib'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { basename, join, resolve } from 'node:path'

const GZIP_LEVEL = 9 // nginx gzip_static serves precompressed files built at max level.
const ASSET_EXTENSIONS = ['.js', '.css']
// Vite emits `<name>-<hash>.js`. The hash is at least 8 chars. The class deliberately
// excludes "-" so that `react-vendor-Qq11Ww22` strips to `react-vendor`, not to `react`
// (a dash-permitting class matches leftmost and eats the chunk name).
const HASH_SUFFIX = /-[A-Za-z0-9_]{8,}$/
// Matches src="/assets/x.js", href='/assets/y.css', and the same with a relative path.
const HTML_ASSET_REFERENCE = /(?:src|href)\s*=\s*["']([^"']*\/?assets\/[^"']+)["']/g

function fail(message) {
  process.stderr.write(`check-bundle-size: ${message}\n`)
  process.exit(1)
}

function parseArguments(argv) {
  const positional = argv.filter((argument) => !argument.startsWith('--'))
  const json = argv.includes('--json')
  const unknown = argv.filter((a) => a.startsWith('--') && a !== '--json')
  if (unknown.length > 0) fail(`unknown option ${unknown[0]}. Usage: check-bundle-size.mjs <distDir> <budgetFile> [--json]`)
  if (positional.length !== 2) {
    fail('usage: node tools/check-bundle-size.mjs <distDir> <budgetFile> [--json]')
  }
  return { distDir: resolve(positional[0]), budgetFile: resolve(positional[1]), json }
}

function readDist(distDir) {
  let stats
  try {
    stats = statSync(distDir)
  } catch {
    fail(`dist directory not found: ${distDir}. Run "npm run build" first.`)
  }
  if (!stats.isDirectory()) fail(`not a directory: ${distDir}`)

  const assetsDir = join(distDir, 'assets')
  let assetNames
  try {
    assetNames = readdirSync(assetsDir)
  } catch {
    fail(`assets directory not found: ${assetsDir}. The build did not emit hashed assets.`)
  }
  const files = assetNames.filter((name) => ASSET_EXTENSIONS.some((extension) => name.endsWith(extension)))
  if (files.length === 0) {
    fail(`no .js or .css files in ${assetsDir}. An empty build is a build failure, not a passing budget.`)
  }
  return { assetsDir, files }
}

function readBudget(budgetFile) {
  let raw
  try {
    raw = readFileSync(budgetFile, 'utf8')
  } catch {
    fail(`budget file not found: ${budgetFile}. Copy tools/budget.example.json to the repo root as budget.json.`)
  }
  let parsed
  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    fail(`budget file is not valid JSON (${budgetFile}): ${error.message}`)
  }
  for (const key of ['initial', 'chunk', 'total']) {
    if (typeof parsed[key] !== 'number' || !Number.isFinite(parsed[key]) || parsed[key] <= 0) {
      fail(`budget file ${budgetFile}: "${key}" must be a positive number of bytes`)
    }
  }
  const entries = parsed.entries ?? {}
  if (typeof entries !== 'object' || entries === null || Array.isArray(entries)) {
    fail(`budget file ${budgetFile}: "entries" must be an object of { chunkName: bytes }`)
  }
  for (const [name, value] of Object.entries(entries)) {
    if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) {
      fail(`budget file ${budgetFile}: entries["${name}"] must be a positive number of bytes`)
    }
  }
  return { initial: parsed.initial, chunk: parsed.chunk, total: parsed.total, entries }
}

// Entry assets are the ones index.html itself pulls in. Anything else is loaded later,
// so it is measured against the per-chunk budget, not the initial-load budget.
function readEntryNames(distDir) {
  let html
  try {
    html = readFileSync(join(distDir, 'index.html'), 'utf8')
  } catch {
    fail(`index.html not found in ${distDir}. Without it, entry chunks cannot be identified.`)
  }
  const names = new Set()
  for (const match of html.matchAll(HTML_ASSET_REFERENCE)) {
    names.add(basename(match[1]))
  }
  return names
}

function chunkName(fileName) {
  const withoutExtension = fileName.replace(/\.(js|css)$/, '')
  return withoutExtension.replace(HASH_SUFFIX, '')
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`
  return `${(bytes / 1024).toFixed(1)} kB`
}

function measure(assetsDir, files, entryNames) {
  return files
    .map((file) => {
      const gzipped = gzipSync(readFileSync(join(assetsDir, file)), { level: GZIP_LEVEL }).length
      return { file, name: chunkName(file), kind: entryNames.has(file) ? 'entry' : 'chunk', gzipped }
    })
    .sort((a, b) => b.gzipped - a.gzipped)
}

// Longest-prefix match, so an entries key works whether or not the hash itself contains a
// dash: "react-vendor" matches both `react-vendor` and `react-vendor-Ab12-cd`.
function findNamedBudget(name, entries) {
  let matched = null
  for (const key of Object.keys(entries)) {
    if ((name === key || name.startsWith(`${key}-`)) && (matched === null || key.length > matched.length)) {
      matched = key
    }
  }
  return matched
}

function evaluate(assets, budget) {
  const breaches = []
  const rows = assets.map((asset) => {
    // A named entries[] budget always wins; it exists precisely to give a known-large
    // vendor chunk (maplibre) its own line instead of relaxing the generic chunk budget.
    const namedKey = findNamedBudget(asset.name, budget.entries)
    const named = namedKey === null ? null : budget.entries[namedKey]
    const limit = named ?? (asset.kind === 'entry' ? budget.initial : budget.chunk)
    const source = namedKey !== null ? `entries.${namedKey}` : asset.kind === 'entry' ? 'initial' : 'chunk'
    const over = asset.gzipped > limit
    if (over) {
      breaches.push({ scope: asset.file, limit, actual: asset.gzipped, budget: source })
    }
    return { ...asset, limit, source, status: over ? 'OVER' : 'ok' }
  })

  const initialTotal = assets.filter((a) => a.kind === 'entry').reduce((sum, a) => sum + a.gzipped, 0)
  const total = assets.reduce((sum, a) => sum + a.gzipped, 0)
  if (initialTotal > budget.initial) {
    breaches.push({ scope: 'INITIAL (sum of entry assets)', limit: budget.initial, actual: initialTotal, budget: 'initial' })
  }
  if (total > budget.total) {
    breaches.push({ scope: 'TOTAL (all assets)', limit: budget.total, actual: total, budget: 'total' })
  }
  return { rows, initialTotal, total, breaches }
}

function printTable(rows, result, budget) {
  const header = { file: 'FILE', kind: 'KIND', gzip: 'GZIP', limit: 'BUDGET', status: 'STATUS' }
  const printable = rows.map((row) => ({
    file: row.file,
    kind: row.kind,
    gzip: formatBytes(row.gzipped),
    limit: `${formatBytes(row.limit)} (${row.source})`,
    status: row.status,
  }))
  const width = (key) => Math.max(header[key].length, ...printable.map((row) => row[key].length))
  const widths = { file: width('file'), kind: width('kind'), gzip: width('gzip'), limit: width('limit'), status: width('status') }
  const line = (row) =>
    `${row.file.padEnd(widths.file)}  ${row.kind.padEnd(widths.kind)}  ${row.gzip.padStart(widths.gzip)}  ${row.limit.padStart(widths.limit)}  ${row.status}`

  process.stdout.write(`${line(header)}\n`)
  process.stdout.write(`${'-'.repeat(widths.file + widths.kind + widths.gzip + widths.limit + widths.status + 8)}\n`)
  for (const row of printable) process.stdout.write(`${line(row)}\n`)
  process.stdout.write(
    `\ninitial (entry assets): ${formatBytes(result.initialTotal)} / ${formatBytes(budget.initial)}\n` +
      `total   (all assets)  : ${formatBytes(result.total)} / ${formatBytes(budget.total)}\n`,
  )
}

const { distDir, budgetFile, json } = parseArguments(process.argv.slice(2))
const budget = readBudget(budgetFile)
const { assetsDir, files } = readDist(distDir)
const entryNames = readEntryNames(distDir)
const assets = measure(assetsDir, files, entryNames)
const result = evaluate(assets, budget)

if (json) {
  process.stdout.write(
    `${JSON.stringify(
      {
        dist: distDir,
        budgetFile,
        initial: result.initialTotal,
        total: result.total,
        assets: result.rows.map(({ file, name, kind, gzipped, limit, source, status }) => ({
          file,
          name,
          kind,
          gzipped,
          limit,
          budget: source,
          status,
        })),
        breaches: result.breaches,
        ok: result.breaches.length === 0,
      },
      null,
      2,
    )}\n`,
  )
} else {
  printTable(result.rows, result, budget)
  if (result.breaches.length > 0) {
    process.stdout.write('\nBUDGET EXCEEDED:\n')
    for (const breach of result.breaches) {
      const over = breach.actual - breach.limit
      process.stdout.write(
        `  ${breach.scope}: ${formatBytes(breach.actual)} > ${formatBytes(breach.limit)} (${breach.budget}), over by ${formatBytes(over)}\n`,
      )
    }
    process.stdout.write('\nEither make it smaller or raise the budget in a reviewed change with a reason ([PERF-03]).\n')
  } else {
    process.stdout.write('\nAll bundle budgets met.\n')
  }
}

process.exit(result.breaches.length > 0 ? 1 : 0)
