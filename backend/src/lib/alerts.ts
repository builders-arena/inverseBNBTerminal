import { config } from "./config.js";
import { logger } from "./logger.js";

/// Fire-and-forget Telegram alert. No-op when not configured.
export async function alert(message: string): Promise<void> {
  const token = config.TELEGRAM_BOT_TOKEN;
  const chatId = config.TELEGRAM_CHAT_ID;
  if (!token || !chatId) {
    logger.warn({ message }, "alert (telegram not configured)");
    return;
  }
  try {
    const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text: `🜛 inverse: ${message}`, disable_notification: false }),
    });
    if (!res.ok) logger.error({ status: res.status }, "telegram alert failed");
  } catch (err) {
    logger.error({ err }, "telegram alert error");
  }
}
