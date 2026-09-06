// Shared e2e build step.
//
// Why this exists: the suite's scripts fell into two groups — most build
// their own fakecore/alayaface-server into a private temp dir, while the
// older three (reasoning-level, preset-reorder, attachment-drop) exec
// src-go/bin/* and assume someone else built it. Nothing in `make e2e` or
// CI ever builds that path, so those three only worked on a dev machine
// where `make build-go`/`make test-go` had left the binaries behind. On a
// clean checkout they die with `spawn ... ENOENT` — and because the CI loop
// ignored each script's exit status, the e2e job stayed green anyway.
//
// `go build` is incremental, so calling this from every script costs ~0 when
// the binaries are current.
import { execSync } from "child_process";
import { existsSync, mkdirSync } from "fs";
import { join } from "path";

const TARGETS = [
  ["fakecore", "./internal/fakecore"],
  ["alayaface-server", "./cmd/alayaface-server"],
];

/** Build fakecore + alayaface-server into src-go/bin; return {fakecore, server}. */
export function buildGoBinaries(repoRoot) {
  const binDir = join(repoRoot, "src-go", "bin");
  mkdirSync(binDir, { recursive: true });

  const built = {};
  for (const [name, pkg] of TARGETS) {
    const out = join(binDir, name);
    try {
      execSync(`go build -o "${out}" ${pkg}`, {
        cwd: join(repoRoot, "src-go"),
        stdio: ["ignore", "ignore", "pipe"],
      });
    } catch (e) {
      // Surface the compiler's own words: a script with no backend has
      // nothing to test, and "Command failed" alone would send the next
      // reader hunting instead of telling them what broke.
      const detail = (e.stderr || e.stdout || "").toString().trim();
      throw new Error(`go build ${pkg} failed${detail ? ":\n" + detail : ""}`);
    }
    if (!existsSync(out)) throw new Error(`go build produced no ${out}`);
    built[name] = out;
  }

  return { fakecore: built["fakecore"], server: built["alayaface-server"] };
}
