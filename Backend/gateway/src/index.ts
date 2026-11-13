import { loadConfig } from "./config.js";
import { EiaClient, FuelPriceService } from "./eia/client.js";
import { ExpediaRapidClient } from "./expedia/client.js";
import { LodgingService } from "./expedia/lodging.js";
import { buildServer } from "./server.js";

const config = loadConfig();
const app = await buildServer({
  config,
  logger: { level: config.logLevel },
  lodging: config.expedia ? new LodgingService(new ExpediaRapidClient(config.expedia)) : undefined,
  fuel: config.eiaApiKey ? new FuelPriceService(new EiaClient(config.eiaApiKey)) : undefined,
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    app.log.info({ signal }, "shutting down");
    void app.close().then(() => process.exit(0));
  });
}

await app.listen({ port: config.port, host: config.host });
app.log.info({ expedia: Boolean(config.expedia), eia: Boolean(config.eiaApiKey) }, "cadence gateway ready");
