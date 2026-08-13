"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";

import { ThemeToggle } from "@/components/ThemeToggle";

interface CaseSummary {
  experimentSet: string;
  competitionId: string;
  timestamp: string;
  model: string | null;
  status: string | null;
  score: number | null;
  bronzeThreshold: number | null;
  isLowerBetter: boolean | null;
  anyMedal: boolean | null;
  validSubmission: boolean | null;
  startedAtUtc: string | null;
  durationSeconds: number | null;
}

export default function MlebenchListPage() {
  const [cases, setCases] = useState<CaseSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");

  useEffect(() => {
    let cancelled = false;
    fetch("/api/mlebench/cases")
      .then((r) => r.json())
      .then((data) => {
        if (cancelled) return;
        setCases(data.cases ?? []);
        setError(data.error ?? null);
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const visibleCases = useMemo(() => {
    const q = filter.trim().toLowerCase();
    const filtered = q
      ? cases.filter(
          (c) =>
            c.competitionId.toLowerCase().includes(q) ||
            (c.status ?? "").toLowerCase().includes(q),
        )
      : cases;
    return filtered.slice().sort((a, b) => a.competitionId.localeCompare(b.competitionId));
  }, [cases, filter]);

  return (
    <main className="page-shell mlebench-shell">
      <header className="app-bar">
        <div className="app-bar-title">Gemma MLE-bench Runs</div>
        <ThemeToggle />
      </header>

      <div className="mlebench-list-body">
        <input
          className="mlebench-filter"
          placeholder="Filter by competition / status..."
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
        />

        {loading ? <p className="muted">Loading cases…</p> : null}
        {error ? <p className="mlebench-error">{error}</p> : null}
        {!loading && !error && cases.length === 0 ? (
          <p className="muted">No Gemma runs found under mle-bench/runs.</p>
        ) : null}

        <section className="mlebench-set">
          {visibleCases.map((run) => (
            <div key={run.competitionId} className="mlebench-competition">
              <h3>{run.competitionId}</h3>
              <ul className="mlebench-run-list">
                <li>
                  <Link
                    href={`/mlebench/${run.experimentSet}/${run.competitionId}/${run.timestamp}`}
                    className="mlebench-run-link"
                  >
                    <span className={`mlebench-badge mlebench-badge-${run.status ?? "unknown"}`}>
                      {run.status ?? "unknown"}
                    </span>
                    <span className="mlebench-run-ts">{run.timestamp}</span>
                    <span className="mlebench-run-model">{run.model ?? "?"}</span>
                    <span className="mlebench-run-score">
                      {run.score != null ? `score ${run.score}` : "no score"}
                      {run.bronzeThreshold != null ? ` · bronze ${run.bronzeThreshold}` : ""}
                    </span>
                    {run.anyMedal ? <span className="mlebench-medal">medal</span> : null}
                  </Link>
                </li>
              </ul>
            </div>
          ))}
        </section>
      </div>
    </main>
  );
}
