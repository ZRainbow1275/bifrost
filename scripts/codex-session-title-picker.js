#!/usr/bin/env node

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { spawnSync } = require('child_process');

const GUARDIAN_RESUME_PICKER_VERSION = 'GuardianCodexResumePicker/2026-05-16-title-archive-v3';
const DEFAULT_LIMIT = 50;
const DEFAULT_SCAN_LIMIT = 3000;
const PREVIEW_CHARS = 300;
const SQLITE_PREVIEW_CHUNK_SIZE = 60;
const JSONL_PREFIX_BYTES = 2 * 1024 * 1024;

function usage() {
  console.log(`Usage: node codex-resume-picker.js [options] [query]

Options:
  -q, --query <text>       Filter by title, cwd, id, provider, source, file state, or cli version
  -C, --cwd <path>         Filter by normalized cwd
  -n, --limit <n>          Number of rows to display (default: ${DEFAULT_LIMIT})
      --scan-limit <n>     Number of SQLite rows to inspect (default: ${DEFAULT_SCAN_LIMIT})
      --active-only        Hide archived DB rows
      --include-exec       Include source=exec rows
      --all-sources        Include all source values
      --pick               Prompt for a row and run codex resume <id>
      --resume <n|id>      Resume by displayed index or exact session id
      --dry-run            Print actions without running codex resume or restoring archived files
      --no-restore         Do not copy archived JSONL back before resume
      --json               Print selected rows as JSON
      --doctor             Print local Codex session storage diagnostics
  -h, --help               Show this help

Examples:
  node codex-resume-picker.js --query Inkforge --pick
  node codex-resume-picker.js --cwd D:\\Desktop\\LawSaw --limit 80 --pick
  node codex-resume-picker.js "CREATOR FOUR" --resume 3
`);
}

function parseArgs(argv) {
  const options = {
    query: '',
    cwd: '',
    limit: DEFAULT_LIMIT,
    scanLimit: DEFAULT_SCAN_LIMIT,
    activeOnly: false,
    includeExec: false,
    allSources: false,
    pick: false,
    resumeTarget: '',
    dryRun: false,
    noRestore: false,
    json: false,
    doctor: false,
  };
  const queryParts = [];

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case '-h':
      case '--help':
        usage();
        process.exit(0);
        break;
      case '-q':
      case '--query':
        options.query = argv[i + 1] || '';
        i += 1;
        break;
      case '-C':
      case '--cwd':
        options.cwd = argv[i + 1] || '';
        i += 1;
        break;
      case '-n':
      case '--limit':
        options.limit = positiveInt(argv[i + 1], options.limit);
        i += 1;
        break;
      case '--scan-limit':
        options.scanLimit = positiveInt(argv[i + 1], options.scanLimit);
        i += 1;
        break;
      case '--active-only':
        options.activeOnly = true;
        break;
      case '--include-exec':
        options.includeExec = true;
        break;
      case '--all-sources':
        options.allSources = true;
        break;
      case '--pick':
        options.pick = true;
        break;
      case '--resume':
        options.resumeTarget = argv[i + 1] || '';
        i += 1;
        break;
      case '--dry-run':
        options.dryRun = true;
        break;
      case '--no-restore':
        options.noRestore = true;
        break;
      case '--json':
        options.json = true;
        break;
      case '--doctor':
        options.doctor = true;
        break;
      default:
        queryParts.push(arg);
        break;
    }
  }

  if (!options.query && queryParts.length > 0) {
    options.query = queryParts.join(' ');
  }

  options.query = normalizeText(options.query).toLowerCase();
  options.cwd = normalizeCwd(options.cwd);
  return options;
}

function positiveInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function getCodexHome() {
  return process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
}

function normalizeCwd(value) {
  if (!value) return '';
  return String(value)
    .replace(/^\\\\\?\\/, '')
    .replace(/^\\\?\\/, '')
    .replace(/\\\\/g, '\\')
    .replace(/\//g, '\\')
    .replace(/\\+$/g, '');
}

function normalizeText(value) {
  return String(value || '').replace(/\s+/g, ' ').trim();
}

function truncate(value, maxChars) {
  const normalized = normalizeText(value);
  if (normalized.length <= maxChars) return normalized;
  return `${normalized.slice(0, Math.max(0, maxChars - 3))}...`;
}

function sqliteLiteral(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

function sqliteAvailable() {
  const result = spawnSync(process.env.SQLITE3 || 'sqlite3', ['-version'], {
    encoding: 'utf8',
    windowsHide: true,
  });
  return result.status === 0;
}

function runSqliteJson(dbPath, sql) {
  const sqlite = process.env.SQLITE3 || 'sqlite3';
  const result = spawnSync(sqlite, ['-json', dbPath, sql], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
  });

  if (result.status !== 0) {
    const reason = (result.stderr || result.stdout || '').trim() || `exit ${result.status}`;
    throw new Error(`sqlite3 failed: ${reason}`);
  }

  const output = (result.stdout || '').trim();
  return output ? JSON.parse(output) : [];
}

function latestStateDb(codexHome) {
  const candidates = [];
  try {
    for (const entry of fs.readdirSync(codexHome, { withFileTypes: true })) {
      if (!entry.isFile()) continue;
      const match = entry.name.match(/^state_(\d+)\.sqlite$/);
      if (!match) continue;
      const fullPath = path.join(codexHome, entry.name);
      candidates.push({
        index: Number(match[1]),
        mtimeMs: fs.statSync(fullPath).mtimeMs,
        path: fullPath,
      });
    }
  } catch (_) {
    return '';
  }

  candidates.sort((a, b) => (b.index - a.index) || (b.mtimeMs - a.mtimeMs));
  return candidates[0] ? candidates[0].path : '';
}

function sqliteThreadColumns(dbPath) {
  const rows = runSqliteJson(dbPath, 'pragma table_info(threads);');
  return new Set(rows.map((row) => row.name).filter(Boolean));
}

function columnExpr(columns, name, fallbackSql) {
  return columns.has(name) ? name : fallbackSql;
}

function firstExistingExpr(columns, names, fallbackSql) {
  const existing = names.filter((name) => columns.has(name));
  if (existing.length === 0) return fallbackSql;
  return `coalesce(${existing.join(', ')})`;
}

function updatedMsExpr(columns) {
  const parts = [];
  if (columns.has('updated_at_ms')) parts.push('updated_at_ms');
  if (columns.has('updated_at')) parts.push('updated_at * 1000');
  if (columns.has('created_at_ms')) parts.push('created_at_ms');
  if (columns.has('created_at')) parts.push('created_at * 1000');
  return parts.length > 0 ? `coalesce(${parts.join(', ')})` : '0';
}

function sourceAllowed(row, options) {
  if (options.allSources) return true;
  if (row.source === 'cli' || row.thread_source === 'user') return true;
  return options.includeExec && row.source === 'exec';
}

function collectSessionRows(dbPath, options) {
  const columns = sqliteThreadColumns(dbPath);
  const where = [];
  if (options.activeOnly && columns.has('archived')) where.push('archived = 0');
  const whereSql = where.length > 0 ? `where ${where.join(' and ')}` : '';
  const updatedExpr = updatedMsExpr(columns);
  const sql = `
    select
      ${columnExpr(columns, 'id', "''")} as id,
      ${columnExpr(columns, 'rollout_path', "''")} as rollout_path,
      ${updatedExpr} as updated_ms,
      ${columnExpr(columns, 'source', "''")} as source,
      ${columnExpr(columns, 'thread_source', "''")} as thread_source,
      ${columnExpr(columns, 'model_provider', "''")} as model_provider,
      ${columnExpr(columns, 'cwd', "''")} as cwd,
      ${columnExpr(columns, 'cli_version', "''")} as cli_version,
      ${columnExpr(columns, 'archived', '0')} as archived
    from threads
    ${whereSql}
    order by ${updatedExpr} desc, id desc
    limit ${options.scanLimit};
  `;

  return runSqliteJson(dbPath, sql)
    .filter((row) => row.id && sourceAllowed(row, options))
    .map((row) => ({
      id: row.id,
      rolloutPath: row.rollout_path || '',
      updatedMs: Number(row.updated_ms || 0),
      source: row.thread_source ? `${row.source || '?'}/${row.thread_source}` : row.source || '?',
      sourceRaw: row.source || '?',
      threadSource: row.thread_source || '',
      provider: row.model_provider || '?',
      cwd: normalizeCwd(row.cwd || '?') || '?',
      cliVersion: row.cli_version || '?',
      archived: Number(row.archived || 0) === 1,
      preview: '',
      previewSource: '',
      fileState: 'unknown',
      livePath: row.rollout_path || '',
      archivedPath: '',
    }));
}

function enrichPreviews(dbPath, sessions) {
  if (sessions.length === 0) return;
  const columns = sqliteThreadColumns(dbPath);
  const previewExpr = firstExistingExpr(columns, ['first_user_message', 'title'], "''");
  if (previewExpr === "''") return;

  const byId = new Map(sessions.map((session) => [session.id, session]));
  for (let i = 0; i < sessions.length; i += SQLITE_PREVIEW_CHUNK_SIZE) {
    const ids = sessions.slice(i, i + SQLITE_PREVIEW_CHUNK_SIZE).map((session) => sqliteLiteral(session.id));
    if (ids.length === 0) continue;

    const sql = `
      select
        id,
        substr(${previewExpr}, 1, 900) as preview
      from threads
      where id in (${ids.join(',')});
    `;

    for (const row of runSqliteJson(dbPath, sql)) {
      const session = byId.get(row.id);
      if (!session) continue;
      session.preview = normalizeText(row.preview || '');
      session.previewSource = session.preview ? 'sqlite' : '';
    }
  }
}

function findArchiveManifests(codexHome) {
  const root = path.join(codexHome, 'archived-large-sessions');
  if (!fs.existsSync(root)) return [];

  const manifests = [];
  for (const batch of fs.readdirSync(root, { withFileTypes: true })) {
    if (!batch.isDirectory()) continue;
    const manifestPath = path.join(root, batch.name, 'manifest.json');
    if (fs.existsSync(manifestPath)) manifests.push(manifestPath);
  }
  return manifests;
}

function loadArchiveMap(codexHome) {
  const byOriginal = new Map();
  const byId = new Map();
  const entries = [];

  for (const manifestPath of findArchiveManifests(codexHome)) {
    try {
      const manifestText = fs.readFileSync(manifestPath, 'utf8').replace(/^\uFEFF/, '');
      const manifest = JSON.parse(manifestText);
      for (const entry of manifest.entries || []) {
        if (!entry.original || !entry.archived) continue;
        const original = path.resolve(entry.original);
        const archived = path.resolve(entry.archived);
        const id = sessionIdFromPath(original) || sessionIdFromPath(archived);
        const item = {
          original,
          archived,
          id,
          bytes: Number(entry.bytes || 0),
          lastWriteTime: entry.last_write_time || '',
        };
        entries.push(item);
        byOriginal.set(original.toLowerCase(), archived);
        if (id) byId.set(id, archived);
      }
    } catch (error) {
      console.error(`WARN: cannot read archive manifest ${manifestPath}: ${error.message}`);
    }
  }

  return { byOriginal, byId, entries };
}

function sessionIdFromPath(filePath) {
  const match = String(filePath).match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i);
  return match ? match[1] : '';
}

function resolveFileState(session, archiveMap) {
  const livePath = session.rolloutPath;
  if (livePath && fs.existsSync(livePath)) {
    session.fileState = 'live';
    session.livePath = livePath;
    return;
  }

  const archivedPath = livePath
    ? archiveMap.byOriginal.get(path.resolve(livePath).toLowerCase())
    : archiveMap.byId.get(session.id);
  if (archivedPath && fs.existsSync(archivedPath)) {
    session.fileState = 'archived';
    session.archivedPath = archivedPath;
    return;
  }

  session.fileState = 'missing';
}

function resolveAllFileStates(sessions, archiveMap) {
  for (const session of sessions) resolveFileState(session, archiveMap);
}

function readPrefix(filePath, maxBytes = JSONL_PREFIX_BYTES) {
  const fd = fs.openSync(filePath, 'r');
  try {
    const size = Math.min(fs.statSync(filePath).size, maxBytes);
    const buf = Buffer.alloc(size);
    const bytesRead = fs.readSync(fd, buf, 0, size, 0);
    return buf.toString('utf8', 0, bytesRead);
  } finally {
    fs.closeSync(fd);
  }
}

function textFromContent(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';

  const parts = [];
  for (const part of content) {
    if (!part || typeof part !== 'object') continue;
    if (typeof part.text === 'string') parts.push(part.text);
    if (typeof part.input_text === 'string') parts.push(part.input_text);
    if (part.type === 'input_text' && typeof part.text === 'string') parts.push(part.text);
  }
  return parts.join(' ');
}

function previewFromJsonl(session) {
  const filePath = session.fileState === 'archived' ? session.archivedPath : session.livePath;
  if (!filePath || !fs.existsSync(filePath)) return '';

  try {
    const text = readPrefix(filePath);
    for (const line of text.split(/\r?\n/)) {
      if (!line.includes('"role":"user"') && !line.includes('"role": "user"')) continue;
      try {
        const item = JSON.parse(line);
        const content = item && item.payload && item.payload.content;
        const textValue = textFromContent(content);
        if (textValue) return normalizeText(textValue);
      } catch (_) {
        continue;
      }
    }
  } catch (_) {
    return '';
  }

  return '';
}

function fillMissingPreviewsFromJsonl(sessions) {
  for (const session of sessions) {
    if (session.preview) continue;
    const preview = previewFromJsonl(session);
    if (preview) {
      session.preview = preview;
      session.previewSource = 'jsonl';
    }
  }
}

function walkJsonl(dir) {
  let results = [];
  try {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        results = results.concat(walkJsonl(fullPath));
      } else if (entry.name.endsWith('.jsonl')) {
        results.push(fullPath);
      }
    }
  } catch (_) {}
  return results;
}

function matchQuotedField(prefix, field) {
  const escapedField = field.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(`"${escapedField}"\\s*:\\s*"([^"]+)"`);
  const match = prefix.match(regex);
  return match ? match[1] : '';
}

function matchSource(prefix) {
  const directSource = matchQuotedField(prefix, 'source');
  if (directSource) return directSource;

  if (/"source"\s*:\s*\{/.test(prefix)) {
    if (/"parent_thread_id"\s*:\s*"[^"]+"/.test(prefix)) {
      return 'exec';
    }
    return 'object';
  }

  return '?';
}

function hasSessionMeta(prefix) {
  return /"type"\s*:\s*"session_meta"/.test(prefix);
}

function sessionFromJsonl(filePath, options, archiveEntry) {
  const prefix = readPrefix(filePath, 64 * 1024);
  if (!hasSessionMeta(prefix)) return null;

  const stat = fs.statSync(filePath);
  const timestamp = matchQuotedField(prefix, 'timestamp');
  const source = matchSource(prefix);
  const row = { source, thread_source: '' };
  if (!sourceAllowed(row, options)) return null;

  const id = matchQuotedField(prefix, 'id') || sessionIdFromPath(filePath);
  if (!id) return null;
  const isArchived = Boolean(archiveEntry);
  const livePath = isArchived ? archiveEntry.original : filePath;
  const archivedPath = isArchived ? archiveEntry.archived : '';
  const updatedMs = Number.isFinite(Date.parse(archiveEntry && archiveEntry.lastWriteTime || ''))
    ? Date.parse(archiveEntry.lastWriteTime)
    : stat.mtimeMs || Date.parse(timestamp || '') || 0;

  return {
    id,
    rolloutPath: livePath,
    updatedMs,
    source,
    sourceRaw: source,
    threadSource: '',
    provider: matchQuotedField(prefix, 'model_provider') || '?',
    cwd: normalizeCwd(matchQuotedField(prefix, 'cwd') || '?') || '?',
    cliVersion: matchQuotedField(prefix, 'cli_version') || '?',
    archived: isArchived,
    preview: '',
    previewSource: '',
    fileState: isArchived ? 'archived' : 'live',
    livePath,
    archivedPath,
  };
}

function collectSessionsFromJsonl(codexHome, options, archiveMap) {
  const sessionsDir = path.join(codexHome, 'sessions');
  const seen = new Set();
  const sessions = [];

  for (const filePath of walkJsonl(sessionsDir)) {
    try {
      const session = sessionFromJsonl(filePath, options, null);
      if (!session || seen.has(session.id)) continue;
      sessions.push(session);
      seen.add(session.id);
    } catch (_) {}
  }

  for (const entry of archiveMap.entries) {
    if (!entry.archived || !fs.existsSync(entry.archived)) continue;
    if (entry.id && seen.has(entry.id)) continue;
    try {
      const session = sessionFromJsonl(entry.archived, options, entry);
      if (!session || seen.has(session.id)) continue;
      sessions.push(session);
      seen.add(session.id);
    } catch (_) {}
  }

  sessions.sort((a, b) => b.updatedMs - a.updatedMs || b.id.localeCompare(a.id));
  fillMissingPreviewsFromJsonl(sessions);
  return sessions;
}

function applyFilters(sessions, options) {
  let filtered = sessions;
  if (options.cwd) {
    const expected = options.cwd.toLowerCase();
    filtered = filtered.filter((session) => session.cwd.toLowerCase() === expected);
  }

  if (options.query) {
    const terms = options.query.split(/\s+/).filter(Boolean);
    filtered = filtered.filter((session) => {
      const haystack = [
        session.id,
        session.cwd,
        session.preview,
        session.source,
        session.provider,
        session.cliVersion,
        session.fileState,
      ].join(' ').toLowerCase();
      return terms.every((term) => haystack.includes(term));
    });
  }
  return filtered;
}

function formatUpdatedTime(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '?';
  const date = new Date(ms);
  const pad = (value) => String(value).padStart(2, '0');
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
  ].join('-') + ' ' + [
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds()),
  ].join(':');
}

function printSessions(sessions, options) {
  const visible = sessions.slice(0, options.limit);
  console.log('=== Codex Sessions With Titles ===');
  console.log(`Shown: ${visible.length} / ${sessions.length} (scan-limit=${options.scanLimit})`);
  console.log('');

  visible.forEach((session, index) => {
    const state = session.archived ? `db-archived/${session.fileState}` : session.fileState;
    const title = session.preview ? truncate(session.preview, PREVIEW_CHARS) : '(no title found)';
    console.log(`[${index + 1}] Updated: ${formatUpdatedTime(session.updatedMs)} | ${session.id}`);
    console.log(`    CWD: ${session.cwd}`);
    console.log(`    Title: ${title}`);
    console.log(`    Source: ${session.source} | Provider: ${session.provider} | CLI: ${session.cliVersion} | File: ${state}`);
    console.log(`    Open: codex resume ${session.id}`);
    console.log('');
  });
}

function printableSession(session) {
  return {
    id: session.id,
    updatedMs: session.updatedMs,
    updated: formatUpdatedTime(session.updatedMs),
    cwd: session.cwd,
    title: session.preview,
    source: session.source,
    provider: session.provider,
    cliVersion: session.cliVersion,
    archived: session.archived,
    fileState: session.fileState,
    livePath: session.livePath,
    archivedPath: session.archivedPath,
  };
}

function findSession(sessions, target, limit) {
  if (!target) return null;
  const exact = sessions.find((session) => session.id === target);
  if (exact) return exact;

  const index = Number.parseInt(target, 10);
  if (Number.isFinite(index) && index >= 1 && index <= Math.min(limit, sessions.length)) {
    return sessions[index - 1];
  }
  return null;
}

function ensureSessionFile(session, options) {
  if (session.fileState !== 'archived') return;
  if (!session.livePath || !session.archivedPath) return;

  if (options.noRestore || options.dryRun) {
    console.log(`Would restore archived JSONL: ${session.archivedPath} -> ${session.livePath}`);
    return;
  }

  fs.mkdirSync(path.dirname(session.livePath), { recursive: true });
  fs.copyFileSync(session.archivedPath, session.livePath);
  console.log(`Restored archived JSONL: ${session.livePath}`);
}

function runResume(session, options) {
  ensureSessionFile(session, options);

  const commandText = `codex resume ${session.id}`;
  if (options.dryRun) {
    console.log(commandText);
    return 0;
  }

  const runner = process.platform === 'win32'
    ? { command: 'cmd', args: ['/c', 'codex', 'resume', session.id] }
    : { command: 'codex', args: ['resume', session.id] };

  const result = spawnSync(runner.command, runner.args, {
    stdio: 'inherit',
    env: process.env,
    windowsHide: false,
  });
  return typeof result.status === 'number' ? result.status : 1;
}

async function promptForSession(sessions, options) {
  const visible = sessions.slice(0, options.limit);
  if (visible.length === 0) return 1;

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise((resolve) => {
    rl.question('Select session number or id (blank to cancel): ', resolve);
  });
  rl.close();

  const target = normalizeText(answer);
  if (!target) return 0;

  const session = findSession(sessions, target, options.limit);
  if (!session) {
    console.error(`No matching session for: ${target}`);
    return 1;
  }
  return runResume(session, options);
}

function countFileLines(filePath) {
  if (!fs.existsSync(filePath)) return 0;
  const content = fs.readFileSync(filePath, 'utf8');
  return content.split(/\r?\n/).filter(Boolean).length;
}

function printDoctor(codexHome, dbPath, archiveMap) {
  const historyPath = path.join(codexHome, 'history.jsonl');
  const sessionsDir = path.join(codexHome, 'sessions');
  const sessionFiles = fs.existsSync(sessionsDir) ? walkJsonl(sessionsDir).length : 0;
  const historyLines = countFileLines(historyPath);

  console.log('=== Codex Session Doctor ===');
  console.log(`Picker version: ${GUARDIAN_RESUME_PICKER_VERSION}`);
  console.log(`Codex home: ${codexHome}`);
  console.log(`history.jsonl: ${fs.existsSync(historyPath) ? 'present' : 'missing'} (${historyLines} line(s))`);
  console.log(`sessions/: ${fs.existsSync(sessionsDir) ? 'present' : 'missing'} (${sessionFiles} file(s))`);
  console.log(`state db: ${dbPath && fs.existsSync(dbPath) ? dbPath : 'missing'}`);
  console.log(`sqlite3: ${sqliteAvailable() ? 'available' : 'missing; JSONL fallback will be used'}`);
  console.log(`archive manifests: ${findArchiveManifests(codexHome).length}`);
  console.log(`archived session entries: ${archiveMap.entries.length}`);
  console.log('');
}

function collectSessions(codexHome, options, archiveMap) {
  const dbPath = latestStateDb(codexHome);
  if (dbPath && sqliteAvailable()) {
    try {
      const sessions = collectSessionRows(dbPath, options);
      enrichPreviews(dbPath, sessions);
      resolveAllFileStates(sessions, archiveMap);
      fillMissingPreviewsFromJsonl(sessions);
      return { sessions, dbPath, source: 'sqlite' };
    } catch (error) {
      console.error(`SQLite session index unavailable: ${error.message}`);
    }
  }

  const sessions = collectSessionsFromJsonl(codexHome, options, archiveMap);
  return { sessions, dbPath, source: 'jsonl' };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const codexHome = getCodexHome();
  const archiveMap = loadArchiveMap(codexHome);
  const { sessions, dbPath, source } = collectSessions(codexHome, options, archiveMap);
  const filtered = applyFilters(sessions, options);

  if (options.doctor) {
    printDoctor(codexHome, dbPath, archiveMap);
    console.log(`session source: ${source}`);
    console.log('');
  }

  if (options.json) {
    console.log(JSON.stringify(filtered.slice(0, options.limit).map(printableSession), null, 2));
  } else {
    printSessions(filtered, options);
  }

  if (filtered.length === 0) {
    if (options.cwd) {
      console.error(`No sessions matched cwd: ${options.cwd}`);
      console.error('Tip: try `codex resume --all` or rerun without `--cwd` to see every stored session.');
    }
    process.exit(1);
  }

  if (options.resumeTarget) {
    const session = findSession(filtered, options.resumeTarget, options.limit);
    if (!session) {
      console.error(`No matching session for: ${options.resumeTarget}`);
      process.exit(1);
    }
    process.exit(runResume(session, options));
  }

  if (options.pick) {
    process.exit(await promptForSession(filtered, options));
  }
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
