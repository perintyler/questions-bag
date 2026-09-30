/**
 * Who may reach the questions service, tested against the real server process.
 *
 * The page used to fetch BARRY_SECRET from an unauthenticated `/config` route.
 * Now nothing serves the secret: an app sends it, and a browser signs in once
 * and holds a session cookie.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type TestServer } from "./testServer.js";

const SECRET = "barry_questions_test_secret";

let server: TestServer;
let base: string;

beforeAll(async () => {
  server = await startServer(SECRET);
  base = server.base;
}, 30_000);

afterAll(() => {
  server?.stop();
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
