export type WsMessage =
  | { type: "trade"; data: Record<string, unknown> }
  | { type: "liquidation"; data: Record<string, unknown> }
  | { type: "price"; data: { token: string; price: string; timestamp: number } }
  | { type: "pool"; data: { nav: string; reserved: string; utilizationBps: number; sharePrice: string } };

type Handler = (msg: WsMessage) => void;

/// Reconnecting WebSocket client for /ws/live with exponential backoff.
export class LiveSocket {
  private ws: WebSocket | null = null;
  private handlers = new Set<Handler>();
  private backoff = 1000;
  private readonly maxBackoff = 30_000;
  private closed = false;

  constructor(private readonly url: string) {}

  connect(): void {
    this.closed = false;
    this.open();
  }

  private open(): void {
    if (this.closed) return;
    try {
      this.ws = new WebSocket(this.url);
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.ws.onopen = () => {
      this.backoff = 1000;
    };
    this.ws.onmessage = (ev: MessageEvent) => {
      try {
        const msg = JSON.parse(String(ev.data)) as WsMessage;
        for (const h of this.handlers) h(msg);
      } catch {
        // ignore malformed frames
      }
    };
    this.ws.onclose = () => this.scheduleReconnect();
    this.ws.onerror = () => this.ws?.close();
  }

  private scheduleReconnect(): void {
    if (this.closed) return;
    setTimeout(() => this.open(), this.backoff);
    this.backoff = Math.min(this.backoff * 2, this.maxBackoff);
  }

  on(handler: Handler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  close(): void {
    this.closed = true;
    this.ws?.close();
    this.ws = null;
  }
}
