import { NextResponse } from "next/server";
import path from "node:path";

import { discoverRuns, readJsonIfExists } from "@/lib/mlebenchRuns";

export const dynamic = "force-dynamic";

interface RunJsonShape {
  pi?: { model?: string };
  status?: string;
  started_at_utc?: string;
  duration_seconds?: number;
  grade?: {
    score?: number | null;
    bronze_threshold?: number;
    is_lower_better?: boolean;
    any_medal?: boolean;
    valid_submission?: boolean;
  };
}

export async function GET() {
  try {
    const refs = await discoverRuns();
    const cases = await Promise.all(
      refs.map(async (ref) => {
        const run = await readJsonIfExists<RunJsonShape>(path.join(ref.dir, "run.json"));
        return {
          experimentSet: ref.experimentSet,
          competitionId: ref.competitionId,
          timestamp: ref.timestamp,
          model: run?.pi?.model ?? null,
          status: run?.status ?? null,
          score: run?.grade?.score ?? null,
          bronzeThreshold: run?.grade?.bronze_threshold ?? null,
          isLowerBetter: run?.grade?.is_lower_better ?? null,
          anyMedal: run?.grade?.any_medal ?? null,
          validSubmission: run?.grade?.valid_submission ?? null,
          startedAtUtc: run?.started_at_utc ?? null,
          durationSeconds: run?.duration_seconds ?? null,
        };
      }),
    );
    cases.sort((a, b) => (a.startedAtUtc ?? "").localeCompare(b.startedAtUtc ?? ""));
    return NextResponse.json({ cases, error: null });
  } catch (err) {
    return NextResponse.json({
      cases: [],
      error: err instanceof Error ? err.message : String(err),
    });
  }
}
