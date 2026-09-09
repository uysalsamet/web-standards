#!/usr/bin/env node
// check-i18n.mjs — locale parity checker. Contract: 09-I18N.md §12, tools/README.md.
//
// Usage:
//   node tools/check-i18n.mjs <localesDir> [--src <srcDir>] [--default tr] [--json]
//
// Reads <localesDir>/<lng>/<namespace>.json. A file named <namespace>.json contributes keys
// prefixed with "<namespace>." (parking.json -> parking.list.title). The legacy file
// translation.json contributes keys without a prefix; a top-level { "translation": {...} }
// wrapper inside it is unwrapped. Every locale is compared against the default locale.
//
// Exit codes: 0 no errors, 1 any error (parity, JSON, IO), 2 invalid arguments.
// Node 24, ESM, no dependencies.

import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs'
import { join, basename, extname, resolve } from 'node:path'

const PLURAL_SUFFIXES = ['zero', 'one', 'two', 'few', 'many', 'other']
const PLURAL_RE = new RegExp(`^(.*)_(${PLURAL_SUFFIXES.join('|')})$`)
const PLACEHOLDER_RE = /\{\{\s*([^{},\s]+)\s*(?:,[^}]*)?\}\}/g
const NESTED_RE = /\$t\(\s*([^),\s]+)/g
const SOURCE_EXT = new Set(['.ts', '.tsx', '.js', '.jsx', '.mts', '.cts'])
const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', '.git', 'coverage'])
const TEXT_LIST_LIMIT = 40

// ---------- CLI ----------

function parseArgs(argv) {
  const opts = { localesDir: null, srcDir: null, defaultLng: 'tr', json: false }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--src') opts.srcDir = argv[++i]
    else if (a === '--default') opts.defaultLng = argv[++i]
    else if (a === '--json') opts.json = true
    else if (a.startsWith('--')) usage(`unknown option ${a}`)
    else if (!opts.localesDir) opts.localesDir = a
    else usage(`unexpected argument ${a}`)
  }
  if (!opts.localesDir) usage('missing <localesDir>')
  if (!opts.defaultLng) usage('--default needs a value')
  if (opts.srcDir === undefined) usage('--src needs a value')
  return opts
}

function usage(msg) {
  process.stderr.write(`check-i18n: ${msg}\nusage: node tools/check-i18n.mjs <localesDir> [--src <srcDir>] [--default tr] [--json]\n`)
  process.exit(2)
}

// ---------- Loading ----------

function parseJsonFile(file, report) {
  let text = readFileSync(file, 'utf8')
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1) // BOM
  try {
    return JSON.parse(text)
  } catch (err) {
    const m = /position (\d+)/.exec(err.message)
    let where = ''
    if (m && !/line \d+/.test(err.message)) { // Node 24 already appends "(line L column C)"; older runtimes do not
      const pos = Number(m[1])
      const before = text.slice(0, pos)
      const line = before.split('\n').length
      const col = pos - before.lastIndexOf('\n')
      where = ` (line ${line}, column ${col})`
    }
    report.errors.push({ type: 'invalidJson', file, message: `${err.message}${where}` })
    return null
  }
}

// Flattens { a: { b: "x" } } into Map("a.b" -> "x"). Non-string leaves are reported.
function flatten(obj, prefix, file, report, out = new Map()) {
  for (const [k, v] of Object.entries(obj)) {
    const key = prefix ? `${prefix}.${k}` : k
    if (typeof v === 'string') out.set(key, v)
    else if (v && typeof v === 'object' && !Array.isArray(v)) flatten(v, key, file, report, out)
    else report.errors.push({ type: 'nonStringValue', file, key, message: `value is ${Array.isArray(v) ? 'array' : v === null ? 'null' : typeof v}` })
  }
  return out
}

function loadLocale(dir, lng, report) {
  const files = readdirSync(join(dir, lng)).filter((f) => extname(f) === '.json').sort()
  const keys = new Map() // flatKey -> { value, file }
  for (const f of files) {
    const file = join(dir, lng, f)
    const ns = basename(f, '.json')
    let data = parseJsonFile(file, report)
    if (data === null) continue
    if (!data || typeof data !== 'object' || Array.isArray(data)) {
      report.errors.push({ type: 'invalidJson', file, message: 'top level must be an object' })
      continue
    }
    let prefix = ns
    if (ns === 'translation') {
      prefix = ''
      const top = Object.keys(data)
      if (top.length === 1 && top[0] === 'translation' && data.translation && typeof data.translation === 'object') data = data.translation
    }
    for (const [key, value] of flatten(data, prefix, file, report)) {
      if (keys.has(key)) report.errors.push({ type: 'duplicateKey', locale: lng, file, key, message: `also defined in ${keys.get(key).file}` })
      keys.set(key, { value, file })
    }
  }
  return { lng, files, keys }
}

// ---------- Checks ----------

function placeholders(value) {
  const set = new Set()
  for (const m of value.matchAll(PLACEHOLDER_RE)) set.add(m[1])
  return set
}

function sameSet(a, b) {
  return a.size === b.size && [...a].every((x) => b.has(x))
}

function checkValues(locale, report) {
  const byValue = new Map()
  for (const [key, { value, file }] of locale.keys) {
    if (value.trim() === '') report.errors.push({ type: 'emptyValue', locale: locale.lng, file, key })
    if (value === key) report.errors.push({ type: 'valueEqualsKey', locale: locale.lng, file, key })
    for (const m of value.matchAll(NESTED_RE)) {
      const ref = m[1].replace(/^['"]|['"]$/g, '')
      if (!locale.keys.has(ref)) report.errors.push({ type: 'nestedKeyMissing', locale: locale.lng, file, key, message: `$t(${ref}) not found` })
    }
    const list = byValue.get(value) ?? []
    list.push(key)
    byValue.set(value, list)
  }
  for (const [value, list] of byValue) {
    // Plural siblings of one base (count_one / count_other) legitimately share a value in Turkish.
    const bases = new Set(list.map((k) => PLURAL_RE.exec(k)?.[1] ?? k))
    if (bases.size > 1 && value.length >= 3) report.warnings.push({ type: 'duplicateValue', locale: locale.lng, value, keys: list })
  }
}

function pluralGroups(keys) {
  const groups = new Map() // base -> Set(suffix)
  for (const key of keys) {
    const m = PLURAL_RE.exec(key)
    if (!m) continue
    const set = groups.get(m[1]) ?? new Set()
    set.add(m[2])
    groups.set(m[1], set)
  }
  return groups
}

function checkPluralsWithin(locale, report) {
  for (const [base, forms] of pluralGroups(locale.keys.keys())) {
    if (!forms.has('other')) report.errors.push({ type: 'pluralMissingOther', locale: locale.lng, key: base, message: `forms present: ${[...forms].join(', ')}` })
  }
}

function compareLocale(def, loc, report) {
  const defPlural = pluralGroups(def.keys.keys())
  const locPlural = pluralGroups(loc.keys.keys())
  // A plural group whose form set differs is ONE finding on the base key, not N missing/extra keys.
  const mismatchedBases = new Set()
  for (const base of new Set([...defPlural.keys(), ...locPlural.keys()])) {
    const a = defPlural.get(base) ?? new Set()
    const b = locPlural.get(base) ?? new Set()
    if (a.size && b.size && !sameSet(a, b)) {
      mismatchedBases.add(base)
      report.errors.push({ type: 'pluralMismatch', locale: loc.lng, key: base, message: `${def.lng}: ${[...a].join('/')}  ${loc.lng}: ${[...b].join('/')}` })
    }
  }
  const inMismatchedGroup = (key) => { const m = PLURAL_RE.exec(key); return m !== null && mismatchedBases.has(m[1]) }

  for (const [key, { value }] of def.keys) {
    const other = loc.keys.get(key)
    if (!other) {
      if (!inMismatchedGroup(key)) report.errors.push({ type: 'missingKey', locale: loc.lng, key })
      continue
    }
    const a = placeholders(value)
    const b = placeholders(other.value)
    if (!sameSet(a, b)) report.errors.push({ type: 'placeholderMismatch', locale: loc.lng, key, message: `${def.lng}: {${[...a].join(', ')}}  ${loc.lng}: {${[...b].join(', ')}}` })
  }
  for (const key of loc.keys.keys()) {
    if (!def.keys.has(key) && !inMismatchedGroup(key)) report.errors.push({ type: 'extraKey', locale: loc.lng, key })
  }
}

// ---------- Source scan ----------

function* walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) yield* walk(join(dir, entry.name))
    } else if (SOURCE_EXT.has(extname(entry.name))) yield join(dir, entry.name)
  }
}

const STATIC_KEY_RE = /\bt\(\s*(['"`])([A-Za-z0-9_.:$-]+)\1/g
const TEMPLATE_KEY_RE = /\bt\(\s*`([A-Za-z0-9_.:-]*?)\$\{/g
const I18NKEY_RE = /i18nKey=\s*(['"])([A-Za-z0-9_.:-]+)\1/g

function normaliseKey(raw) {
  return raw.replace(':', '.') // parking:list.title -> parking.list.title (merged-namespace model)
}

function scanSources(srcDir) {
  const used = new Set()
  const dynamicPrefixes = new Set()
  let fileCount = 0
  for (const file of walk(srcDir)) {
    fileCount++
    const text = readFileSync(file, 'utf8')
    for (const m of text.matchAll(STATIC_KEY_RE)) if (!m[2].includes('$')) used.add(normaliseKey(m[2]))
    for (const m of text.matchAll(I18NKEY_RE)) used.add(normaliseKey(m[2]))
    for (const m of text.matchAll(TEMPLATE_KEY_RE)) dynamicPrefixes.add(normaliseKey(m[1]))
  }
  return { used, dynamicPrefixes, fileCount }
}

/** Does this locale define the key, one of its plural/context forms, or a subtree under it? */
function localeHasKey(locale, used) {
  for (const k of locale.keys.keys()) {
    if (k === used || k.startsWith(`${used}_`) || k.startsWith(`${used}.`)) return true
  }
  return false
}

function checkUsage(def, locales, scan, report) {
  const all = [...def.keys.keys()]
  const covered = new Set()
  // A used key K covers K, K_<plural|context> and K.* (returnObjects). Dynamic prefixes cover everything below them.
  for (const key of all) {
    let hit = false
    for (const u of scan.used) {
      if (key === u || key.startsWith(`${u}_`) || key.startsWith(`${u}.`)) { hit = true; break }
    }
    if (!hit) for (const p of scan.dynamicPrefixes) if (key.startsWith(p)) { hit = true; break }
    if (hit) covered.add(key)
  }
  for (const key of all) if (!covered.has(key)) report.warnings.push({ type: 'unusedKey', locale: def.lng, key })
  // Every locale is checked, not only the default one. Reporting a key as "not in tr"
  // when it is absent everywhere sends the reader to translate one file when the key was
  // never added to any of them, which is a different job with a different fix.
  for (const u of scan.used) {
    const eksik = locales.filter((l) => !localeHasKey(l, u)).map((l) => l.lng)
    if (eksik.length === 0) continue
    const hepsi = eksik.length === locales.length
    report.errors.push({
      type: 'usedKeyMissing',
      locale: hepsi ? '*' : eksik.join(','),
      key: u,
      missingIn: eksik,
      message: hepsi
        ? `used in code, defined in no locale (${eksik.join(', ')})`
        : `used in code, missing from ${eksik.join(', ')}`,
    })
  }
}

// ---------- Output ----------

function countBy(list) {
  const out = {}
  for (const item of list) out[item.type] = (out[item.type] ?? 0) + 1
  return out
}

function printText(report) {
  const w = (s) => process.stdout.write(`${s}\n`)
  w(`check-i18n: ${report.localesDir}`)
  w(`  default locale: ${report.defaultLocale}   locales: ${report.locales.map((l) => `${l.lng} (${l.keyCount} keys, ${l.files.length} files)`).join(', ')}`)
  if (report.scan) w(`  source scan: ${report.scan.fileCount} files, ${report.scan.usedKeys} static keys, ${report.scan.dynamicPrefixes} dynamic prefixes`)
  w('')
  const groups = new Map()
  for (const e of [...report.errors.map((e) => ({ ...e, level: 'ERROR' })), ...report.warnings.map((x) => ({ ...x, level: 'WARN' }))]) {
    const list = groups.get(`${e.level} ${e.type}`) ?? []
    list.push(e)
    groups.set(`${e.level} ${e.type}`, list)
  }
  for (const [name, list] of groups) {
    // Duplicate values are informational and numerous on a large app; keep them from drowning the errors.
    const limit = name.endsWith('duplicateValue') ? 10 : TEXT_LIST_LIMIT
    w(`${name} (${list.length})`)
    for (const item of list.slice(0, limit)) {
      const where = [item.locale, item.key ?? item.file].filter(Boolean).join('  ')
      const detail = item.message ?? (item.keys ? `${JSON.stringify(item.value)} <- ${item.keys.join(', ')}` : '')
      w(`  ${[where, detail].filter(Boolean).join('  ')}`)
    }
    if (list.length > limit) w(`  ... ${list.length - limit} more (use --json for the full list)`)
    w('')
  }
  w(`errors: ${report.errors.length}  warnings: ${report.warnings.length}`)
  w(`by type: ${JSON.stringify({ errors: countBy(report.errors), warnings: countBy(report.warnings) })}`)
}

// ---------- Main ----------

function main() {
  const opts = parseArgs(process.argv.slice(2))
  const report = { localesDir: resolve(opts.localesDir), defaultLocale: opts.defaultLng, locales: [], scan: null, errors: [], warnings: [] }

  if (!existsSync(report.localesDir) || !statSync(report.localesDir).isDirectory()) {
    report.errors.push({ type: 'missingDir', message: `locales directory not found: ${report.localesDir}` })
    return finish(report, opts)
  }
  const lngs = readdirSync(report.localesDir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort()
  if (!lngs.includes(opts.defaultLng)) {
    report.errors.push({ type: 'missingDir', message: `default locale directory not found: ${join(report.localesDir, opts.defaultLng)}` })
    return finish(report, opts)
  }
  if (lngs.length < 2) report.warnings.push({ type: 'singleLocale', message: `only one locale (${lngs[0]}) found; nothing to compare` })

  const locales = lngs.map((lng) => loadLocale(report.localesDir, lng, report))
  const def = locales.find((l) => l.lng === opts.defaultLng)
  for (const loc of locales) {
    report.locales.push({ lng: loc.lng, files: loc.files, keyCount: loc.keys.size })
    checkValues(loc, report)
    checkPluralsWithin(loc, report)
    if (loc !== def) {
      for (const f of def.files) if (!loc.files.includes(f)) report.errors.push({ type: 'missingFile', locale: loc.lng, file: join(report.localesDir, loc.lng, f) })
      for (const f of loc.files) if (!def.files.includes(f)) report.errors.push({ type: 'extraFile', locale: loc.lng, file: join(report.localesDir, loc.lng, f) })
      compareLocale(def, loc, report)
    }
  }

  if (opts.srcDir) {
    const srcDir = resolve(opts.srcDir)
    if (!existsSync(srcDir) || !statSync(srcDir).isDirectory()) {
      report.errors.push({ type: 'missingDir', message: `source directory not found: ${srcDir}` })
    } else {
      const scan = scanSources(srcDir)
      report.scan = { srcDir, fileCount: scan.fileCount, usedKeys: scan.used.size, dynamicPrefixes: scan.dynamicPrefixes.size, dynamicPrefixList: [...scan.dynamicPrefixes].sort() }
      checkUsage(def, locales, scan, report)
    }
  }
  return finish(report, opts)
}

function finish(report, opts) {
  const ok = report.errors.length === 0
  report.ok = ok
  report.summary = { errors: countBy(report.errors), warnings: countBy(report.warnings) }
  if (opts.json) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`)
  else printText(report)
  process.exit(ok ? 0 : 1)
}

main()
