import type { FetchLike } from "../src/http.js";

export interface RecordedCall {
  url: URL;
  init?: RequestInit;
}

/** A fake `fetch` that records calls and answers from a list of handlers. */
export function fakeFetch(handler: (url: URL, init?: RequestInit) => Response | Promise<Response>): FetchLike & { calls: RecordedCall[] } {
  const calls: RecordedCall[] = [];
  const fn = (async (input: string | URL, init?: RequestInit) => {
    const url = new URL(input.toString());
    calls.push({ url, init });
    return handler(url, init);
  }) as FetchLike & { calls: RecordedCall[] };
  fn.calls = calls;
  return fn;
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

export const TEST_TOKEN = "test-token-0123456789abcdef";
