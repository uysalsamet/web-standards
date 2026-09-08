#!/usr/bin/env node
// =============================================================================
//  check-refs.mjs — internal consistency check for the standard itself
//
//  Usage:  node tools/check-refs.mjs [standardDir] [--json]
//  Exit:   0 = consistent | 1 = at least one broken reference or duplicate id
//
//  The rule documents are written and maintained separately, so the cross
//  references between them rot silently: a rule is renumbered, a file is
//  renamed, an ADR is cited before it is written. This script is what keeps the
//  set honest. It checks:
//
//    1. Every rule id is DEFINED exactly once   (definition = a line starting
//       with **[XXX-NN] followed by MUST / MUST NOT / SHOULD).
//    2. Every rule id REFERENCED anywhere resolves to a definition.
//    3. Rule ids inside one prefix are numbered from 01 without gaps.
//    4. Every relative markdown link points to a file that exists.
//    5. Every prefix used is declared in 00-README.md's prefix table.
//    6. The tools reference only rule ids that exist.
//
//  Code is not prose: fenced blocks and inline code spans are blanked before
//  scanning, so a template that SHOWS a placeholder as an example is not a
//  finding. It reads .md files plus tools/*.sh and tools/*.mjs, so a rule id
//  quoted in a tool's output message is checked too. No dependencies.
// =============================================================================

import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { join, dirname, relative, resolve, extname } from 'node:path'

const args = process.argv.slice(2)
const asJson = args.includes('--json')
const ROOT = resolve(args.find((a) => !a.startsWith('--')) ?? '.')

const RULE_DEF = /^\*\*\[([A-Z][A-Z0-9]*)-(\d{2,3})\]\s*(MUST NOT|MUST|SHOULD NOT|SHOULD)/
const RULE_REF = /\[([A-Z][A-Z0-9]*)-(\d{2,3})\]/g
const PLACEHOLDER = /\[([A-Z][A-Z0-9]*)-(xx|XX|NN|nn)\]/
const MD_LINK = /\[[^\]]*\]\(([^)\s#]+)(?:#[^)]*)?\)/g

// Rule-shaped tokens that are not rule ids. Extend deliberately, not casually.
const NOT_A_RULE = new Set([
  'ADR', 'RFC', 'ISO', 'EPSG', 'WCAG', 'UTF', 'TLS', 'HTTP', 'CVE',
  // Template stand-ins used in the ADR skeleton and in this tool's own docs.
  'XXX', 'YYY', 'ZZZ',
])

const errors = []
const warnings = []
const err = (file, msg) => errors.push({ file, msg })
const warn = (file, msg) => warnings.push({ file, msg })

/**
 * Split into lines with fenced code blocks and inline code spans blanked out.
 * A document that shows a placeholder or a sample rule id inside backticks is
 * documenting the format, not making a dangling reference.
 */
function proseLines(text) {
  let fenced = false
  return text.split(/\r?\n/).map((line) => {
    if (/^\s*```/.test(line)) {
      fenced = !fenced
      return ''
    }
    if (fenced) return ''
    return line.replace(/`[^`]*`/g, '')
  })
}

/** Recursively collect files we care about. */
function collect(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === '.git' || name === 'fixtures') continue
    const full = join(dir, name)
    if (statSync(full).isDirectory()) collect(full, out)
    else if (['.md', '.sh', '.mjs'].includes(extname(name))) out.push(full)
  }
  return out
}

if (!existsSync(ROOT)) {
  console.error(`check-refs: directory not found: ${ROOT}`)
  process.exit(1)
}

const files = collect(ROOT)
const mdFiles = files.filter((f) => f.endsWith('.md'))
if (mdFiles.length === 0) {
  console.error(`check-refs: no markdown files under ${ROOT}`)
  process.exit(1)
}

// --- 1. Collect definitions --------------------------------------------------
/** @type {Map<string, {file: string, line: number}[]>} */
const defs = new Map()
/** @type {Map<string, Set<number>>} */
const byPrefix = new Map()
/** @type {Map<string, Set<string>>} */
const prefixFiles = new Map()

for (const file of mdFiles) {
  const lines = readFileSync(file, 'utf8').split(/\r?\n/)
  lines.forEach((text, i) => {
    const m = RULE_DEF.exec(text)
    if (!m) return
    const [, prefix, num] = m
    const id = `${prefix}-${num}`
    if (!defs.has(id)) defs.set(id, [])
    defs.get(id).push({ file, line: i + 1 })
    if (!byPrefix.has(prefix)) byPrefix.set(prefix, new Set())
    byPrefix.get(prefix).add(Number(num))
    if (!prefixFiles.has(prefix)) prefixFiles.set(prefix, new Set())
    prefixFiles.get(prefix).add(relative(ROOT, file))
  })
}

// --- 2. Duplicate definitions ------------------------------------------------
for (const [id, places] of defs) {
  if (places.length > 1) {
    const where = places.map((p) => `${relative(ROOT, p.file)}:${p.line}`).join(', ')
    err(id, `defined ${places.length} times: ${where}`)
  }
}

// --- 3. One prefix should live in one file -----------------------------------
for (const [prefix, fileSet] of prefixFiles) {
  if (fileSet.size === 1) continue
  // A document may be split into siblings that share a numeric stem (08, 08b, 08c) when it
  // grows too large to read for a narrow task. That is a deliberate split, not drift, so
  // the rule ids stay continuous across them and this is not worth warning about.
  const stems = new Set([...fileSet].map((f) => (/^(\d+)/.exec(f.split(/[\\/]/).pop()) ?? [])[1]))
  if (stems.size === 1 && !stems.has(undefined)) continue
  warn(prefix, `prefix defined across ${fileSet.size} files: ${[...fileSet].join(', ')}`)
}

// --- 4. Numbering gaps -------------------------------------------------------
for (const [prefix, nums] of byPrefix) {
  const sorted = [...nums].sort((a, b) => a - b)
  if (sorted[0] !== 1) warn(prefix, `numbering starts at ${sorted[0]}, expected 01`)
  const gaps = []
  for (let n = sorted[0]; n < sorted[sorted.length - 1]; n++) {
    if (!nums.has(n)) gaps.push(String(n).padStart(2, '0'))
  }
  if (gaps.length) warn(prefix, `missing numbers: ${gaps.join(', ')}`)
}

// --- 5. Unresolved references ------------------------------------------------
/** @type {Map<string, Set<string>>} */
const unresolved = new Map()
for (const file of files) {
  const rel = relative(ROOT, file)
  const body = readFileSync(file, 'utf8')
  const raw = body.split(/\r?\n/)
  const lines = proseLines(body)
  lines.forEach((text, i) => {
    // Definitions are detected on the raw line: a rule's own text usually
    // contains inline code, which proseLines has removed.
    const rawLine = raw[i] ?? ''
    const isDef = RULE_DEF.test(rawLine)
    RULE_REF.lastIndex = 0
    let m
    while ((m = RULE_REF.exec(text))) {
      const [, prefix, num] = m
      if (NOT_A_RULE.has(prefix)) continue
      const id = `${prefix}-${num}`
      if (isDef && rawLine.startsWith(`**[${id}]`)) continue
      if (defs.has(id)) continue
      if (!unresolved.has(id)) unresolved.set(id, new Set())
      unresolved.get(id).add(`${rel}:${i + 1}`)
    }
  })
}
for (const [id, places] of unresolved) {
  const list = [...places]
  const shown = list.slice(0, 4).join(', ')
  err(id, `referenced but never defined (${list.length} place(s)): ${shown}${list.length > 4 ? ', …' : ''}`)
}

// --- 6. Placeholder references left in the text ------------------------------
for (const file of mdFiles) {
  const rel = relative(ROOT, file)
  proseLines(readFileSync(file, 'utf8')).forEach((text, i) => {
    const m = PLACEHOLDER.exec(text)
    if (m) err(rel, `line ${i + 1}: placeholder ${m[0]} was never replaced with a real id`)
  })
}

// --- 7. Broken relative links ------------------------------------------------
for (const file of mdFiles) {
  const rel = relative(ROOT, file)
  // templates/ is copied into a consuming repository, so its relative links resolve at
  // the destination, not here. Checking them in place reports false breakage.
  if (rel.split(/[\\/]/)[0] === 'templates') continue
  // Prose only: a regex or a code sample can look like a markdown link.
  const body = proseLines(readFileSync(file, 'utf8')).join('\n')
  MD_LINK.lastIndex = 0
  let m
  while ((m = MD_LINK.exec(body))) {
    const target = m[1]
    if (/^([a-z][a-z0-9+.-]*:)?\/\//i.test(target) || target.startsWith('mailto:')) continue
    if (!existsSync(resolve(dirname(file), target))) err(rel, `broken link to '${target}'`)
  }
}

// --- 8. Prefix table in 00-README.md ----------------------------------------
const readme = join(ROOT, '00-README.md')
if (existsSync(readme)) {
  const body = readFileSync(readme, 'utf8')
  // The table has several prefix columns per row, so every cell is examined, not
  // just the first one on the line.
  const declared = new Set()
  for (const row of body.split(/\r?\n/).filter((l) => l.trimStart().startsWith('|'))) {
    for (const cell of row.split('|')) {
      const v = cell.trim()
      if (/^[A-Z][A-Z0-9]{1,5}$/.test(v)) declared.add(v)
    }
  }
  for (const prefix of byPrefix.keys()) {
    if (!declared.has(prefix)) {
      warn('00-README.md', `prefix ${prefix} is used but not in the prefix table`)
    }
  }
} else {
  warn('00-README.md', 'not found; prefix table not checked')
}

// --- Report ------------------------------------------------------------------
const totalRules = defs.size
if (asJson) {
  console.log(JSON.stringify({ totalRules, errors, warnings }, null, 2))
  process.exit(errors.length ? 1 : 0)
}

const tty = process.stdout.isTTY
const dim = tty ? '\x1b[2m' : ''
const red = tty ? '\x1b[31m' : ''
const yel = tty ? '\x1b[33m' : ''
const grn = tty ? '\x1b[32m' : ''
const nc = tty ? '\x1b[0m' : ''

console.log('frontend-standards — reference consistency check')
console.log(`root: ${ROOT}`)
console.log(`${mdFiles.length} documents · ${totalRules} rules · ${byPrefix.size} prefixes`)
console.log()
console.log(
  dim +
    [...byPrefix.entries()]
      .sort((a, b) => a[0].localeCompare(b[0]))
      .map(([p, nums]) => `${p}:${nums.size}`)
      .join('  ') +
    nc,
)
console.log()

for (const e of errors) console.log(`${red}ERROR${nc}  ${e.file}\n       ${e.msg}`)
for (const w of warnings) console.log(`${yel}WARN${nc}   ${w.file}\n       ${w.msg}`)

console.log()
if (errors.length) {
  console.log(`${red}FAILED${nc}  ${errors.length} error(s), ${warnings.length} warning(s)`)
  process.exit(1)
}
console.log(`${grn}CONSISTENT${nc}  0 errors, ${warnings.length} warning(s)`)
process.exit(0)
