// Vercel serverless entry for the REST API. Boots the Fastify app once per warm container and
// forwards each request into it. Imports the COMPILED output (dist/), produced by the build command,
// so there is no TypeScript/.js-resolution work for the bundler to do here.
import { buildApp } from "../dist/services/api.js";

let appPromise;

export default async function handler(req, res) {
  if (!appPromise) {
    appPromise = (async () => {
      const app = await buildApp();
      await app.ready();
      return app;
    })();
  }
  const app = await appPromise;
  app.server.emit("request", req, res);
}
