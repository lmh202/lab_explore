import { NextResponse } from "next/server";
import path from "node:path";

import {
  listDirShallow,
  readCsvPreview,
  readJsonIfExists,
  readTextIfExists,
  resolveRunDir,
} from "@/lib/mlebenchRuns";

export const dynamic = "force-dynamic";

interface RouteParams {
  params: Promise<{ experimentSet: string; competitionId: string; timestamp: string }>;
}

export async function GET(_req: Request, { params }: RouteParams) {
  const { experimentSet, competitionId, timestamp } = await params;

  // Only ever read from a directory that discoverRuns() itself found on
  // disk -- never join the raw route params into a filesystem path, so an
  // unrecognized id 404s instead of opening an arbitrary path.
  const dir = await resolveRunDir(experimentSet, competitionId, timestamp);
  if (!dir) {
    return NextResponse.json({ error: "case not found" }, { status: 404 });
  }

  try {
    const run = await readJsonIfExists(path.join(dir, "run.json"));
    const taskMd = await readTextIfExists(path.join(dir, "workspace", "task.md"));
    const descriptionMd = await readTextIfExists(
      path.join(dir, "workspace", "data", "description.md"),
    );
    const submissionPreview = await readCsvPreview(
      path.join(dir, "workspace", "submission", "submission.csv"),
    );
    const codeFiles = await listDirShallow(path.join(dir, "workspace", "code"));
    const dataFiles = await listDirShallow(path.join(dir, "workspace", "data"));

    return NextResponse.json({
      run,
      taskMd,
      descriptionMd,
      submissionPreview,
      codeFiles,
      dataFiles,
      error: null,
    });
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 500 },
    );
  }
}
