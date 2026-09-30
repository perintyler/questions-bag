/**
 * The list and answer routes, through the real service: what Supervisor
 * relies on when it polls for questions and answers them as the user.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type TestServer } from "./testServer.js";

const SECRET = "barry_questions_routes_secret";

let server: TestServer;

beforeAll(async () => {
  server = await startServer(SECRET);
}, 30_000);

afterAll(() => {
  server?.stop();
});

function call(path: string, init: { method?: string; body?: unknown } = {}) {
  return fetch(`${server.base}${path}`, {
    method: init.method ?? "GET",
    headers: { authorization: `Bearer ${SECRET}`, "content-type": "application/json" },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
}

async function ask(): Promise<string> {
  const res = await call("/questions", {
    method: "POST",
    body: {
      requester: "routes-test",
      questions: [{ id: "q1", question: "Which?", kind: "choice", multiSelect: false, options: [{ label: "A" }] }],
    },
  });
  expect(res.status).toBe(200);
  return ((await res.json()) as { id: string }).id;
}

describe("answering as supervisor", () => {
  it("accepts answered_by: supervisor and records it", async () => {
    const id = await ask();
    const res = await call(`/questions/${id}/answer`, {
      method: "POST",
      body: { answers: [{ questionId: "q1", selected: ["A"] }], answered_by: "supervisor" },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ state: "answered", answered_by: "supervisor", changed: true });
  });

  it("accepts dismissed_by and a delivery report from supervisor", async () => {
    const id = await ask();
    const delivery = await call(`/questions/${id}/delivery`, {
      method: "POST",
      body: { surface: "supervisor", delivered: true },
    });
    expect(delivery.status).toBe(200);
    const dismissed = await call(`/questions/${id}/dismiss`, { method: "POST", body: { dismissed_by: "supervisor" } });
    expect(dismissed.status).toBe(200);
    expect(await dismissed.json()).toMatchObject({ state: "dismissed", answered_by: "supervisor" });
  });

  it("still refuses a surface it does not know", async () => {
    const id = await ask();
    const res = await call(`/questions/${id}/answer`, {
      method: "POST",
      body: { answers: [{ questionId: "q1", selected: ["A"] }], answered_by: "slack" },
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: string }).error).toContain("supervisor");
  });
});

describe("GET /questions filters", () => {
  it("caps the list with ?limit=", async () => {
    await ask();
    await ask();
    const res = await call("/questions?limit=1");
    expect(res.status).toBe(200);
    expect(await res.json()).toHaveLength(1);
  });

  it("refuses a limit it cannot honour", async () => {
    for (const limit of ["0", "abc", "501"]) {
      expect((await call(`/questions?limit=${limit}`)).status).toBe(400);
    }
  });

  it("filters with ?since= as epoch ms or ISO", async () => {
    const id = await ask();
    const past = Date.now() - 60_000;
    const future = Date.now() + 60 * 60_000;

    const recent = (await (await call(`/questions?since=${past}&limit=500`)).json()) as Array<{ id: string }>;
    expect(recent.map((q) => q.id)).toContain(id);

    const iso = (await (await call(`/questions?since=${new Date(past).toISOString()}&limit=500`)).json()) as Array<{ id: string }>;
    expect(iso.map((q) => q.id)).toContain(id);

    expect(await (await call(`/questions?since=${future}`)).json()).toEqual([]);
  });

  it("refuses a since that is not a time", async () => {
    expect((await call("/questions?since=yesterday")).status).toBe(400);
  });

  it("still asks for the secret before it validates anything", async () => {
    const res = await fetch(`${server.base}/questions?limit=abc`);
    expect(res.status).toBe(401);
  });
});
