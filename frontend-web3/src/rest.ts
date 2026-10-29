import type { Market, PoolState, PositionView, OracleStatus } from "./types.js";

/// Thin typed client over the backend REST API (§4.3).
export class RestClient {
  constructor(private readonly baseUrl: string) {}

  private async get<T>(path: string): Promise<T> {
    const res = await fetch(`${this.baseUrl}${path}`, { headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(`GET ${path} -> ${res.status}`);
    return (await res.json()) as T;
  }

  markets(): Promise<Market[]> {
    return this.get<Market[]>("/markets");
  }

  market(token: string): Promise<{ stats: unknown; status: OracleStatus; volume24h: string }> {
    return this.get(`/markets/${token}`);
  }

  oracleStatus(token: string): Promise<OracleStatus> {
    return this.get<OracleStatus>(`/oracle/${token}/status`);
  }

  oracleSnapshots(token: string): Promise<Array<{ price: string; timestamp: string }>> {
    return this.get(`/oracle/${token}/snapshots`);
  }

  positions(addr: string): Promise<PositionView[]> {
    return this.get<PositionView[]>(`/positions/${addr}`);
  }

  history(addr: string): Promise<PositionView[]> {
    return this.get<PositionView[]>(`/history/${addr}`);
  }

  tape(): Promise<PositionView[]> {
    return this.get<PositionView[]>("/tape");
  }

  leaderboard(): Promise<unknown[]> {
    return this.get<unknown[]>("/leaderboard");
  }

  pool(): Promise<PoolState & { events: unknown[] }> {
    return this.get("/pool");
  }
}
