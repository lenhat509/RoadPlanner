import rateLimit from "@fastify/rate-limit";
import Fastify, { type FastifyInstance } from "fastify";
import { z } from "zod";

import { APP_TOKEN_HEADER, appTokenHook } from "./auth.js";
import type { AppConfig } from "./config.js";
import type { FuelPriceService } from "./eia/client.js";
import type { LodgingService } from "./expedia/lodging.js";
import { NotConfiguredError, UpstreamError } from "./http.js";

export interface ServerDependencies {
  config: AppConfig;
  lodging?: LodgingService;
  fuel?: FuelPriceService;
  logger?: boolean | { level: string };
}

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");

export const lodgingQuerySchema = z
  .object({
    lat: z.coerce.number().min(-90).max(90),
    lng: z.coerce.number().min(-180).max(180),
    radiusKm: z.coerce.number().positive().max(50).default(25),
    checkin: isoDate,
    checkout: isoDate,
    adults: z.coerce.number().int().min(1).max(8).default(2),
  })
  .refine((query) => query.checkout > query.checkin, { message: "checkout must be after checkin", path: ["checkout"] });

export const fuelQuerySchema = z.object({
  lat: z.coerce.number().min(-90).max(90),
  lng: z.coerce.number().min(-180).max(180),
  fuelType: z.enum(["regular", "midgrade", "premium", "diesel"]).default("regular"),
});

/** Builds the Fastify app. Exported separately from `listen` so tests can use `inject`. */
export async function buildServer(dependencies: ServerDependencies): Promise<FastifyInstance> {
  const { config } = dependencies;
  const app = Fastify({ logger: dependencies.logger ?? false, trustProxy: true });

  await app.register(rateLimit, {
    max: config.rateLimitPerMinute,
    timeWindow: "1 minute",
    keyGenerator: (request) => {
      const token = request.headers[APP_TOKEN_HEADER];
      return `${request.ip}|${Array.isArray(token) ? token[0] : (token ?? "")}`;
    },
  });
  app.addHook("onRequest", appTokenHook(config.appTokens));

  // Google-style error envelope, which the iOS client already understands.
  app.setErrorHandler((error, request, reply) => {
    if (error instanceof z.ZodError) {
      const message = error.issues.map((issue) => `${issue.path.join(".")}: ${issue.message}`).join("; ");
      return reply.code(400).send({ error: { status: "INVALID_ARGUMENT", message } });
    }
    if (error instanceof NotConfiguredError) {
      return reply.code(503).send({ error: { status: "UNAVAILABLE", message: error.message } });
    }
    if (error instanceof UpstreamError) {
      request.log.warn({ provider: error.provider, status: error.status }, "upstream failure");
      return reply.code(502).send({ error: { status: "BAD_GATEWAY", message: `${error.provider} is unavailable` } });
    }
    const statusCode = (error as { statusCode?: number }).statusCode;
    if (statusCode && statusCode < 500) {
      return reply.code(statusCode).send({ error: { status: "REQUEST_ERROR", message: (error as Error).message } });
    }
    request.log.error(error);
    return reply.code(500).send({ error: { status: "INTERNAL", message: "Internal error" } });
  });

  app.get("/healthz", async () => ({ status: "ok" }));

  app.get("/v1/lodging/rates", async (request) => {
    const query = lodgingQuerySchema.parse(request.query);
    if (!dependencies.lodging) throw new NotConfiguredError("Lodging rates (Expedia Rapid)");
    const offers = await dependencies.lodging.ratesNear({ ...query, customerIp: request.ip });
    return { offers };
  });

  app.get("/v1/fuel/average", async (request) => {
    const query = fuelQuerySchema.parse(request.query);
    if (!dependencies.fuel) throw new NotConfiguredError("Fuel prices (EIA)");
    return dependencies.fuel.averageNear(query.lat, query.lng, query.fuelType);
  });

  return app;
}
