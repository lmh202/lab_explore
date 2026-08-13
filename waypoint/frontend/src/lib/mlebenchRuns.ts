import fs from "node:fs/promises";
import path from "node:path";

// Server-only helpers for the temporary mle-bench viewer (app/mlebench/*,
// app/api/mlebench/*). Reads run directories straight off disk -- this is a
// local, throwaway internal tool, deliberately decoupled from Waypoint's own
// FastAPI backend, auth, and session/runtime model.

export interface RunRef {
  experimentSet: string;
  competitionId: string;
  timestamp: string;
  dir: string;
}

interface RunSelectionMetadata {
  pi?: { model?: string };
}

const VISIBLE_MODEL = "nvidia/Gemma-4-26B-A4B-NVFP4";

function resolveRunsDir(): string {
  if (process.env.MLEBENCH_RUNS_DIR) {
    return path.resolve(process.env.MLEBENCH_RUNS_DIR);
  }
  // waypoint/frontend -> repo root is two levels up. (turbopackIgnore: this
  // cwd-relative resolve is dev-server-only file access, not a bundler
  // import, but Turbopack's static analyzer can't tell the difference.)
  return path.resolve(/* turbopackIgnore: true */ process.cwd(), "..", "..", "mle-bench", "runs");
}

async function listSubdirs(dirPath: string): Promise<string[]> {
  try {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });
    return entries.filter((e) => e.isDirectory()).map((e) => e.name);
  } catch {
    return [];
  }
}

async function exists(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

// Enumerates every real baseline run directory. This stays private so the API
// cannot accidentally expose hidden models or superseded attempts.
async function discoverAllRuns(): Promise<RunRef[]> {
  const runsDir = resolveRunsDir();
  const refs: RunRef[] = [];
  for (const experimentSet of await listSubdirs(runsDir)) {
    const setDir = path.join(runsDir, experimentSet);
    for (const competitionId of await listSubdirs(setDir)) {
      const baselineDir = path.join(setDir, competitionId, "baseline");
      for (const timestamp of await listSubdirs(baselineDir)) {
        const dir = path.join(baselineDir, timestamp);
        if (await exists(path.join(dir, "run.json"))) {
          refs.push({ experimentSet, competitionId, timestamp, dir });
        }
      }
    }
  }
  return refs;
}

// Negative means a should be shown instead of b.
function compareCandidateRuns(
  a: { ref: RunRef; run: RunSelectionMetadata },
  b: { ref: RunRef; run: RunSelectionMetadata },
): number {
  return b.ref.timestamp.localeCompare(a.ref.timestamp);
}

// Public discovery is deliberately curated: only the requested Gemma model
// is visible, and exactly one attempt is retained per competition: the latest
// run-directory timestamp, regardless of completion or submission status.
//
// This function is also the route allowlist. Detail/transcript endpoints call
// it through resolveRunDir(), so a hand-written URL cannot reveal a Qwen or
// superseded Gemma run.
export async function discoverRuns(): Promise<RunRef[]> {
  const candidates: { ref: RunRef; run: RunSelectionMetadata }[] = [];
  for (const ref of await discoverAllRuns()) {
    const run = await readJsonIfExists<RunSelectionMetadata>(path.join(ref.dir, "run.json"));
    if (run?.pi?.model === VISIBLE_MODEL) {
      candidates.push({ ref, run });
    }
  }

  const latestByCompetition = new Map<
    string,
    { ref: RunRef; run: RunSelectionMetadata }
  >();
  for (const candidate of candidates) {
    const current = latestByCompetition.get(candidate.ref.competitionId);
    if (!current || compareCandidateRuns(candidate, current) < 0) {
      latestByCompetition.set(candidate.ref.competitionId, candidate);
    }
  }

  return [...latestByCompetition.values()]
    .sort((a, b) => a.ref.competitionId.localeCompare(b.ref.competitionId))
    .map(({ ref }) => ref);
}

export async function resolveRunDir(
  experimentSet: string,
  competitionId: string,
  timestamp: string,
): Promise<string | null> {
  const refs = await discoverRuns();
  const match = refs.find(
    (r) =>
      r.experimentSet === experimentSet &&
      r.competitionId === competitionId &&
      r.timestamp === timestamp,
  );
  return match ? match.dir : null;
}

export async function readTextIfExists(filePath: string): Promise<string | null> {
  try {
    return await fs.readFile(filePath, "utf-8");
  } catch {
    return null;
  }
}

export async function readJsonIfExists<T = unknown>(filePath: string): Promise<T | null> {
  const raw = await readTextIfExists(filePath);
  if (raw == null) return null;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

export async function listDirShallow(
  dirPath: string,
): Promise<{ name: string; size: number }[]> {
  try {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });
    const out: { name: string; size: number }[] = [];
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      const stat = await fs.stat(path.join(dirPath, entry.name));
      out.push({ name: entry.name, size: stat.size });
    }
    out.sort((a, b) => a.name.localeCompare(b.name));
    return out;
  } catch {
    return [];
  }
}

export interface CsvPreview {
  header: string;
  rows: string[];
  totalRows: number;
}

export async function readCsvPreview(
  filePath: string,
  maxRows = 20,
): Promise<CsvPreview | null> {
  const raw = await readTextIfExists(filePath);
  if (raw == null) return null;
  const lines = raw.split(/\r\n|\n/).filter((line) => line.length > 0);
  if (lines.length === 0) return null;
  return {
    header: lines[0],
    rows: lines.slice(1, 1 + maxRows),
    totalRows: Math.max(0, lines.length - 1),
  };
}
