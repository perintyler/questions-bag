/**
 * Start the real questions service on a free port with a scratch database,
 * for tests that need to go through HTTP. Not a test file itself.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

export interface TestServer {
  base: string;
  stop(): void;
}

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      probe.close(() => (address && typeof address === "object" ? resolve(address.port) : reject(new Error("no port"))));
    });
  });
}

export async function startServer(secret: string): Promise<TestServer> {
  const port = await freePort();
  const base = `http://127.0.0.1:${port}`;
  const scratch = mkdtempSync(join(tmpdir(), "questions-service-"));
  const child: ChildProcess = spawn(process.execPath, ["--import", "tsx", join(HERE, "index.ts")], {
    env: {
      ...process.env,
      PORT: String(port),
      BARRY_SECRET: secret,
      BARRY_QUESTIONS_DB: join(scratch, "questions.db"),
    },
    stdio: "ignore",
  });
  const stop = () => child.kill();
  for (let attempt = 0; attempt < 200; attempt++) {
    try {
      if ((await fetch(`${base}/health`)).ok) return { base, stop };
    } catch {
      // not listening yet
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  stop();
  throw new Error("the questions service never answered /health");
}
