import { connect } from "cloudflare:sockets";

export interface Env {
  VM_HOST: string;
  VM_PORT: string;
}

// Dumb WS<->TCP relay: terminates the client's WebSocket (TLS handled by
// Cloudflare's edge on the workers.dev hostname) and forwards the raw
// message bytes to a plain-TCP VLESS inbound on the VM. Xray on both ends
// handles all VLESS framing; this Worker never parses the protocol.
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    let socket: ReturnType<typeof connect>;
    try {
      socket = connect({ hostname: env.VM_HOST, port: Number(env.VM_PORT) });
    } catch (err) {
      server.close(1011, "upstream connect failed");
      return new Response("Upstream connect failed", { status: 502 });
    }

    const writer = socket.writable.getWriter();

    server.addEventListener("message", (event: MessageEvent) => {
      const data = event.data;
      const chunk =
        typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data as ArrayBuffer);
      writer.write(chunk).catch(() => {});
    });

    server.addEventListener("close", () => {
      writer.close().catch(() => {});
      socket.close().catch(() => {});
    });

    server.addEventListener("error", () => {
      writer.close().catch(() => {});
      socket.close().catch(() => {});
    });

    (async () => {
      const reader = socket.readable.getReader();
      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          server.send(value);
        }
      } catch {
        // upstream closed or errored
      } finally {
        try {
          server.close();
        } catch {}
      }
    })();

    return new Response(null, { status: 101, webSocket: client });
  },
};
