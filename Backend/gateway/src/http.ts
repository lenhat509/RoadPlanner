/** Minimal fetch signature so upstream calls can be faked in tests. */
export type FetchLike = (input: string | URL, init?: RequestInit) => Promise<Response>;

/** An upstream provider (Expedia, EIA) failed. Mapped to HTTP 502. */
export class UpstreamError extends Error {
  constructor(
    readonly provider: string,
    readonly status: number,
    message: string,
  ) {
    super(`${provider} responded ${status}: ${message}`);
    this.name = "UpstreamError";
  }
}

/** A feature is not configured on this deployment (missing credentials). Mapped to HTTP 503. */
export class NotConfiguredError extends Error {
  constructor(readonly feature: string) {
    super(`${feature} is not configured on this gateway`);
    this.name = "NotConfiguredError";
  }
}
