import { timingSafeEqual } from "node:crypto";
import type { FastifyReply, FastifyRequest } from "fastify";

export const APP_TOKEN_HEADER = "x-cadence-app-token";

/** Constant-time comparison against any accepted token (supports rotation). */
export function isAcceptedToken(candidate: string | undefined, accepted: string[]): boolean {
  if (!candidate) return false;
  const candidateBuffer = Buffer.from(candidate);
  let match = false;
  for (const token of accepted) {
    const tokenBuffer = Buffer.from(token);
    if (tokenBuffer.length === candidateBuffer.length && timingSafeEqual(tokenBuffer, candidateBuffer)) match = true;
  }
  return match;
}

/** Rejects requests without a valid app token (health checks are public). */
export function appTokenHook(accepted: string[]) {
  return async (request: FastifyRequest, reply: FastifyReply): Promise<void> => {
    if (request.url.startsWith("/healthz")) return;
    const header = request.headers[APP_TOKEN_HEADER];
    const token = Array.isArray(header) ? header[0] : header;
    if (!isAcceptedToken(token, accepted)) {
      await reply.code(401).send({ error: { status: "UNAUTHENTICATED", message: "Missing or invalid app token" } });
    }
  };
}
