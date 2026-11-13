import { createHash } from "node:crypto";

/**
 * Expedia Rapid request signature: SHA-512 hex of `apiKey + sharedSecret + timestamp`
 * (timestamp in whole seconds since the Unix epoch).
 */
export function eanSignature(apiKey: string, sharedSecret: string, timestampSeconds: number): string {
  return createHash("sha512").update(`${apiKey}${sharedSecret}${timestampSeconds}`).digest("hex");
}

/** `Authorization` header value for Expedia Rapid. */
export function eanAuthorizationHeader(apiKey: string, sharedSecret: string, nowMs: number = Date.now()): string {
  const timestamp = Math.floor(nowMs / 1000);
  return `EAN APIKey=${apiKey},Signature=${eanSignature(apiKey, sharedSecret, timestamp)},timestamp=${timestamp}`;
}
