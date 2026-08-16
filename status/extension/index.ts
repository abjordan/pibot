// pibot status extension -- publishes what this pi session is doing right now.
//
// It writes one small JSON file per run into the pibot run registry inside the
// pi config volume. The status viewer mounts that volume read-only and renders
// it. Nothing is served from here, no socket is opened, and no data leaves the
// container: the file is the entire interface.
//
// Why this exists on top of the session JSONL the viewer already reads: the
// transcript only lands on disk when a message completes, so from the file
// alone you cannot tell "thinking hard" from "container died", and you cannot
// see how long the current tool call has been running. This fills both gaps.
//
// Deliberately imports nothing but node builtins. Extensions are loaded through
// jiti at pi startup, and a module resolution failure here would be a startup
// failure for the agent itself. Everything is wrapped so a bug in this file can
// never take a session down.

import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type RunState = "starting" | "idle" | "thinking" | "tool" | "error" | "ended";

interface RunningTool {
    name: string;
    summary: string;
    startedAt: number;
}

const HEARTBEAT_MS = 5000;
const MIN_WRITE_INTERVAL_MS = 700;

function toolSummary(name: string, args: any): string {
    if (!args || typeof args !== "object") return "";
    const pick = (value: unknown) => (typeof value === "string" ? value : "");
    let raw = "";
    switch (name) {
        case "bash":
            raw = pick(args.command);
            break;
        case "read":
        case "write":
        case "edit":
            raw = pick(args.path);
            break;
        case "glob":
        case "grep":
            raw = pick(args.pattern) || pick(args.query);
            break;
        default:
            try {
                raw = JSON.stringify(args) ?? "";
            } catch {
                raw = "";
            }
    }
    return raw.length > 200 ? `${raw.slice(0, 200)}…` : raw;
}

export default function (pi: any) {
    const runId = process.env.PIBOT_RUN;
    if (!runId || process.env.PIBOT_STATUS === "0") return;

    const runDir = process.env.PIBOT_RUN_DIR || join(homedir(), ".pi", "agent", ".pibot", "runs");
    const target = join(runDir, `${runId}.json`);

    const record: Record<string, unknown> = {
        runId,
        source: "extension",
        agent: process.env.PI_AGENT || "pi",
        label: process.env.PIBOT_LABEL || null,
        sessionIdInjected: process.env.PIBOT_SESSION_ID_INJECTED === "1",
        startedAt: new Date().toISOString(),
        state: "starting" as RunState,
        cost: 0,
        messages: 0,
    };

    const runningTools = new Map<string, RunningTool>();
    let timer: ReturnType<typeof setInterval> | undefined;
    let trailing: ReturnType<typeof setTimeout> | undefined;
    let lastWrite = 0;
    let disabled = false;

    const write = (force = false) => {
        if (disabled) return;
        const now = Date.now();
        const wait = MIN_WRITE_INTERVAL_MS - (now - lastWrite);
        if (!force && wait > 0) {
            // Rate limited, but never dropped: a suppressed update schedules a
            // trailing write. Without this the record can keep advertising a
            // tool that already finished, since the events that matter most
            // (tool start, tool end) arrive in bursts well under the interval.
            if (!trailing) {
                trailing = setTimeout(() => {
                    trailing = undefined;
                    write(true);
                }, wait);
                trailing.unref?.();
            }
            return;
        }
        if (trailing) {
            clearTimeout(trailing);
            trailing = undefined;
        }
        lastWrite = now;
        try {
            mkdirSync(runDir, { recursive: true });
            // Rename within the same directory so a reader never sees a half
            // written record -- it either gets the old file or the new one.
            const tmp = `${target}.tmp`;
            record.updatedAt = new Date().toISOString();
            writeFileSync(tmp, `${JSON.stringify(record, null, 2)}\n`);
            renameSync(tmp, target);
        } catch {
            // A read-only or missing registry is not worth failing a session
            // over. Stop trying; the entrypoint heartbeat still marks liveness.
            disabled = true;
        }
    };

    const refreshUsage = (ctx: any) => {
        try {
            const usage = ctx?.getContextUsage?.();
            if (usage) {
                record.contextTokens = usage.tokens;
                record.contextWindow = usage.contextWindow;
                record.contextPercent = usage.percent;
            }
        } catch {
            /* usage is a nicety, never a reason to fail */
        }
    };

    const syncSession = (ctx: any) => {
        try {
            const sm = ctx?.sessionManager;
            if (sm) {
                const file = sm.getSessionFile?.() ?? null;
                record.sessionFile = file;
                // The viewer runs in a different container, where this same
                // volume is mounted somewhere else entirely -- so an absolute
                // path from here means nothing there. The trailing
                // `sessions/<project>/<file>.jsonl` is the part that identifies
                // the file in any namespace, so publish that too.
                record.sessionRelPath = file ? file.split("/").filter(Boolean).slice(-3).join("/") : null;
                record.sessionId = sm.getSessionId?.() ?? null;
                record.sessionName = sm.getSessionName?.() ?? null;
                record.cwd = sm.getCwd?.() ?? ctx.cwd ?? null;
            } else if (ctx?.cwd) {
                record.cwd = ctx.cwd;
            }
            if (ctx?.model) {
                record.model = ctx.model.id ?? null;
                record.provider = ctx.model.provider ?? null;
            }
        } catch {
            /* keep whatever we already had */
        }
    };

    const setCurrentTool = () => {
        // With parallel tool execution several can be in flight; the oldest is
        // the one the session is actually waiting on.
        let oldest: RunningTool | undefined;
        for (const tool of runningTools.values()) {
            if (!oldest || tool.startedAt < oldest.startedAt) oldest = tool;
        }
        record.currentTool = oldest ?? null;
        record.runningTools = runningTools.size;
    };

    const stopTimer = () => {
        if (timer) {
            clearInterval(timer);
            timer = undefined;
        }
        if (trailing) {
            clearTimeout(trailing);
            trailing = undefined;
        }
    };

    const guard = (fn: (event: any, ctx: any) => void) => (event: any, ctx: any) => {
        try {
            fn(event, ctx);
        } catch {
            /* never propagate into pi's event loop */
        }
    };

    // Background resources start here, not in the factory: pi loads extensions
    // in invocations that never open a session (`pi install`, `--list-models`).
    pi.on(
        "session_start",
        guard((_event: any, ctx: any) => {
            syncSession(ctx);
            refreshUsage(ctx);
            record.state = "idle";
            record.endedAt = null;
            record.endReason = null;
            write(true);

            stopTimer();
            timer = setInterval(() => {
                refreshUsage(ctx);
                write(true);
            }, HEARTBEAT_MS);
            // Never hold the process open on pi's account.
            timer.unref?.();
        }),
    );

    pi.on(
        "session_info_changed",
        guard((event: any) => {
            record.sessionName = event?.name ?? null;
            write(true);
        }),
    );

    pi.on(
        "model_select",
        guard((event: any) => {
            record.model = event?.model?.id ?? record.model;
            record.provider = event?.model?.provider ?? record.provider;
            write(true);
        }),
    );

    pi.on(
        "agent_start",
        guard((_event: any, ctx: any) => {
            record.state = "thinking";
            syncSession(ctx);
            write(true);
        }),
    );

    pi.on(
        "agent_settled",
        guard((_event: any, ctx: any) => {
            runningTools.clear();
            setCurrentTool();
            record.state = "idle";
            refreshUsage(ctx);
            write(true);
        }),
    );

    pi.on(
        "tool_execution_start",
        guard((event: any) => {
            runningTools.set(event.toolCallId, {
                name: event.toolName,
                summary: toolSummary(event.toolName, event.args),
                startedAt: Date.now(),
            });
            setCurrentTool();
            record.state = "tool";
            write(true);
        }),
    );

    pi.on(
        "tool_execution_end",
        guard((event: any) => {
            runningTools.delete(event.toolCallId);
            setCurrentTool();
            if (runningTools.size === 0) record.state = "thinking";
            if (event?.isError) record.lastToolError = event.toolName;
            write();
        }),
    );

    pi.on(
        "message_end",
        guard((event: any, ctx: any) => {
            const message = event?.message;
            record.messages = (record.messages as number) + 1;
            if (message?.role === "assistant") {
                const usage = message.usage;
                if (usage?.cost?.total) record.cost = (record.cost as number) + usage.cost.total;
                if (typeof usage?.totalTokens === "number") record.tokens = usage.totalTokens;
                if (message.stopReason === "error") {
                    record.state = "error";
                    record.lastError = message.errorMessage ?? "error";
                }
                if (message.model) record.model = message.model;
                if (message.provider) record.provider = message.provider;
            }
            refreshUsage(ctx);
            write();
        }),
    );

    // Fires on Ctrl+C, Ctrl+D, SIGTERM and SIGHUP as well as session
    // replacement, so a clean exit is distinguishable from a killed container.
    pi.on(
        "session_shutdown",
        guard((event: any) => {
            stopTimer();
            runningTools.clear();
            setCurrentTool();
            if (event?.reason === "quit") {
                record.state = "ended";
                record.endedAt = new Date().toISOString();
                record.endReason = "quit";
            } else {
                record.state = "idle";
            }
            write(true);
        }),
    );
}
