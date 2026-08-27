import net from "node:net";

const requestTimeoutMs = 10_000;

export class HerdrClient {
  private nextId = 1;
  private subscriptions = new Set<() => void>();

  constructor(private readonly socketPath: string) {}

  request(method: string, params: Record<string, unknown> = {}) {
    const id = `sympp:${process.pid}:${this.nextId++}`;
    return new Promise<unknown>((resolve, reject) => {
      const socket = net.createConnection(socketEndpoint(this.socketPath));
      let buffer = "";
      let settled = false;
      const finish = (error?: Error, value?: unknown) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        socket.destroy();
        if (error) reject(error);
        else resolve(value);
      };
      const timeout = setTimeout(() => finish(new Error("Herdr request timed out")), requestTimeoutMs);
      timeout.unref();
      socket.setEncoding("utf8");
      socket.on("connect", () => socket.write(`${JSON.stringify({ id, method, params })}\n`));
      socket.on("data", (chunk: string) => {
        buffer += chunk;
        let newline = buffer.indexOf("\n");
        while (newline >= 0) {
          const line = buffer.slice(0, newline).trim();
          buffer = buffer.slice(newline + 1);
          if (line) {
            let message: { id?: string; result?: unknown; error?: unknown };
            try {
              const parsed = JSON.parse(line) as unknown;
              if (!parsed || typeof parsed !== "object") throw new Error("Invalid Herdr response");
              message = parsed as typeof message;
            } catch (error) {
              finish(error instanceof Error ? error : new Error("Invalid Herdr response"));
              return;
            }
            if (message.id === id) {
              finish(message.error ? new Error(JSON.stringify(message.error)) : undefined, message.result);
              return;
            }
          }
          newline = buffer.indexOf("\n");
        }
      });
      socket.on("error", (error) => finish(error));
      socket.on("close", () => finish(new Error("Herdr socket closed")));
    });
  }

  async subscribe(types: string[], listener: (event: unknown) => void | Promise<void>) {
    let socket: net.Socket | undefined;
    let reconnect: NodeJS.Timeout | undefined;
    let stopped = false;
    let delivery = Promise.resolve();

    const connect = () => new Promise<void>((resolve, reject) => {
      let buffer = "";
      const id = `sympp:${process.pid}:${this.nextId++}`;
      socket = net.createConnection(socketEndpoint(this.socketPath));
      socket.setEncoding("utf8");
      socket.on("connect", () => {
        socket?.write(`${JSON.stringify({
          id,
          method: "events.subscribe",
          params: { subscriptions: types.map((type) => ({ type })) },
        })}\n`);
        resolve();
      });
      socket.on("data", (chunk: string) => {
        buffer += chunk;
        let newline = buffer.indexOf("\n");
        while (newline >= 0) {
          const line = buffer.slice(0, newline).trim();
          buffer = buffer.slice(newline + 1);
          if (line) {
            try {
              const parsed = JSON.parse(line) as unknown;
              if (parsed && typeof parsed === "object") {
                const message = parsed as { id?: string };
                if (message.id !== id) delivery = delivery.then(() => listener(message)).catch(() => undefined);
              }
            } catch {
              // Ignore malformed event lines; a later valid event can still reconcile the snapshot.
            }
          }
          newline = buffer.indexOf("\n");
        }
      });
      socket.on("error", reject);
      socket.on("close", () => {
        if (stopped) return;
        reconnect = setTimeout(() => void connect().catch(() => undefined), 1000);
        reconnect.unref();
      });
    });

    const stop = () => {
      stopped = true;
      if (reconnect) clearTimeout(reconnect);
      socket?.destroy();
      this.subscriptions.delete(stop);
    };
    this.subscriptions.add(stop);
    try {
      await connect();
    } catch (error) {
      stop();
      throw error;
    }
    return stop;
  }

  close() {
    for (const stop of [...this.subscriptions]) stop();
  }
}

export function socketEndpoint(socketPath: string, platform = process.platform) {
  return platform === "win32" ? `\\\\.\\pipe\\${socketPath}` : socketPath;
}

export function snapshotFromResponse(response: unknown) {
  const result = (response ?? {}) as { snapshot?: unknown; type?: string };
  const snapshot = (result.snapshot ?? result) as Partial<import("./types").HerdrSnapshot>;
  return { ...snapshot, panes: snapshot.panes ?? [] } as import("./types").HerdrSnapshot;
}
