#!/usr/bin/env node
// Read-only status viewer for pibot agent containers.
//
// It never talks to an agent. Everything it knows comes from two read-only
// volume mounts:
//
//   <root>/sessions/--<cwd>--/<ts>_<id>.jsonl   pi's own session transcripts
//   <runDir>/<run-id>.json + <run-id>.beat      pibot run records + heartbeats
//
// That one-way data flow is the point: the agent sits on an `internal` network
// and cannot reach this process, and this process cannot reach the agent. The
// worst it can do is render a bad web page.
//
// Zero dependencies on purpose -- this image has no egress, and the session
// format is documented and versioned upstream (docs/session-format.md).

import { createServer } from "node:http";
import { execFile } from "node:child_process";
import {
    closeSync,
    existsSync,
    mkdtempSync,
    openSync,
    readdirSync,
    readFileSync,
    readSync,
    realpathSync,
    rmSync,
    statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

const PORT = Number(process.env.PIBOT_STATUS_PORT || 8787);
// Bound to all interfaces *inside the container*; compose publishes it on the
// host loopback only. Widen the publish, not this.
const HOST = process.env.PIBOT_STATUS_HOST || "0.0.0.0";
const TOKEN = process.env.PIBOT_STATUS_TOKEN || "";
const RUN_DIR = process.env.PIBOT_STATUS_RUN_DIR || "/data/pi/agent/.pibot/runs";
const MAX_AGE_DAYS = Number(process.env.PIBOT_STATUS_MAX_AGE_DAYS || 14);
const MAX_SESSIONS = Number(process.env.PIBOT_STATUS_MAX_SESSIONS || 40);
const EXPORT_ENABLED = process.env.PIBOT_STATUS_EXPORT !== "0";
const PI_BIN = process.env.PIBOT_STATUS_PI_BIN || "pi";

const ROOTS = (process.env.PIBOT_STATUS_ROOTS || "/data/pi/agent:/data/omp/agent")
    .split(":")
    .filter(Boolean)
    .map((p) => resolve(p))
    .filter((p) => existsSync(p));

// A run's heartbeat is touched every 5s by the agent entrypoint. Three missed
// beats and we stop claiming the container is alive.
const BEAT_STALE_MS = Number(process.env.PIBOT_STATUS_BEAT_STALE_MS || 20_000);

// Session files are appended to, so we only ever read the bytes we haven't seen.
// A file that has somehow grown past this on first sight gets tail-parsed
// instead, and says so in the UI.
const MAX_FULL_PARSE_BYTES = 32 * 1024 * 1024;
const TAIL_PARSE_BYTES = 4 * 1024 * 1024;
const READ_CHUNK = 1024 * 1024;

const MAX_TEXT = 2000;
const VIEW_TTL_MS = 10 * 60 * 1000;

// ---------------------------------------------------------------- utilities

function truncate(value, limit = MAX_TEXT) {
    const s = typeof value === "string" ? value : value == null ? "" : String(value);
    if (s.length <= limit) return s;
    return `${s.slice(0, limit)}\n… (+${s.length - limit} more characters)`;
}

function textOf(content) {
    if (typeof content === "string") return content;
    if (!Array.isArray(content)) return "";
    return content
        .filter((c) => c && c.type === "text" && typeof c.text === "string")
        .map((c) => c.text)
        .join("");
}

/** One-line description of what a tool call is actually doing. */
function toolSummary(name, args) {
    if (!args || typeof args !== "object") return "";
    switch (name) {
        case "bash":
            return truncate(args.command, 200);
        case "read":
        case "write":
            return truncate(args.path, 200);
        case "edit":
            return truncate(args.path, 200);
        case "glob":
        case "grep":
            return truncate(args.pattern ?? args.query, 200);
        default: {
            try {
                return truncate(JSON.stringify(args), 200);
            } catch {
                return "";
            }
        }
    }
}

/** `--home-user-project--` -> `/home/user/project` is lossy, so prefer the header cwd. */
function projectLabel(cwd, file) {
    if (cwd) return cwd;
    return basename(dirname(file));
}

// ------------------------------------------------------------- session view

/**
 * Incremental fold over one session JSONL file.
 *
 * Entries are kept as small summaries (text truncated) keyed by id, so the
 * parent walk that reconstructs the active branch stays possible without
 * holding whole bash transcripts in memory.
 */
class SessionView {
    constructor(file) {
        this.file = file;
        this.reset();
    }

    reset() {
        this.header = null;
        this.byId = new Map();
        this.order = [];
        this.labels = new Map();
        this.name = undefined;
        this.model = undefined;
        this.provider = undefined;
        this.cost = 0;
        this.tokens = null;
        this.contextWindow = null;
        this.messageCount = 0;
        this.lastActivity = 0;
        this.offset = 0;
        this.size = -1;
        this.mtimeMs = -1;
        this.leftover = Buffer.alloc(0);
        this.truncatedHistory = false;
        this.missing = false;
        this.parseErrors = 0;
    }

    refresh() {
        let st;
        try {
            st = statSync(this.file);
        } catch {
            this.missing = true;
            return this;
        }
        this.missing = false;
        if (st.size === this.size && st.mtimeMs === this.mtimeMs) return this;

        // pi rewrites the whole file in some flush paths, and /tree can shorten
        // it. Anything but pure growth means our offsets are meaningless.
        if (st.size < this.size) this.reset();

        let start = this.offset;
        let dropFirstPartial = false;
        if (start === 0 && st.size > MAX_FULL_PARSE_BYTES) {
            start = st.size - TAIL_PARSE_BYTES;
            dropFirstPartial = true;
            this.truncatedHistory = true;
        }

        const fd = openSync(this.file, "r");
        try {
            const buf = Buffer.allocUnsafe(READ_CHUNK);
            let pos = start;
            let first = dropFirstPartial;
            while (pos < st.size) {
                const bytes = readSync(fd, buf, 0, Math.min(READ_CHUNK, st.size - pos), pos);
                if (bytes <= 0) break;
                pos += bytes;
                let chunk = Buffer.concat([this.leftover, buf.subarray(0, bytes)]);
                const lastNl = chunk.lastIndexOf(0x0a);
                if (lastNl === -1) {
                    this.leftover = chunk;
                    continue;
                }
                const complete = chunk.subarray(0, lastNl).toString("utf8");
                this.leftover = Buffer.from(chunk.subarray(lastNl + 1));
                const lines = complete.split("\n");
                if (first) {
                    // We started mid-file; the first line is half an entry.
                    lines.shift();
                    first = false;
                }
                for (const line of lines) this.#addLine(line);
            }
            this.offset = pos;
        } finally {
            closeSync(fd);
        }

        this.size = st.size;
        this.mtimeMs = st.mtimeMs;
        this.lastActivity = st.mtimeMs;
        return this;
    }

    #addLine(line) {
        const trimmed = line.trim();
        if (!trimmed) return;
        let entry;
        try {
            entry = JSON.parse(trimmed);
        } catch {
            // A torn append we caught mid-write, or a line we started reading
            // from the middle of. Both are expected; neither is fatal.
            this.parseErrors++;
            return;
        }
        if (!entry || typeof entry !== "object") return;

        if (entry.type === "session") {
            this.header = entry;
            return;
        }
        if (!entry.id) return;

        const node = {
            id: entry.id,
            parentId: entry.parentId ?? null,
            ts: entry.timestamp,
            kind: "other",
        };

        switch (entry.type) {
            case "message":
                this.#summarizeMessage(entry.message, node);
                this.messageCount++;
                break;
            case "compaction":
                node.kind = "compaction";
                node.text = truncate(entry.summary, 800);
                node.tokensBefore = entry.tokensBefore;
                if (entry.usage?.cost?.total) this.cost += entry.usage.cost.total;
                break;
            case "branch_summary":
                node.kind = "branch";
                node.text = truncate(entry.summary, 800);
                break;
            case "session_info":
                node.kind = "meta";
                node.hidden = true;
                this.name = entry.name;
                break;
            case "model_change":
                node.kind = "meta";
                node.text = `model → ${entry.provider}/${entry.modelId}`;
                this.model = entry.modelId;
                this.provider = entry.provider;
                break;
            case "thinking_level_change":
                node.kind = "meta";
                node.text = `thinking → ${entry.thinkingLevel}`;
                break;
            case "custom_message":
                node.kind = "custom";
                node.customType = entry.customType;
                node.text = truncate(textOf(entry.content), 800);
                node.hidden = entry.display === false;
                break;
            case "custom":
                node.kind = "custom";
                node.customType = entry.customType;
                node.hidden = true;
                break;
            case "label":
                node.kind = "meta";
                node.hidden = true;
                if (entry.targetId) this.labels.set(entry.targetId, entry.label);
                break;
            default:
                node.hidden = true;
        }

        // Label entries are part of the tree, so even hidden nodes have to be
        // stored or the parent walk breaks at them.
        this.byId.set(node.id, node);
        this.order.push(node.id);
    }

    #summarizeMessage(message, node) {
        if (!message || typeof message !== "object") {
            node.hidden = true;
            return;
        }
        node.kind = message.role;
        switch (message.role) {
            case "user":
                node.text = truncate(textOf(message.content));
                break;
            case "assistant": {
                const content = Array.isArray(message.content) ? message.content : [];
                node.text = truncate(textOf(content));
                node.thinkingChars = content
                    .filter((c) => c?.type === "thinking")
                    .reduce((n, c) => n + (c.thinking?.length ?? 0), 0);
                node.toolCalls = content
                    .filter((c) => c?.type === "toolCall")
                    .map((c) => ({ id: c.id, name: c.name, summary: toolSummary(c.name, c.arguments) }));
                node.stopReason = message.stopReason;
                node.errorMessage = message.errorMessage;
                if (message.model) this.model = message.model;
                if (message.provider) this.provider = message.provider;
                if (message.usage) {
                    this.cost += message.usage.cost?.total ?? 0;
                    if (typeof message.usage.totalTokens === "number") this.tokens = message.usage.totalTokens;
                }
                break;
            }
            case "toolResult":
                node.toolCallId = message.toolCallId;
                node.toolName = message.toolName;
                node.isError = message.isError === true;
                node.text = truncate(textOf(message.content));
                if (message.usage?.cost?.total) this.cost += message.usage.cost.total;
                break;
            case "bashExecution":
                node.kind = "bash";
                node.command = truncate(message.command, 400);
                node.exitCode = message.exitCode;
                node.text = truncate(message.output);
                break;
            case "compactionSummary":
                node.kind = "compaction";
                node.text = truncate(message.summary, 800);
                node.tokensBefore = message.tokensBefore;
                break;
            case "branchSummary":
                node.kind = "branch";
                node.text = truncate(message.summary, 800);
                break;
            case "custom":
                node.kind = "custom";
                node.customType = message.customType;
                node.text = truncate(textOf(message.content), 800);
                node.hidden = message.display === false;
                break;
            default:
                node.hidden = true;
        }
    }

    /**
     * The active branch, root-first.
     *
     * pi tracks a leaf id internally; from the file alone the last appended
     * entry is the leaf, which is the same thing except immediately after a
     * /tree jump that hasn't been written to yet.
     */
    branch() {
        const leafId = this.order.length ? this.order[this.order.length - 1] : null;
        const out = [];
        const seen = new Set();
        let id = leafId;
        while (id && !seen.has(id)) {
            seen.add(id);
            const node = this.byId.get(id);
            if (!node) break;
            out.push(node);
            id = node.parentId;
        }
        out.reverse();
        return out;
    }

    /** What the agent is doing, inferred from the tail of the active branch. */
    derive() {
        const branch = this.branch();
        const visible = branch.filter((n) => !n.hidden);
        const resolved = new Set();
        for (let i = branch.length - 1; i >= 0; i--) {
            const node = branch[i];
            if (node.kind === "toolResult" && node.toolCallId) resolved.add(node.toolCallId);
            if (node.kind === "assistant" && node.toolCalls?.length) {
                const pending = node.toolCalls.filter((tc) => !resolved.has(tc.id));
                if (pending.length) return { state: "tool", tools: pending, since: node.ts };
                break;
            }
        }
        const last = visible[visible.length - 1];
        if (!last) return { state: "empty" };
        if (last.kind === "assistant") {
            if (last.stopReason === "error") return { state: "error", detail: last.errorMessage };
            return { state: "idle" };
        }
        if (last.kind === "user" || last.kind === "toolResult" || last.kind === "bash" || last.kind === "custom") {
            return { state: "thinking" };
        }
        return { state: "idle" };
    }

    summary() {
        const derived = this.derive();
        return {
            file: this.file,
            sessionId: this.header?.id,
            cwd: this.header?.cwd,
            project: projectLabel(this.header?.cwd, this.file),
            name: this.name,
            model: this.model,
            provider: this.provider,
            startedAt: this.header?.timestamp,
            lastActivity: this.lastActivity,
            messages: this.messageCount,
            tokens: this.tokens,
            cost: this.cost,
            truncatedHistory: this.truncatedHistory,
            version: `${this.size}:${Math.round(this.mtimeMs)}`,
            ...derived,
        };
    }

    messages(limit) {
        const visible = this.branch().filter((n) => !n.hidden);
        const start = limit > 0 ? Math.max(0, visible.length - limit) : 0;
        return {
            total: visible.length,
            omitted: start,
            entries: visible.slice(start).map((n) => ({ ...n, label: this.labels.get(n.id) })),
        };
    }
}

// -------------------------------------------------------------- discovery

const views = new Map(); // file -> { view, lastAccess }

function viewFor(file) {
    let held = views.get(file);
    if (!held) {
        held = { view: new SessionView(file) };
        views.set(file, held);
    }
    held.lastAccess = Date.now();
    return held.view.refresh();
}

function sweepViews() {
    const cutoff = Date.now() - VIEW_TTL_MS;
    for (const [file, held] of views) {
        if (held.lastAccess < cutoff) views.delete(file);
    }
}

/** `/data/omp/agent` -> `omp`. Matches how compose mounts the two config volumes. */
function agentForRoot(root) {
    return basename(dirname(root)) === "omp" ? "omp" : "pi";
}

function listSessionFiles() {
    const cutoff = Date.now() - MAX_AGE_DAYS * 86_400_000;
    const found = [];
    for (const root of ROOTS) {
        const agent = agentForRoot(root);
        const sessionsDir = join(root, "sessions");
        let projects;
        try {
            projects = readdirSync(sessionsDir, { withFileTypes: true });
        } catch {
            continue;
        }
        for (const project of projects) {
            if (!project.isDirectory()) continue;
            const dir = join(sessionsDir, project.name);
            let files;
            try {
                files = readdirSync(dir, { withFileTypes: true });
            } catch {
                continue;
            }
            for (const f of files) {
                if (!f.isFile() || !f.name.endsWith(".jsonl")) continue;
                const file = join(dir, f.name);
                try {
                    const st = statSync(file);
                    if (st.mtimeMs < cutoff) continue;
                    found.push({ file, mtimeMs: st.mtimeMs, agent });
                } catch {
                    /* raced with a delete */
                }
            }
        }
    }
    found.sort((a, b) => b.mtimeMs - a.mtimeMs);
    return found;
}

function listRuns() {
    const now = Date.now();
    const runs = [];
    let names;
    try {
        names = readdirSync(RUN_DIR);
    } catch {
        return runs;
    }
    for (const name of names) {
        if (!name.endsWith(".json")) continue;
        const runId = name.slice(0, -5);
        let record;
        try {
            record = JSON.parse(readFileSync(join(RUN_DIR, name), "utf8"));
        } catch {
            continue; // mid-write, or not ours
        }
        let beatMs = 0;
        try {
            beatMs = statSync(join(RUN_DIR, `${runId}.beat`)).mtimeMs;
        } catch {
            /* no heartbeat: container is gone, or never wrote one */
        }
        const beatAgeMs = beatMs ? now - beatMs : null;
        runs.push({
            ...record,
            runId: record.runId || runId,
            beatAgeMs,
            live: beatAgeMs !== null && beatAgeMs < BEAT_STALE_MS && record.state !== "ended",
        });
    }
    return runs;
}

/** `.../agent/sessions/--proj--/ts_id.jsonl` -> `sessions/--proj--/ts_id.jsonl`. */
function relKey(path) {
    const parts = String(path).split("/").filter(Boolean);
    return parts.length >= 3 ? parts.slice(-3).join("/") : null;
}

/**
 * Index of the session files we can actually see, keyed the two ways a run
 * record can point at one.
 */
function indexFiles(files) {
    const byRel = new Map();
    const byBase = new Map();
    for (const f of files) {
        const rel = relKey(f.file);
        if (rel && !byRel.has(rel)) byRel.set(rel, f.file);
        const base = f.file.split("/").pop();
        if (base && !byBase.has(base)) byBase.set(base, f.file);
    }
    return { byRel, byBase };
}

/**
 * Exact run -> session file resolution, in *this* process's namespace.
 *
 * The critical part is that a run record is written inside the agent container,
 * where the config volume is mounted at ~/.pi -- while here the same volume is
 * at /data/pi. An absolute sessionFile from a record therefore names a path
 * that does not exist for us, and handing it back produced cards with a stat
 * that always failed: zero messages, epoch-zero timestamps, and the real
 * transcript left over as a duplicate card. So every candidate is resolved
 * against files we have actually seen, and anything unresolvable returns null
 * to let the cwd heuristic have a go.
 */
function resolveRunSessionExact(run, index, files) {
    // Namespace-independent, written by current versions of the extension.
    if (run.sessionRelPath && index.byRel.has(run.sessionRelPath)) {
        return index.byRel.get(run.sessionRelPath);
    }
    // Older records (and any custom --session-dir) only carry an absolute path.
    // Its tail still identifies the file wherever the volume happens to be
    // mounted, so match on that rather than on the leading directories.
    if (run.sessionFile) {
        const rel = relKey(run.sessionFile);
        if (rel && index.byRel.has(rel)) return index.byRel.get(rel);
        const base = run.sessionFile.split("/").pop();
        if (base && index.byBase.has(base)) return index.byBase.get(base);
    }
    // A run whose session id we injected owns the file named after it, since
    // sessions are stored as <timestamp>_<sessionId>.jsonl.
    if (run.sessionIdInjected && run.runId) {
        const suffix = `_${run.runId}.jsonl`;
        const match = files.find((f) => f.file.endsWith(suffix));
        if (match) return match.file;
    }
    return null;
}

/**
 * Best-effort fallback for runs neither of those covers: `./omp` (no extension
 * for oh-my-pi yet) and `./pi -c` (which deliberately reuses an existing file
 * rather than taking our id). Match on the session's own recorded cwd, prefer
 * the most recently active, and never hand one file to two runs.
 */
function resolveRunSessionByCwd(run, summaries, claimed) {
    if (!run.cwd) return null;
    const startedMs = run.startedAt ? Date.parse(run.startedAt) : NaN;
    let best = null;
    for (const summary of summaries) {
        if (!summary || claimed.has(summary.file)) continue;
        if (summary.cwd !== run.cwd) continue;
        // A session that was last touched before this run even started belongs
        // to an earlier one.
        if (!Number.isNaN(startedMs) && summary.lastActivity && summary.lastActivity < startedMs - 60_000) continue;
        if (!best || (summary.lastActivity ?? 0) > (best.lastActivity ?? 0)) best = summary;
    }
    return best ? best.file : null;
}

function buildState() {
    const files = listSessionFiles();
    const runs = listRuns();

    const index = indexFiles(files);
    const wanted = new Set();
    const runFiles = new Map(); // runId -> session file
    for (const run of runs) {
        const file = resolveRunSessionExact(run, index, files);
        if (file) {
            runFiles.set(run.runId, file);
            wanted.add(file);
        }
    }
    for (const f of files.slice(0, MAX_SESSIONS)) wanted.add(f.file);

    const byFile = new Map();
    for (const file of wanted) {
        try {
            const view = viewFor(file);
            // A file that vanished between the scan and now. Better to show a
            // run with no transcript than one with a transcript full of zeros.
            if (view.missing) continue;
            byFile.set(file, view.summary());
        } catch (err) {
            byFile.set(file, { file, state: "unreadable", detail: String(err?.message || err) });
        }
    }

    // Drop matches whose file turned out to be unreadable, so those runs fall
    // through to the heuristic below rather than keeping a dead reference.
    for (const [runId, file] of runFiles) {
        if (!byFile.has(file)) runFiles.delete(runId);
    }

    // Second pass, now that headers are parsed: anything still unmatched gets
    // the cwd heuristic. Live runs pick first -- a stale record should not take
    // the transcript of the container that replaced it.
    const claimed = new Set(runFiles.values());
    const summaries = [...byFile.values()];
    for (const run of [...runs].sort((a, b) => Number(b.live) - Number(a.live))) {
        if (runFiles.has(run.runId)) continue;
        const file = resolveRunSessionByCwd(run, summaries, claimed);
        if (file) {
            runFiles.set(run.runId, file);
            claimed.add(file);
        }
    }

    // Two live runs appending to one session file interleave two conversations
    // into one tree. pi does not lock session files, so nothing upstream stops
    // this -- surfacing it is the best we can do from here.
    const liveByFile = new Map();
    for (const run of runs) {
        if (!run.live) continue;
        const file = runFiles.get(run.runId);
        if (!file) continue;
        liveByFile.set(file, (liveByFile.get(file) || 0) + 1);
    }

    const cards = [];
    for (const run of runs) {
        const file = runFiles.get(run.runId) || null;
        const session = file ? byFile.get(file) : null;
        const warnings = [];
        if (file && liveByFile.get(file) > 1) {
            warnings.push("Another live run is appending to this same session file.");
        }
        if (session?.truncatedHistory) warnings.push("Session is large; only its recent history was parsed.");
        cards.push({
            kind: "run",
            runId: run.runId,
            label: run.label || null,
            agent: run.agent || "pi",
            live: run.live,
            beatAgeMs: run.beatAgeMs,
            runState: run.state || null,
            currentTool: run.currentTool || null,
            contextPercent: run.contextPercent ?? null,
            contextTokens: run.contextTokens ?? null,
            runCost: run.cost ?? null,
            startedAt: run.startedAt || session?.startedAt || null,
            endedAt: run.endedAt || null,
            cwd: run.cwd || session?.cwd || null,
            session: session || null,
            warnings,
        });
    }

    for (const f of files.slice(0, MAX_SESSIONS)) {
        if (claimed.has(f.file)) continue;
        const session = byFile.get(f.file);
        if (!session) continue;
        cards.push({
            kind: "session",
            runId: null,
            label: null,
            agent: f.agent,
            live: false,
            beatAgeMs: null,
            runState: null,
            currentTool: null,
            contextPercent: null,
            contextTokens: null,
            runCost: null,
            startedAt: session.startedAt,
            endedAt: null,
            cwd: session.cwd,
            session,
            warnings: session.truncatedHistory ? ["Session is large; only its recent history was parsed."] : [],
        });
    }

    const rank = (c) => (c.live ? 0 : 1);
    const recency = (c) => c.session?.lastActivity || (c.startedAt ? Date.parse(c.startedAt) : 0) || 0;
    cards.sort((a, b) => {
        if (rank(a) !== rank(b)) return rank(a) - rank(b);
        return recency(b) - recency(a);
    });

    sweepViews();
    return {
        now: Date.now(),
        roots: ROOTS,
        runDir: RUN_DIR,
        exportEnabled: EXPORT_ENABLED,
        liveCount: cards.filter((c) => c.live).length,
        cards,
    };
}

// ------------------------------------------------------------------ server

function safeSessionFile(input) {
    if (typeof input !== "string" || !input) return null;
    let candidate = resolve(input);
    if (!candidate.endsWith(".jsonl")) return null;
    try {
        candidate = realpathSync(candidate);
    } catch {
        return null;
    }
    for (const root of ROOTS) {
        if (candidate === root || candidate.startsWith(root + sep)) return candidate;
    }
    return null;
}

function authorized(url, req) {
    if (!TOKEN) return true;
    if (req.headers["x-pibot-token"] === TOKEN) return true;
    return url.searchParams.get("token") === TOKEN;
}

function sendJson(res, status, body) {
    const payload = JSON.stringify(body);
    res.writeHead(status, {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
    });
    res.end(payload);
}

function exportSession(file, res) {
    const dir = mkdtempSync(join(tmpdir(), "pibot-export-"));
    const out = join(dir, "session.html");
    execFile(
        PI_BIN,
        ["--export", file, out],
        {
            cwd: dir,
            timeout: 120_000,
            maxBuffer: 4 * 1024 * 1024,
            env: {
                ...process.env,
                HOME: dir,
                PI_CODING_AGENT_DIR: join(dir, "agent"),
                PI_OFFLINE: "1",
                PI_SKIP_VERSION_CHECK: "1",
                PI_TELEMETRY: "0",
            },
        },
        (err) => {
            try {
                if (err || !existsSync(out)) {
                    sendJson(res, 500, { error: "export failed", detail: String(err?.message || "no output") });
                    return;
                }
                const html = readFileSync(out);
                res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
                res.end(html);
            } finally {
                rmSync(dir, { recursive: true, force: true });
            }
        },
    );
}

let appHtml = null;
function readApp() {
    if (appHtml === null || process.env.PIBOT_STATUS_DEV === "1") {
        appHtml = readFileSync(join(HERE, "app.html"));
    }
    return appHtml;
}

const server = createServer((req, res) => {
    let url;
    try {
        url = new URL(req.url, "http://localhost");
    } catch {
        res.writeHead(400).end("bad request");
        return;
    }

    if (!authorized(url, req)) {
        sendJson(res, 401, { error: "unauthorized", detail: "PIBOT_STATUS_TOKEN is set; pass ?token=…" });
        return;
    }

    try {
        if (url.pathname === "/" || url.pathname === "/index.html") {
            res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
            res.end(readApp());
            return;
        }

        if (url.pathname === "/api/state") {
            sendJson(res, 200, buildState());
            return;
        }

        if (url.pathname === "/api/session") {
            const file = safeSessionFile(url.searchParams.get("file"));
            if (!file) {
                sendJson(res, 400, { error: "unknown session file" });
                return;
            }
            const view = viewFor(file);
            const summary = view.summary();
            const known = url.searchParams.get("v");
            if (known && known === summary.version) {
                sendJson(res, 200, { unchanged: true, version: summary.version });
                return;
            }
            const limit = Number(url.searchParams.get("limit") || 80);
            sendJson(res, 200, { session: summary, ...view.messages(limit) });
            return;
        }

        if (url.pathname === "/api/export") {
            if (!EXPORT_ENABLED) {
                sendJson(res, 501, { error: "export disabled" });
                return;
            }
            const file = safeSessionFile(url.searchParams.get("file"));
            if (!file) {
                sendJson(res, 400, { error: "unknown session file" });
                return;
            }
            exportSession(file, res);
            return;
        }

        res.writeHead(404, { "content-type": "text/plain" }).end("not found");
    } catch (err) {
        sendJson(res, 500, { error: "internal error", detail: String(err?.message || err) });
    }
});

server.listen(PORT, HOST, () => {
    console.log(`pibot status viewer on http://${HOST}:${PORT}`);
    console.log(`  session roots : ${ROOTS.join(", ") || "(none found)"}`);
    console.log(`  run records   : ${RUN_DIR}`);
    console.log(`  html export   : ${EXPORT_ENABLED ? "enabled" : "disabled"}`);
    if (TOKEN) console.log("  token         : required");
    if (ROOTS.length === 0) {
        console.warn("warning: no session roots exist. Are the config volumes mounted?");
    }
});

for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, () => {
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 2000).unref();
    });
}
