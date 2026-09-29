/**
 * Who may reach the questions service, tested against the real server process.
 *
 * The page used to fetch BARRY_SECRET from an unauthenticated `/config` route.
 * Now nothing serves the secret: an app sends it, and a browser signs in once
 * and holds a session cookie.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SECRET = "barry_questions_test_secret";
const HERE = dirname(fileURLToPath(import.meta.url));

let child: ChildProcess;
let base: string;

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

beforeAll(async () => {
  const port = await freePort();
  base = `http://127.0.0.1:${port}`;
  const scratch = mkdtempSync(join(tmpdir(), "questions-auth-"));
  child = spawn(process.execPath, ["--import", "tsx", join(HERE, "index.ts")], {
    env: {
      ...process.env,
      PORT: String(port),
      BARRY_SECRET: SECRET,
      BARRY_QUESTIONS_DB: join(scratch, "questions.db"),
    },
    stdio: "ignore",
  });
  for (let attempt = 0; attempt < 200; attempt++) {
    try {
      if ((await fetch(`${base}/health`)).ok) return;
    } catch {
      // not listening yet
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("the questions service never answered /health");
}, 30_000);

afterAll(() => {
  child?.kill();
});

describe("questions service auth", () => {
  it("serves the secret to nobody", async () => {
    const res = await fetch(`${base}/config`);
    expect(res.status).toBe(404);
    expect(await res.text()).not.toContain(SECRET);
  });

  it("refuses a request with neither the secret nor a session", async () => {
    const res = await fetch(`${base}/questions`);
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "unauthorized", signIn: "/sign-in" });
  });

  it("admits an app carrying the secret", async () => {
    const res = await fetch(`${base}/questions`, { headers: { authorization: `Bearer ${SECRET}` } });
    expect(res.status).toBe(200);
  });

  it("admits a browser once it has signed in", async () => {
    const signIn = await fetch(`${base}/sign-in`, {
      method: "POST",
      redirect: "manual",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ secret: SECRET }).toString(),
    });
    expect(signIn.status).toBe(303);
    const cookie = (signIn.headers.get("set-cookie") ?? "").split(";")[0];
    const res = await fetch(`${base}/questions`, { headers: { cookie } });
    expect(res.status).toBe(200);
  });
});
