#!/usr/bin/env node
// =============================================================================
//  check-language.mjs — finds Turkish text left behind after the translation
//
//  Usage:  node tools/check-language.mjs [dir] [--json] [--quiet]
//  Exit:   0 = no untranslated text found | 1 = leftovers found
//
//  The standard was written in Turkish and translated to English. A translation
//  done file by file always leaves residue: a table cell, a code comment, a
//  hint inside an error message. Residue is worse than a fully Turkish document,
//  because a reader who does not know Turkish hits it mid-sentence and cannot
//  tell whether they are missing a rule.
//
//  This is a detector, not a translator. It reports and exits; it never edits.
//
//  Detection has two independent signals, and a line needs only one of them:
//
//    1. Function words. A word list that is unambiguous in Turkish and does not
//       collide with English or with code identifiers ("için", "olan", "değil").
//       This is the reliable signal.
//    2. Turkish-only letters (ğ ı ş İ Ğ Ş) outside the allow list. Note that
//       ö, ü and ç are NOT used as a signal: they appear in German, French and
//       Turkish proper nouns that are meant to stay.
//
//  Intentional Turkish is allowed and listed below: legal terms, identifier
//  names, place names and the worked examples inside the Turkish-data rules,
//  where the point of the example IS the Turkish string.
// =============================================================================

import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { join, relative, resolve, extname } from 'node:path'

const args = process.argv.slice(2)
const asJson = args.includes('--json')
const quiet = args.includes('--quiet')
const ROOT = resolve(args.find((a) => !a.startsWith('--')) ?? '.')

// Unambiguous Turkish function words. Deliberately excludes anything that is
// also an English word, a Go identifier or a common abbreviation.
const KELIMELER = [
  'için', 'olan', 'değil', 'gerek', 'yapıl', 'kullan', 'edilir', 'olmalı', 'olur',
  'ancak', 'çünkü', 'ayrıca', 'yalnızca', 'sadece', 'zaten', 'hiçbir', 'herhangi',
  'şöyle', 'böyle', 'şunlar', 'bunlar', 'nedeni', 'neden', 'sonra', 'önce',
  'zorunlu', 'yasak', 'önerilen', 'kural', 'dosya', 'hata', 'uyarı', 'sürüm',
  'değer', 'alan', 'satır', 'örnek', 'aşağı', 'yukarı', 'içinde', 'üzerine',
  'göre', 'kadar', 'daha', 'çok', 'gibi', 'yani', 'yeni', 'eski', 'başka',
]

// Turkish that is MEANT to stay. Matched case-insensitively as substrings.
const IZINLI = [
  // Legal and identifier terms
  'kvkk', 'tckn', 'vkn', 'nvi', 'nvİ', 'e-devlet', 'mernis', 'tüik', 'iban',
  // Place and product names
  'arnavutköy', 'türkiye', 'turkiye', 'istanbul', 'i̇stanbul', 'clavus', 'twinup',
  'turef', 'itrf', 'bedaş', 'emqx',
  // Worked examples in the Turkish-data rules: the Turkish string IS the example
  'ışık', 'iğne', 'çilek', 'şeker', 'ağrı', 'izmir', 'i̇zmir', 'ıslak',
  'toLocaleLower', 'toLocaleUpper', 'tr-TR', 'tr_TR', 'Collator',
  // The word "Turkish" itself in English prose, plus file names
  'turkish', 'turkce', 'türkçe',
  // Worked examples where the Turkish string is the point of the example:
  // people in the lost-update scenario, the casing table, the rune-vs-byte comment,
  // and the false-positive sample in the secret scanner's documentation.
  'ayşe', 'mehmet', 'ğüşiöç', 'şifreniz', 'i̇stanbul',
  // The casing and collation rules in 18: the Turkish strings ARE the worked example.
  'isparta', 'şişli', 'sarıyer', 'combining dot', 'ç/ğ/i',
  // Detection patterns in the audit tools. These regexes look for Turkish field names in
  // the USER's code, so the Turkish spelling is the thing being searched for, not prose.
  // A Go identifier may be `Ucret` or `Ücret`; both are legal and both must be caught.
  'password|passwd|parola', 'money_field',
]

// The casing table in 18 renders single Turkish letters inside backticks (`ı`, `İ`).
// That shape is unique to the table and would otherwise be flagged line by line.
const HARF_TABLOSU = /`[ıİğĞşŞçÇöÖüÜiI]`/

const TURKCE_HARF = /[ğışĞİŞ]/
const KELIME_RE = new RegExp(`(^|[^a-zçğıöşü])(${KELIMELER.join('|')})([^a-zçğıöşü]|$)`, 'i')

const bulgular = []

function izinli(satir) {
  const alt = satir.toLowerCase()
  if (HARF_TABLOSU.test(satir)) return true
  return IZINLI.some((t) => alt.includes(t.toLowerCase()))
}

function topla(dir, out = []) {
  for (const ad of readdirSync(dir)) {
    if (['node_modules', '.git', 'testdata'].includes(ad)) continue
    const tam = join(dir, ad)
    if (statSync(tam).isDirectory()) topla(tam, out)
    else if (['.md', '.sh', '.mjs', '.yml', '.mdc', ''].includes(extname(ad))) out.push(tam)
  }
  return out
}

if (!existsSync(ROOT)) {
  console.error(`check-language: directory not found: ${ROOT}`)
  process.exit(1)
}

// A single file is a valid target: spot-checking one document after editing it is the
// common case, and walking a directory to reach it is friction.
const hedefler = statSync(ROOT).isDirectory() ? topla(ROOT) : [ROOT]
const taban = statSync(ROOT).isDirectory() ? ROOT : resolve(ROOT, '..')

for (const dosya of hedefler) {
  const rel = relative(taban, dosya)
  // This file necessarily contains the Turkish word list it searches for.
  if (rel.endsWith('check-language.mjs')) continue
  let icerik
  try {
    icerik = readFileSync(dosya, 'utf8')
  } catch {
    continue
  }
  icerik.split(/\r?\n/).forEach((satir, i) => {
    if (!satir.trim() || izinli(satir)) return
    const kelime = KELIME_RE.exec(satir)
    const harf = TURKCE_HARF.test(satir)
    if (!kelime && !harf) return
    bulgular.push({
      dosya: rel,
      satir: i + 1,
      sinyal: kelime ? `word "${kelime[2]}"` : 'Turkish letter',
      metin: satir.trim().slice(0, 110),
    })
  })
}

if (asJson) {
  console.log(JSON.stringify({ total: bulgular.length, findings: bulgular }, null, 2))
  process.exit(bulgular.length ? 1 : 0)
}

const tty = process.stdout.isTTY
const red = tty ? '\x1b[31m' : ''
const grn = tty ? '\x1b[32m' : ''
const dim = tty ? '\x1b[2m' : ''
const nc = tty ? '\x1b[0m' : ''

console.log('backend-standards — leftover Turkish check')
console.log(`root: ${ROOT}`)
console.log()

const perFile = new Map()
for (const b of bulgular) perFile.set(b.dosya, (perFile.get(b.dosya) ?? 0) + 1)

if (perFile.size) {
  console.log(`${'FILE'.padEnd(42)}${'LINES'.padStart(6)}`)
  for (const [f, n] of [...perFile.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`${f.padEnd(42)}${String(n).padStart(6)}`)
  }
  console.log()
  if (!quiet) {
    for (const b of bulgular.slice(0, 60)) {
      console.log(`${red}${b.dosya}:${b.satir}${nc}  ${dim}(${b.sinyal})${nc}`)
      console.log(`   ${b.metin}`)
    }
    if (bulgular.length > 60) console.log(`${dim}... and ${bulgular.length - 60} more${nc}`)
  }
  console.log()
  console.log(`${red}FOUND${nc}  ${bulgular.length} line(s) in ${perFile.size} file(s)`)
  console.log(`${dim}Intentional Turkish (KVKK, TCKN, place names, worked examples) is allowed`)
  console.log(`and listed in this script. Widen that list deliberately, not to silence a hit.${nc}`)
  process.exit(1)
}

console.log(`${grn}CLEAN${nc}  no untranslated Turkish found`)
console.log(`${dim}This is a word-list detector, not proof. It cannot see a sentence that is`)
console.log(`grammatically English but semantically wrong; a human still reads the result.${nc}`)
process.exit(0)
