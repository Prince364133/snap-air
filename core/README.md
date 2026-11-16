# Snapy shared core — format specification

`core/` is the single source of Snapy's data and rules. Two thin runtimes load it:

- **Windows**: the Python engine (`engine/src/core_loader.py`, `engine/src/appdata.py`).
- **Android**: today the same Python via Chaquopy; next, a Dart runtime that implements this document.

A rule, prompt or string changes for both apps from one edit here. `conformance/` proves the
runtimes behave the same. This file is the contract: if code and this file disagree, one of them is a bug.

```
core/
  VERSION            semver of the core format + content
  manifest.json      load order (config fragments, i18n languages, folders)
  rules/             config fragments, deep-merged into one config tree
  intents/           regex patterns by domain and language (+ index.json catalogue)
  prompts/           AI prompts (.md) and their answer schemas (.schema.json)
  tools/tools.json   the assistant's tool catalog
  schemas/           JSON Schema (draft 2020-12) for stored/synced records
  i18n/              UI and reply strings: en hi ta te mr bn
  conformance/       golden cases: input -> expected output
```

All files are UTF-8, LF line endings, no BOM. Every JSON file has a top-level `_meta`
(`schema_version`, `description`) except `schemas/*` (which use `x-schema-version`) and
`conformance/*` (top-level `schema_version`). Keys named `_comment` / `_meta` are documentation:
runtimes ignore them.

## 1. Locating core/

Python looks, in order, for a folder containing `manifest.json`: `$SNAPY_CORE_DIR`;
`<folder holding src/>/core` (Android/Chaquopy and frozen layouts); `<repo>/core`;
`sys._MEIPASS/core` (PyInstaller). The Dart runtime ships `core/` as Flutter assets
(everything except `conformance/`, which is test-only) and reads `manifest.json` first.

## 2. Config tree (`rules/*.json`)

`manifest.json.config` lists fragments in load order. Each fragment is a JSON object; drop
`_meta`, then deep-merge into one tree:

- object + object -> merge recursively; anything else -> set the value.
- **A leaf path may be defined by one fragment only** (one source per fact). Loading fails
  if two fragments define the same non-`_comment` path.
- Read with `config("a.b.c")` = walk the tree by `.`-separated keys; missing -> default/null.

The Python engine merges this tree into its legacy `appdata` tree (Windows-only
`engine/src/data/app.json` first, then core, then the user override `%APPDATA%/SnapAir/app.json`).
So every historical path keeps working: `android.social_apps`, `android.key_actions`,
`android.selectors`, `android.view_types`, `android.contact_aliases`, `android.speech_locales`,
`android.wake_model`, `android.wake_phrases`, `android.app_links`, `android.min_reel_dwell_ms`,
`android.screen_time_refresh_s`, `ordinals`, `emoji_sets`, `web.*`, `cloud.providers`.

| fragment | paths it owns | meaning |
|---|---|---|
| `vocab.json` | `ordinals`, `emoji_sets`, `vocab.*` | word tables (see §4.5, §4.8) |
| `web.json` | `web.youtube_search`, `web.connectivity_check` | URLs |
| `cloud.json` | `cloud.providers` | bring-your-own-key AI providers; `models` tried in order |
| `phone.json` | `android.app_links` (host -> package), `android.key_actions` (desktop shortcut -> phone action), `android.speech_locales` (voice language -> recognizer locale; `auto` = default), `android.wake_model`, `android.wake_phrases`, `android.contact_aliases` (nickname -> names to try, in order) | phone device data |
| `social.json` | `android.social_apps` (`[{package, label, short_video}]`; `short_video` null = no short-video feed), `android.view_types` (Android class -> matcher type; `_clickable_group` = type for clickable containers), `android.selectors` (fixed-script targets: view ids or descriptions, tried in order), `android.min_reel_dwell_ms`, `android.screen_time_refresh_s`, `android.reels_selectors_url`, `android.realcount.reel_detection`, `android.realcount.creator` (creation/messaging screens that are not consumption; `feed_view_ids` when listed are the only counted scroll sources), `android.realcount.health` | Real Count counter |
| `nudges.json` | `android.realcount.nudges` (thresholds, cooldowns in minutes, bedtime/wake `HH:MM`, `navigation_apps`, `quiet` conditions), `android.realcount.intention`, `android.realcount.nudge_copy` | when to nudge, which copy |
| `attention.json` | `windows.attention.*` (Windows browser counter: `sites` catalogue with title/URL regexes — Python dialect, Windows-only —, `distracting_sites`, `count.*`, `chip.soft_limit_items`, `weekly.*`, `reset.steps` (i18n keys), `address_bar_names`, `nudge_copy`), `realcount.web_labels` (labels for browser-counted ids such as `web.youtube.shorts`) | Windows attention; any key it lacks is read from `android.realcount.<key>` (shared nudge timings, limits, `chip.amber_at`, `habits.report_weekday` are defined once there) |
| `limits.json` | `android.realcount.limits` (`near_fraction`, `over_fraction`, `default_daily_min`, `suggested_minutes`, `break_screen_s`), `android.realcount.chip`, `.habits`, `.rules_update` | defaults |

**Limit state** (`limit_state(used_ms, limit_min)`): no limit -> `ok`; `f = used_ms / (limit_min*60000)`;
`f >= over_fraction` -> `over`; `f >= near_fraction` -> `near`; else `ok`.

**Nudge copy**: `nudge_copy[trigger].normal|soft` are lists of i18n keys. Use `soft` once the user
has dismissed `nudges.soften_after_dismissals` nudges today; pick round-robin by the day's nudge count.
No nudge while any `nudges.quiet` condition holds; at most one nudge per `min_gap_min`;
`app_card` at most once per app per `app_card_cooldown_min`.

## 3. Regex dialect (all patterns in `intents/`)

Patterns are written in the **common subset of Python `re` and ECMAScript/Dart `RegExp`**:

- Allowed: literals, classes, `\d \w \s \b` and negations, `(?:...)`, `(...)`, named groups
  **`(?<name>...)`**, lookahead `(?=...)` `(?!...)`, greedy and lazy quantifiers, `{m,n}`, `^ $`,
  `\uXXXX` escapes.
- Forbidden (the loader and the conformance tests reject them): lookbehind `(?<=` `(?<!`,
  atomic `(?>`, possessive `*+ ++ ?+`, inline flags `(?i)`, `\A \Z \z`, Python `(?P<..>)`,
  named backreferences.
- **ASCII semantics**: `\b \w \d \s` are ASCII (as in JS/Dart). Python compiles with `re.ASCII`.
  Consequently `\b` never appears next to Devanagari; Devanagari patterns use
  `(?=$|[\s,.!?।])` or `(?:^|\s)` instead. Dart: `RegExp(src, caseSensitive: !ignoreCase)`.
- **Case**: each intents file has `flags.ignore_case`; apply it to every pattern in that file.
- **Translation**: Python replaces `(?<name>` with `(?P<name>`. Dart/JS use the source as is.
- **Macros**: `{{NAME}}` is replaced (repeatedly, up to 5 passes) by `macros.NAME` from any intents
  file (a macro name is defined once). Computed macro `{{ORDINALS}}` = the keys of config
  `ordinals`, regex-escaped, sorted by length descending, ties in file order, joined with `|`.
- **Matching** is always *search* (first match anywhere); anchors are written in the pattern.
  Inputs are trimmed (no leading/trailing whitespace, no newline), so `$` = end of text.

## 4. Intents (`intents/`)

`index.json` lists the language `files` (order: `en`, `hinglish`, `devanagari`), declares every
domain and its `type`, and holds `slot_values`. Each language file:
`{_meta, flags: {ignore_case}, macros: {}, domains: {name: entries}}`. A domain collects the
entries of all files, in file order.

Some code-mixed patterns live in `en.json` because splitting their English and Hinglish
alternatives into separate entries would change which text they match or capture (first-match
position, single-strip semantics). Pure-Hinglish entries live in `hinglish.json`.

| type | entry | runtime |
|---|---|---|
| `first_match` | `{id, order, pattern, intent?, replace?, …}` | sort all entries by `order` (stable). Try each: the first whose pattern matches wins. Consumers that validate slots may reject a match and continue with the next entry. |
| `any` | `{id, pattern}` | true if any entry matches. |
| `strip` | `{id, pattern}` | for each entry in order, remove its first match. |
| `rewrite` | `{id, pattern, replace}` | for each entry in order, replace **every** match with `replace`. |
| `extract` | `{id, pattern, template, …}` | every matching entry yields a result (§4.7). |
| `fragment` | `{id, pattern}` | an unanchored piece concatenated into a bigger pattern. |
| `words` | `["…"]` | list concatenated across files. |
| `map` | `{"from": "to"}` | merged across files. |

Replace templates: `$1`…`$9` and `${name}`; a group that did not participate is empty.
For `first_match` + `replace` (the Hinglish normaliser) the result is
`text[:start] + expand(replace) + text[end:]`.

### 4.1 `phone` — phone actions

Input: user text with the wake word removed. `t = clean(text)` where
`clean(s) = collapse_whitespace(s.strip(" .,!?:\"'"))`; `low = lower(t)`. Match entries against
`low` in order. On a match, by `intent` (slot text is taken from `t` at the match offsets so the
user's casing survives where noted):

- `whatsapp`, `sms`: `name = clean(slot name)`; reject (continue) if empty or in
  `slot_values.phone.not_names`. -> `{kind, contact: name, text: clean(t[slot text])}`.
- `call`: same name rule -> `{kind: "call", contact, video: low starts with slot_values.phone.video_call_prefix}`.
- `alarm`: parse slot `when` with the time parser (§4.9, same `now`); reject if null ->
  `{kind: "alarm", hour, minute, label: slot_values.phone.alarm_label}`.
- `timer`: `n` = int if digits else `vocab.numbers.phone[lower(n)]`; reject if missing/0.
  Seconds: the first `vocab.timer_units.rules` entry with a prefix that starts `lower(unit)`,
  else `default_seconds`; -> `{kind: "timer", seconds: n * that}`.
- `navigate`: `place = clean(t[slot place])`; empty -> **stop, return null** -> `{kind, place}`.
- `torch`: `{kind, on: lower(state) in slot_values.phone.torch_on}`.
- `panel`: `p = lower(panel)` without `-`; `{kind, panel: slot_values.phone.panel[p] or panel_default}`.
- `type`: `{kind, text: clean(t[slot text])}`.
- `tap`: `target = clean(slot target)`. If `low` starts with `"open "` and no `phone_tap_open_ok`
  pattern matches the target -> **stop, return null** (an app launch, not a tap). Empty target -> null.
  Else `{kind: "tap", target}`.

No entry -> null. Confirmations: `phone_yes` / `phone_no` (`any`, on the trimmed reply).

### 4.2 Hinglish normaliser

`normalize_command(text)`:
1. `t = lower(transliterate(text)).trim()` — `transliteration` map, keys sorted by length descending,
   plain substring replace, in that order.
2. `t = rewrite(normalize_punct, t)`; collapse whitespace; `t = strip(normalize_prefix, t).trim()`;
   `t = strip(normalize_suffix, t)`.
3. First `normalize` entry that matches; none -> **null**.
4. `out = expand(entry, match).trim()`; `out = rewrite(normalize_fillers, out)`.
5. Return `out` if `out != t`, else null.

`is_question_or_creative(text)` = `any(question_or_creative, text.trim())`.
Language: Devanagari present (`script_devanagari`) -> `hi`; else >= 2 distinct `[a-z]+` words of
lower(text) in `hinglish_markers` -> `hinglish`; else the hint if it is not `en`, else `en`.

### 4.3 Command text, polite words

`normalize_text(s)`: lower, trim, `’`->`'`, `-`->space, each run of `"“”.,!?;:()` -> space,
collapse whitespace, trim.
`plain(cmd)` = `strip(polite_prefix)`, trim, `strip(polite_suffix)`, trim; empty -> `cmd`.
`plain_original(text)` = `strip(polite_prefix_original, text)` trimmed; empty -> `text`.
Assistant turns first apply `strip(assistant_polite, text.trim())`.

### 4.4 Ordinals (`ordinal`)

Input: a normalised command. For each entry in order: on a match take slot `n` (digits -> int,
else `config ordinals[n]`); `keep` = slot `keep` or "". `rest = collapse_ws(cmd[:start] + keep +
" " + cmd[end:]).strip(" ,")`. If `n` and `rest` are non-empty return `(rest, n)`, else try the
next entry. Nothing -> `(cmd, null)`.

### 4.5 Play requests (`play`)

Pipeline used by the assistant and the conformance suite:
`rest, n = ordinal(plain(normalize_text(text)))`, then `play_request(rest)`:
for each `play` match: `q = strip(play_filler_prefix, trim(slot q))`; `q = strip(play_suffix, q).trim()`;
`q = rewrite(play_fixes, q)`. If every space-separated word of `q` is a digit or in
`play_topicless_words` ∪ keys of `ordinals` -> **return null** (click it on screen, don't search).
If `q` is non-empty and not in `play_reject` -> return `q`; else try the next entry. Nothing -> null.

### 4.6 Wake word

`variants = normalize_text` of each `settings.wake_words`, ∪ `vocab.wake.builtin`, ∪
{name, name without spaces} where `name = normalize_text(settings.agent_name)`; sorted by length
descending, then alphabetically. `norm = normalize_text(text)`. For each variant `v`:
match `^` + fragment(`wake_filler`) + escape(v) + `(?:` + escape(`vocab.wake.optional_suffix`) + `)?\b\s*(.*)$`
-> `(true, trim(group 1))`. Else, if `name` is not builtin and `len(name) >= fuzzy_min_name_len`:
match `^` + filler + `(\S+(?: \S+)?)\s*(.*)$`; for `k` in (word count of name, 1): `cand` = first `k`
words of group 1; if `ratio(sound(cand), sound(name)) >= fuzzy_min_ratio` return
`(true, trim(rest of group-1 words + " " + group 2))`. Else `(false, norm)`.
`sound(w)`: lower; apply `vocab.wake.phonetic` pairs in order (plain replace-all); collapse runs of
the same character to one; drop one final `h`. `ratio` is Python `difflib.SequenceMatcher(None, a, b).ratio()`
(= 2·M/T with Ratcliff/Obershelp matching blocks, no autojunk for these short strings) — the Dart
port must implement that algorithm exactly.

### 4.7 Memory

`memory_extract`: for each entry whose pattern matches (search), `groups` = the non-empty capture
groups in order, each trimmed and with trailing `.` removed; skip if none; text =
`template` with `{0}`, `{1}`… replaced. Fields `category`, `importance`, `key` (null = not keyed).
`memory_secret` (`any`): never store. `memory_self` (`any`): worth sending to the AI for learning.
`memory_explicit`: slot `fact`.

### 4.8 Other domains

`unfinished` (`any`, trimmed text) — wait for the rest of the sentence. `assistant_yes/no/stop/risky`
(`any`). `realcount_*` (§4.10). `meeting_*` (`any`) — no-AI meeting notes.
`task_title_prefix` / `_suffix` (`strip`, in that order, then trim `" ,."`; empty -> original).
`phone_device` (`first_match`, Android only; Windows has no handler) — camera, SOS and meeting
phrases. Input: `lower(text)`, every run of `[.,!?;]` -> one space, whitespace collapsed, trimmed.
The first entry (by `order`) that matches gives `intent` (`capture_video`, `capture_photo`,
`capture_stop`, `sos`, `sos_stop`, `sos_call`, `meeting_start`, `meeting_stop`); its optional
named group `camera` is mapped through `slot_values.phone_device.camera` (lower-cased key;
unmapped -> the word itself; no group -> null).

### 4.9 Time parser `parse_when(text, now)` -> `(when | null, rest)`

Vocabulary: `vocab.numbers.time` (key order is the regex alternation order), `vocab.time.*`.
`low = " " + lower(trim(text)) + " "`. NUMRX = `(\d+(?:\.\d+)?|` + keys joined `|` + `)`.
1. Relative: `\b(?:in|after)\s+NUMRX\s*(seconds?|secs?|minutes?|mins?|m|hours?|hrs?|h)\b`, then
   `\bNUMRX\s*(seconds?|minutes?|mins?|ghante|hours?|hrs?)\s+(?:baad|bad|later|from now)\b`;
   n = number or table value; unit minutes from `unit_minutes` (strip a trailing `s` unless the unit
   is `s`; `ghante` = `hour`; try the full unit then its first 3 letters). First hit sets `when = now + n·minutes`.
2. Day: `\b(tomorrow|kal|day after tomorrow|tonight|this evening|this afternoon|this morning|shaam ko|subah)\b`
   -> `day = today + day_offsets[word] (0 if absent)`; else weekday `\b(?:on |next |this )?(monday|…)\b`
   -> the next such weekday (7 days ahead if today).
3. Clock (if `when` unset): `\b(?:at|by|@)\s*(\d{1,2})(?::|\.)?(\d{2})?\s*(a\.?m\.?|p\.?m\.?)?(?=\W)`, else
   `\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)(?=\W)`, else `\b(\d{1,2}):(\d{2})()(?=\W)`.
   (Hinglish "7 baje" is NOT a clock time yet: "subah 7 baje" -> the part-of-day default 9:00, or now + past_day_fallback_min once that has passed.) Hour <= 23 only. Clock rule: am/pm adjusts (pm & h<12 -> +12; am & 12 -> 0). With a day: that day at h:m.
   Without a day and without am/pm and h <= 12: candidates [h, h+12] (h<12) or [h]; if
   `afternoon_first_hours[0] <= h <= [1]` try h+12 first; first candidate after `now`, else the first + 1 day.
   Without a day otherwise: today, +1 day if not after `now`.
4. `noon|midday|midnight` (optional `at `): 12:00 / 00:00 on day or today, +1 day if not after now.
5. Only a day: hour = `day_default_hours[day word]` or `fallback_hour`; a `part_of_day_hours` word
   anywhere overrides; if not after `now` -> `now + past_day_fallback_min`.
6. `rest`: remove the matched time span; if `when` is set also remove day words and weekdays;
   collapse whitespace; strip `" ,."`.

### 4.10 Usage questions (Real Count)

`classify(text)` on `lower(trim(text))`: `period` = `slot_values.realcount.period[first realcount_period
slot]` or `period_default`; `app` = slot `app` or `app2` of the first `realcount_app` match (last word
only when the entry has `last_word: true`); `reels` / `videos` / `screen` = `any`. Answer order: `app`
(if it resolves to a known package, by label or package) -> time on app; else `reels` (shorts/reels only,
from day files' `apps`); else `videos` (long videos, from day files' `videos.{id}.{count,ms}`); else
`screen`; else not a usage question. Days/end: `period_days`, `period_end_offset_days` from "today"
(injectable). Labels: the app list from `android.social_apps`, then `realcount.web_labels`, else the last
package segment title-cased. Copy: i18n `realcount.*`.

Day files (`attention_day` schema): `YYYY-MM-DD.json` `{apps: {id: {reels, reel_ms}}, videos: {id: {count, ms}}}`,
`usage-YYYY-MM-DD.json` `{screen_ms, per_app_ms, opens}`. Weekly summary: the last 7 days ending today vs
the 7 before; when there is no usage file in the week the screen-time/social clause is omitted
(`realcount.weekly_no_screen`), never reported as 0.

## 5. Prompts (`prompts/`)

`<name>.md` is used verbatim after removing trailing newlines; `{{var}}` placeholders are replaced
by plain substring replace (unknown ones stay). `system.md` takes `{{agent_name}}` and `{{tools}}`
(§6). Others: `answer_from_web`, `extract_memory`, `meeting_summary`, `screen_task`, `pick_video`,
`read_page`, `clipboard` (`{{task}}` from `clipboard_tasks.json`, `{{language}}` =
`vocab.language_names[lang]`), `reply_language_devanagari` (the reply-language line when speaking
Hindi/Hinglish), `command_rewrite` (`{{phrase}}`), `nudge_tone` (`{{agent_name}} {{language}} {{soften_after}}`).
`*.schema.json` are the JSON answers the AI must produce; for `extract_memory.schema.json` the
runtime injects `category.enum` from `schemas/memory_fact.schema.json`.

## 6. Tools (`tools/tools.json`)

The AI answers `{say, tool, args}` (`say` first so speech can start while streaming).
`tool` ∈ `["none"] + tools[].name` (catalog order). `args` properties = `args` map
(`{name: {type}}`). Each tool: `name`, `description`, `args` (names it uses), `platforms`, and
`prompt` — its exact text for the model. `{{tools}}` in `system.md` =
`prompt_layout` rows, each row's prompts joined with `" | "`, rows joined with `"\n"`.
(`screen.goal` is described in the prompt but not in the `args` schema, on purpose.)

## 7. Records (`schemas/`)

JSON Schema draft 2020-12: `memory_fact`, `task`, `note`, `activity_day`, `attention_day`,
`settings_profile`. Every record has `schema_version` (integer = the schema's `x-schema-version`).
Records with `x-synced: true` also carry `id`, `updated` (ISO-8601 in UTC with an explicit
offset, e.g. `2026-11-16T04:30:00+00:00`; never naive local time, so devices in different
time zones or across a DST change compare correctly), `device`, `deleted`
(tombstone; deletions are kept so they sync). Merge rule: newer `updated` wins; on a tie the
lexically greater `device`. Runtimes must accept and preserve unknown fields.

Shapes both runtimes store (and must read): a meeting note's `transcript` is an array of
`{t, who, text}` segments (`t` = seconds from the start). Notes written before 2026-11 by the
Windows engine hold one string there; readers accept both (`src/life/notes.transcript_text`,
the HUD's `transcriptText`). A memory's `category` is always one of the schema's enum values:
intent rules that extract memories use those values only (`Works as …` / `Works at …` are
`fact`), and an unknown category is stored as `fact`.

## 8. Strings (`i18n/`)

Flat `{key: string}` per language (`manifest.i18n.languages`); `en` is complete and the fallback.
Keys are stable: never rename, only add (minor bump) or remove (major bump). Placeholders `{name}`
(letters, digits, `_`); every language has exactly the placeholders of `en`. A language may
omit keys (not yet translated: they show in English) but never has a key `en` lacks; the
Kotlin/Flutter screen strings (formerly `mobile/assets/i18n/en.ui.json`) are in `en` only for now.
Lookup: language -> `en` -> the key itself. Strings may contain `\n`, and a leading space when they are appended to
another string (e.g. `realcount.screen_avg`).

## 9. Conformance (`conformance/*.json`)

`{suite, schema_version, doc, cases: [{id, input, expect, now?, settings?, domain?}]}`.
A runtime passes when, for every case, its output **deep-equals** `expect` (JSON types: `null`,
booleans, integers vs strings matter; object key order does not). Per suite:

| suite | run | expect |
|---|---|---|
| `phone_intents` | `phone.parse(input, now)` | `{action}` (§4.1; null = none) |
| `yes_no` | `any(domain, trim(input))` | `{match}` |
| `hinglish` | normaliser, question check, language (§4.2, no hint) | `{command, question_or_creative, lang}` |
| `polite` | `plain(normalize_text(input))`, `plain_original(input)` | `{plain, plain_original}` |
| `ordinal` | `ordinal(normalize_text(input))` | `{rest, n}` |
| `play` | §4.5 pipeline | `{q, n}` |
| `time_parse` | `parse_when(input, now)` | `{when: "YYYY-MM-DDTHH:MM" or null, rest}` |
| `realcount` | `classify(input)` | `{period, app, reels, videos, screen}` |
| `realcount_answer` | write each `files` entry (name -> JSON) into an empty folder; today = `today`; `weekly` ? `weekly_summary(lang)` : `answer(input, lang)` (`lang` default `en`) | `{answer}` (string or null) |
| `wake` | §4.6 with `settings` over defaults `{agent_name: "Snapy", wake_words: ["snapy","snappy","hey snapy","snap"]}` | `{heard, rest}` |
| `unfinished` | `any(unfinished, trim(input))` | `{unfinished}` |
| `memory` | §4.7 on `input`; `secret` = any(memory_secret) | `{secret, extract: [{key,text,category,importance}], explicit}` |
| `task_title` | §4.8 title cleaning | `{title}` |
| `phone_device` | §4.8 `phone_device` | `{intent, camera}` (null = none) |

`now` is a local ISO time without offset; the runtime must use it instead of the clock.
Python: `engine/tests/test_conformance.py` (prints failing ids). The Dart runtime must run every file;
a new case is added for every bug fixed in either runtime.

## 10. Versioning

`VERSION` is semver. **Minor** for additive changes (new keys, entries, strings, cases, domains,
optional fields) — old runtimes keep working. **Major** for breaking changes (removed/renamed keys or
domains, changed field meaning, changed matching rules in this document). **Patch** for content fixes
that change no format (a better translation, a corrected pattern with its new golden). A runtime
refuses a core whose major version it does not know.
