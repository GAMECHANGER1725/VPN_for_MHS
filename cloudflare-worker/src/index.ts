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
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    // Workers delivers binary WS messages as a Blob, not an ArrayBuffer --
    // Blob.arrayBuffer() is async, so writes are chained through this queue
    // to preserve arrival order (VLESS is a single ordered byte stream).
    let writeQueue: Promise<void> = Promise.resolve();
    let writer: WritableStreamDefaultWriter<Uint8Array> | null = null;
    const earlyMessages: (string | Blob | ArrayBuffer)[] = [];

    const toBytes = async (data: string | Blob | ArrayBuffer): Promise<Uint8Array> => {
      if (typeof data === "string") return new TextEncoder().encode(data);
      if (data instanceof Blob) return new Uint8Array(await data.arrayBuffer());
      return new Uint8Array(data);
    };

    const enqueueWrite = (data: string | Blob | ArrayBuffer) => {
      writeQueue = writeQueue
        .then(async () => {
          const chunk = await toBytes(data);
          await writer!.write(chunk);
        })
        .catch((err) => console.log("write failed:", err));
    };

    server.addEventListener("message", (event: MessageEvent) => {
      if (writer) {
        enqueueWrite(event.data);
      } else {
        earlyMessages.push(event.data);
      }
    });

    server.addEventListener("close", (event: CloseEvent) => {
      console.log("client WS closed:", event.code, event.reason);
      writer?.close().catch(() => {});
      socket.close().catch(() => {});
    });

    server.addEventListener("error", () => {
      writer?.close().catch(() => {});
      socket.close().catch(() => {});
    });

    server.accept();

    let socket: ReturnType<typeof connect>;
    try {
      socket = connect({ hostname: env.VM_HOST, port: Number(env.VM_PORT) });
    } catch (err) {
      console.log("connect() threw synchronously:", err);
      server.close(1011, "upstream connect failed");
      return new Response("Upstream connect failed", { status: 502 });
    }

    socket.closed.catch(() => {});

    writer = socket.writable.getWriter();
    for (const data of earlyMessages) enqueueWrite(data);
    earlyMessages.length = 0;

    // Registered with ctx.waitUntil(): without it, the Workers runtime is
    // free to tear down this detached background loop once fetch() returns
    // its Response, since nothing else references this promise.
    ctx.waitUntil(
      (async () => {
        const reader = socket.readable.getReader();
        try {
          while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            server.send(value);
          }
        } catch (err) {
          console.log("download loop error:", err);
        } finally {
          try {
            server.close();
          } catch {}
        }
      })(),
    );

    return new Response(null, { status: 101, webSocket: client });
  },
};
