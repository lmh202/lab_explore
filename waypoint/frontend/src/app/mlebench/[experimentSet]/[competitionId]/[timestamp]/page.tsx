"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useEffect, useState } from "react";

import { ExpandableText } from "@/components/ExpandableText";
import { MarkdownMessage } from "@/components/MarkdownMessage";
import { ThemeToggle } from "@/components/ThemeToggle";

interface RunJson {
  pi?: { model?: string };
  seed?: number;
  time_limit_hours?: number;
  resource_limits?: { max_cpu_threads?: number };
  started_at_utc?: string;
  duration_seconds?: number;
  status?: string;
  public_submission_validation?: { valid?: boolean; errors?: string[] };
  grade?: {
    score?: number | null;
    bronze_threshold?: number;
    silver_threshold?: number;
    gold_threshold?: number;
    is_lower_better?: boolean;
    any_medal?: boolean;
    valid_submission?: boolean;
  };
}

interface DetailResponse {
  run: RunJson | null;
  taskMd: string | null;
  descriptionMd: string | null;
  submissionPreview: { header: string; rows: string[]; totalRows: number } | null;
  codeFiles: { name: string; size: number }[];
  dataFiles: { name: string; size: number }[];
  error: string | null;
}

interface ContentBlock {
  kind: "thinking" | "text" | "toolCall";
  text?: string;
  toolCallId?: string;
  toolName?: string;
  arguments?: unknown;
}

interface ToolResultBlock {
  toolCallId: string;
  toolName: string;
  isError: boolean;
  text: string;
}

type TranscriptItem =
  | { kind: "turn"; episode: number; role: string; content: ContentBlock[]; toolResults: ToolResultBlock[] }
  | { kind: "compaction"; reason: string | null; summary: string | null }
  | { kind: "retry"; attempt: unknown; errorMessage: string | null; success: boolean | null };

interface TranscriptResponse {
  items: TranscriptItem[];
  turnCount: number;
  episodeCount: number;
  settled: boolean;
  error: string | null;
}

const PAGE_SIZE = 150;

export default function MlebenchCasePage() {
  const params = useParams<{ experimentSet: string; competitionId: string; timestamp: string }>();
  const { experimentSet, competitionId, timestamp } = params;

  const [tab, setTab] = useState<"overview" | "transcript">("overview");
  const [detail, setDetail] = useState<DetailResponse | null>(null);
  const [transcript, setTranscript] = useState<TranscriptResponse | null>(null);
  const [transcriptLoading, setTranscriptLoading] = useState(false);
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE);

  useEffect(() => {
    setDetail(null);
    fetch(`/api/mlebench/cases/${experimentSet}/${competitionId}/${timestamp}`)
      .then((r) => r.json())
      .then(setDetail);
  }, [experimentSet, competitionId, timestamp]);

  useEffect(() => {
    if (tab !== "transcript" || transcript || transcriptLoading) return;
    setTranscriptLoading(true);
    fetch(`/api/mlebench/cases/${experimentSet}/${competitionId}/${timestamp}/transcript`)
      .then((r) => r.json())
      .then(setTranscript)
      .finally(() => setTranscriptLoading(false));
  }, [tab, transcript, transcriptLoading, experimentSet, competitionId, timestamp]);

  const run = detail?.run;
  const grade = run?.grade;

  return (
    <main className="page-shell mlebench-shell">
      <header className="app-bar">
        <Link href="/mlebench" className="mlebench-back">
          ← all cases
        </Link>
        <div className="app-bar-title">
          {competitionId} <span className="muted">/ {timestamp}</span>
        </div>
        <ThemeToggle />
      </header>

      <nav className="mlebench-tabs">
        <button
          type="button"
          className={tab === "overview" ? "active" : ""}
          onClick={() => setTab("overview")}
        >
          Overview
        </button>
        <button
          type="button"
          className={tab === "transcript" ? "active" : ""}
          onClick={() => setTab("transcript")}
        >
          Prompt &amp; Transcript
        </button>
      </nav>

      {!detail ? (
        <p className="muted">Loading…</p>
      ) : detail.error && !run ? (
        <p className="mlebench-error">{detail.error}</p>
      ) : tab === "overview" ? (
        <section className="mlebench-overview">
          <div className="mlebench-card">
            <h3>Input</h3>
            <dl>
              <dt>Model</dt>
              <dd>{run?.pi?.model ?? "—"}</dd>
              <dt>Seed</dt>
              <dd>{run?.seed ?? "—"}</dd>
              <dt>Time limit</dt>
              <dd>{run?.time_limit_hours != null ? `${run.time_limit_hours} h` : "—"}</dd>
              <dt>CPU threads</dt>
              <dd>{run?.resource_limits?.max_cpu_threads ?? "—"}</dd>
              <dt>Started (UTC)</dt>
              <dd>{run?.started_at_utc ?? "—"}</dd>
              <dt>Duration</dt>
              <dd>{run?.duration_seconds != null ? `${run.duration_seconds.toFixed(1)} s` : "—"}</dd>
            </dl>
          </div>

          <div className="mlebench-card">
            <h3>Output</h3>
            <dl>
              <dt>Status</dt>
              <dd>{run?.status ?? "—"}</dd>
              <dt>Score</dt>
              <dd>{grade?.score ?? "—"}</dd>
              <dt>Bronze threshold</dt>
              <dd>
                {grade?.bronze_threshold ?? "—"}
                {grade ? ` (${grade.is_lower_better ? "lower is better" : "higher is better"})` : ""}
              </dd>
              <dt>Any medal</dt>
              <dd>{grade ? String(grade.any_medal) : "—"}</dd>
              <dt>Valid submission</dt>
              <dd>{grade ? String(grade.valid_submission) : "—"}</dd>
              {run?.public_submission_validation?.errors?.length ? (
                <>
                  <dt>Validation errors</dt>
                  <dd className="mlebench-error">
                    {run.public_submission_validation.errors.join("; ")}
                  </dd>
                </>
              ) : null}
            </dl>
            {detail.submissionPreview ? (
              <div className="mlebench-csv-preview">
                <pre>
                  {[detail.submissionPreview.header, ...detail.submissionPreview.rows].join("\n")}
                </pre>
                <p className="muted">{detail.submissionPreview.totalRows} total rows</p>
              </div>
            ) : (
              <p className="muted">No submission file.</p>
            )}
          </div>

          <div className="mlebench-card mlebench-card-wide">
            <h3>Description</h3>
            {detail.descriptionMd ? (
              <MarkdownMessage text={detail.descriptionMd} />
            ) : (
              <p className="muted">No description.md found.</p>
            )}
          </div>

          {detail.codeFiles.length || detail.dataFiles.length ? (
            <div className="mlebench-card mlebench-card-wide">
              <h3>Files</h3>
              <p className="muted">
                code/: {detail.codeFiles.map((f) => f.name).join(", ") || "—"}
              </p>
              <p className="muted">
                data/: {detail.dataFiles.map((f) => f.name).join(", ") || "—"}
              </p>
            </div>
          ) : null}
        </section>
      ) : (
        <section className="mlebench-transcript">
          <div className="mlebench-card mlebench-card-wide">
            <h3>Prompt</h3>
            {detail.taskMd ? (
              <MarkdownMessage text={detail.taskMd} />
            ) : (
              <p className="muted">No task.md found.</p>
            )}
          </div>

          {transcriptLoading ? <p className="muted">Loading transcript…</p> : null}
          {transcript?.error ? <p className="mlebench-error">{transcript.error}</p> : null}
          {transcript && !transcript.settled ? (
            <p className="mlebench-warn">
              Run never reached a clean end (killed, crashed, or timed out mid-turn) — this is
              every turn found in the trace up to that point, nothing hidden after it.
            </p>
          ) : null}
          {transcript && transcript.episodeCount > 1 ? (
            <p className="muted">
              {transcript.episodeCount} episodes (context was compacted and/or the stream was
              retried during this run) — {transcript.turnCount} turns total across all of them.
            </p>
          ) : null}

          <div className="mlebench-transcript-list">
            {transcript?.items.slice(0, visibleCount).map((item, i) => (
              <TranscriptItemCard key={i} item={item} />
            ))}
          </div>
          {transcript && visibleCount < transcript.items.length ? (
            <button
              type="button"
              className="mlebench-load-more"
              onClick={() => setVisibleCount((v) => v + PAGE_SIZE)}
            >
              Load more ({transcript.items.length - visibleCount} remaining)
            </button>
          ) : null}
        </section>
      )}
    </main>
  );
}

function TranscriptItemCard({ item }: { item: TranscriptItem }) {
  if (item.kind === "compaction") {
    return (
      <div className="mlebench-divider">
        context compacted{item.reason ? ` — ${item.reason}` : ""}
        {item.summary ? <ExpandableText text={item.summary} collapsedMaxHeight="4em" /> : null}
      </div>
    );
  }
  if (item.kind === "retry") {
    return (
      <div className="mlebench-divider">
        {item.success == null
          ? `retrying after a stream error${item.errorMessage ? `: ${item.errorMessage}` : ""}`
          : item.success
            ? "retry succeeded"
            : "retry gave up"}
      </div>
    );
  }

  const resultsByToolCallId = new Map(item.toolResults.map((r) => [r.toolCallId, r]));

  return (
    <div className={`mlebench-msg mlebench-msg-${item.role}`}>
      <div className="mlebench-msg-label">
        {item.role}
        {item.episode > 1 ? ` · episode ${item.episode}` : ""}
      </div>
      {item.content.map((block, i) => {
        if (block.kind === "text" && block.text) {
          return <MarkdownMessage key={i} text={block.text} />;
        }
        if (block.kind === "thinking" && block.text) {
          return (
            <details key={i} className="mlebench-thinking">
              <summary>thinking</summary>
              <ExpandableText text={block.text} collapsedMaxHeight="8em" />
            </details>
          );
        }
        if (block.kind === "toolCall") {
          const result = block.toolCallId ? resultsByToolCallId.get(block.toolCallId) : undefined;
          return (
            <div key={i} className="mlebench-toolcall-pair">
              <pre className="mlebench-toolcall">
                {block.toolName}({JSON.stringify(block.arguments, null, 2)})
              </pre>
              {result ? (
                <div className={`mlebench-msg mlebench-msg-tool${result.isError ? " mlebench-msg-error" : ""}`}>
                  <div className="mlebench-msg-label">result — {result.toolName}</div>
                  <ExpandableText text={result.text} collapsedMaxHeight="6em" />
                </div>
              ) : (
                <p className="muted">no result recorded (run likely ended before this call finished)</p>
              )}
            </div>
          );
        }
        return null;
      })}
    </div>
  );
}
