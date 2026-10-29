// PM2 process map for a Hetzner VPS node (plan §6: keeper #2/#3 + relayer #2 + warmer).
// Usage (from backend/, after `npm ci && npm run build` and a populated .env):
//   pm2 start deploy/ecosystem.config.cjs
// Each service imports dotenv at startup, so .env in cwd is loaded automatically.
module.exports = {
  apps: [
    {
      name: "keeper",
      script: "dist/services/keeper.js",
      instances: 1,
      autorestart: true,
      max_restarts: 50,
      restart_delay: 5000,
      env: { NODE_ENV: "production" },
    },
    {
      name: "relayer",
      script: "dist/services/relayer.js",
      instances: 1,
      autorestart: true,
      max_restarts: 50,
      restart_delay: 5000,
      env: { NODE_ENV: "production" },
    },
    {
      name: "warmer",
      script: "dist/services/warmer.js",
      instances: 1,
      autorestart: true,
      max_restarts: 50,
      restart_delay: 5000,
      env: { NODE_ENV: "production" },
    },
  ],
};
