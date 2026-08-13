import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";

// Parses a pi coding-agent JSONL trace (host-logs/pi-events.jsonl) into a
// flat, render-ready list of turns.
//
// Two things make this non-trivial:
//
// 1. Most lines are redundant. `message_update` is a per-token streaming
//    delta; `message_start`/`tool_execution_start`/`tool_execution_update`
//    are superseded by the finalized data on `turn_end`. `turn_end` alone
//    carries the assistant's finished `message.content[]` *and* its matching
//    `toolResults[]` (each result already tagged with the `toolCallId` it
//    answers) in one event -- no cross-event correlation needed. One
//    corpus-wide outlier had a single `tool_execution_update` line re-serialize
//    a 69 KB growing buffer per tick, 3,347 times, for 221 MB in one file --
//    so these types are skipped by a cheap regex on the first ~40 bytes of
//    each line, before it's ever JSON.parsed.
//
// 2. A trace is not always ONE agent_start...agent_end run. Context
//    compaction or a stream-error retry can close out an "episode" and open
//    a fresh one (agent_start increments an episode counter; compaction/retry
//    markers are recorded in place). A run can also end without ever closing
//    the final episode (killed/timed out). Earlier code took only the last
//    agent_end's message list, which silently discarded every earlier
//    episode AND any unclosed trailing one -- on one real 9-episode run that
//    dropped 639 of 1321 turns with no indication anything was missing.
//    Building the item list from `turn_end` sidesteps this entirely: it's a
//    flat, file-order stream of turns regardless of how many episodes wrap
//    them.

export interface ContentBlock {
  kind: "thinking" | "text" | "toolCall";
  text?: string;
  toolCallId?: string;
  toolName?: string;
  arguments?: unknown;
}

export interface ToolResultBlock {
  toolCallId: string;
  toolName: string;
  isError: boolean;
  text: string;
}

export type TranscriptItem =
  | { kind: "turn"; episode: number; role: string; content: ContentBlock[]; toolResults: ToolResultBlock[] }
  | { kind: "compaction"; reason: string | null; summary: string | null }
  | { kind: "retry"; attempt: unknown; errorMessage: string | null; success: boolean | null };

export interface TranscriptResult {
  items: TranscriptItem[];
  turnCount: number;
  episodeCount: number;
  settled: boolean;
  error: string | null;
}

const SKIP_TYPES = new Set([
  "message_update",
  "message_start",
  "message_end",
  "tool_execution_start",
  "tool_execution_update",
  "tool_execution_end",
]);

const MAX_BLOCK_CHARS = 40_000;
function truncateText(text: string): string {
  if (text.length <= MAX_BLOCK_CHARS) return text;
  const omitted = text.length - MAX_BLOCK_CHARS;
  return `${text.slice(0, MAX_BLOCK_CHARS)}\n\n… [${omitted} more characters truncated -- see host-logs/pi-events.jsonl] …`;
}

function typeOf(line: string): string | null {
  const m = /^\{"type":"([a-zA-Z_]+)"/.exec(line);
  return m ? m[1] : null;
}

export async function readTranscript(traceFile: string): Promise<TranscriptResult> {
  const items: TranscriptItem[] = [];
  let episode = 0;
  let turnCount = 0;
  let settled = false;

  let stream;
  try {
    stream = createReadStream(traceFile, "utf-8");
  } catch {
    return { items: [], turnCount: 0, episodeCount: 0, settled: false, error: "trace file not found" };
  }

  const rl = createInterface({ input: stream, crlfDelay: Infinity });

  try {
    for await (const line of rl) {
      if (!line.trim()) continue;
      const type = typeOf(line);
      if (!type || SKIP_TYPES.has(type)) continue;

      let evt: Record<string, unknown>;
      try {
        evt = JSON.parse(line);
      } catch {
        continue; // one malformed trailing line (e.g. a killed process mid-write) never aborts the parse
      }

      switch (type) {
        case "agent_start":
          episode++;
          break;
        case "agent_settled":
          settled = true;
          break;
        case "compaction_end": {
          const result = evt.result as { summary?: string } | undefined;
          items.push({
            kind: "compaction",
            reason: typeof evt.reason === "string" ? evt.reason : null,
            summary: result?.summary ? truncateText(result.summary) : null,
          });
          break;
        }
        case "auto_retry_start":
          items.push({
            kind: "retry",
            attempt: evt.attempt ?? null,
            errorMessage: typeof evt.errorMessage === "string" ? evt.errorMessage : null,
            success: null,
          });
          break;
        case "auto_retry_end":
          items.push({
            kind: "retry",
            attempt: evt.attempt ?? null,
            errorMessage: null,
            success: typeof evt.success === "boolean" ? evt.success : null,
          });
          break;
        case "turn_end": {
          const message = evt.message as { role?: string; content?: Record<string, unknown>[] } | undefined;
          if (!message) break;
          const content: ContentBlock[] = (message.content ?? []).map((b) => {
            if (b.type === "thinking") {
              return { kind: "thinking", text: truncateText(String(b.thinking ?? "")) };
            }
            if (b.type === "text") {
              return { kind: "text", text: truncateText(String(b.text ?? "")) };
            }
            if (b.type === "toolCall") {
              return {
                kind: "toolCall",
                toolCallId: String(b.id ?? ""),
                toolName: String(b.name ?? ""),
                arguments: b.arguments,
              };
            }
            return { kind: "text", text: truncateText(JSON.stringify(b)) };
          });
          const rawResults = (evt.toolResults as Record<string, unknown>[] | undefined) ?? [];
          const toolResults: ToolResultBlock[] = rawResults.map((r) => {
            const resultContent = (r.content as { text?: string }[] | undefined) ?? [];
            return {
              toolCallId: String(r.toolCallId ?? ""),
              toolName: String(r.toolName ?? ""),
              isError: Boolean(r.isError),
              text: truncateText(resultContent.map((c) => c.text ?? "").join("\n")),
            };
          });
          items.push({ kind: "turn", episode: episode || 1, role: String(message.role ?? "assistant"), content, toolResults });
          turnCount++;
          break;
        }
        default:
          break;
      }
    }
  } catch (err) {
    return {
      items,
      turnCount,
      episodeCount: episode,
      settled,
      error: err instanceof Error ? err.message : String(err),
    };
  }

  return { items, turnCount, episodeCount: episode, settled, error: null };
}
