import { z } from "zod";

const schema = z.object({
  PORT: z.coerce.number().int().positive().default(8080),
  HOST: z.string().default("0.0.0.0"),
  LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"]).default("info"),
  /** Comma-separated tokens accepted in `X-Cadence-App-Token` (supports rotation). */
  APP_TOKENS: z.string().min(1, "APP_TOKENS must list at least one token"),
  EXPEDIA_API_KEY: z.string().optional(),
  EXPEDIA_SHARED_SECRET: z.string().optional(),
  /** https://test.ean.com for the Rapid test environment, https://api.ean.com for production. */
  EXPEDIA_BASE_URL: z.string().url().default("https://test.ean.com"),
  EIA_API_KEY: z.string().optional(),
  RATE_LIMIT_PER_MINUTE: z.coerce.number().int().positive().default(120),
});

export interface AppConfig {
  port: number;
  host: string;
  logLevel: string;
  appTokens: string[];
  expedia?: { apiKey: string; sharedSecret: string; baseUrl: string };
  eiaApiKey?: string;
  rateLimitPerMinute: number;
}

/** Parses and validates environment variables; throws with a readable message when invalid. */
export function loadConfig(env: Record<string, string | undefined> = process.env): AppConfig {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const problems = parsed.error.issues.map((issue) => `${issue.path.join(".")}: ${issue.message}`).join("; ");
    throw new Error(`Invalid gateway configuration — ${problems}`);
  }
  const value = parsed.data;
  const appTokens = value.APP_TOKENS.split(",").map((token) => token.trim()).filter(Boolean);
  if (appTokens.some((token) => token.length < 16)) {
    throw new Error("Invalid gateway configuration — APP_TOKENS entries must be at least 16 characters");
  }
  return {
    port: value.PORT,
    host: value.HOST,
    logLevel: value.LOG_LEVEL,
    appTokens,
    expedia:
      value.EXPEDIA_API_KEY && value.EXPEDIA_SHARED_SECRET
        ? { apiKey: value.EXPEDIA_API_KEY, sharedSecret: value.EXPEDIA_SHARED_SECRET, baseUrl: value.EXPEDIA_BASE_URL }
        : undefined,
    eiaApiKey: value.EIA_API_KEY || undefined,
    rateLimitPerMinute: value.RATE_LIMIT_PER_MINUTE,
  };
}
