import { NextResponse } from "next/server";
import path from "node:path";

import { resolveRunDir } from "@/lib/mlebenchRuns";
import { readTranscript } from "@/lib/mlebenchTranscript";

export const dynamic = "force-dynamic";

interface RouteParams {
  params: Promise<{ experimentSet: string; competitionId: string; timestamp: string }>;
}

export async function GET(_req: Request, { params }: RouteParams) {
  const { experimentSet, competitionId, timestamp } = await params;

  const dir = await resolveRunDir(experimentSet, competitionId, timestamp);
  if (!dir) {
    return NextResponse.json({ error: "case not found" }, { status: 404 });
  }

  try {
    const traceFile = path.join(dir, "host-logs", "pi-events.jsonl");
    const { items, turnCount, episodeCount, settled } = await readTranscript(traceFile);
    return NextResponse.json({ items, turnCount, episodeCount, settled, error: null });
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 500 },
    );
  }
}
