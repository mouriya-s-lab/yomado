// yomado agent session client for Bun (omp eval code mode).
// Protocol and operations: fork-features/agent/README.md, operations.md.
//   const { connect } = await import("/Applications/Yomado.app/Contents/Resources/agent/yomado.ts");
//   globalThis.ym = await connect({ screen: "Agent" });
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Socket } from "bun";

export type Bounds = { x: number; y: number; width: number; height: number };
export type Window = { id: number; pid: number; app: string; bundleId: string; title: string; bounds: Bounds };
export type Pointer = { window: number; x: number; y: number };
export type Point = { x: number; y: number };
export type Screen = { id: number; title: string; displayID: number; bounds: Bounds; workspace: string | null };
export type Element = {
  ref: string; role: string; title: string; description: string; value: string;
  actions: string[]; settable: boolean; x: number; y: number; width: number; height: number;
};
export type Capture = { path: string; pixels: { width: number; height: number }; scale: number; bounds: Bounds };
export type Status = {
  version: string; pid: number; aerospace: boolean; sessions: number;
  grants: { accessibility: boolean; screenRecording: boolean };
};
export type SessionEvent =
  | { type: "focus_restored"; pid: number; app: string; restoredPid: number; restoredApp: string }
  | { type: "window_adopted"; window: Window }
  | { type: "window_closed"; window: number };

export type ErrorCode =
  | "usage" | "not_open" | "no_screen" | "no_window" | "not_owned" | "app_running" | "launch_failed"
  | "ax_failed" | "stale_ref" | "capture_failed" | "focus_stolen" | "permission" | "timeout" | "yomado_unreachable";

export class SessionError extends Error {
  constructor(readonly code: ErrorCode, message: string) {
    super(`${code}: ${message}`);
    this.name = "SessionError";
  }
}

type Reply =
  | { id: number; ok: true; result: unknown; events: SessionEvent[] }
  | { id: number; ok: false; error: { code: ErrorCode; message: string }; events: SessionEvent[] };

const SOCKET = join(homedir(), "Library/Application Support/dev.chekusu.yomado/agent.sock");
// This file is installed in Yomado.app/Contents/Resources/agent/; the helper is the nested
// bundle Contents/Helpers/YomadoAgent.app.
const HELPER = join(import.meta.dir, "../../Helpers/YomadoAgent.app/Contents/MacOS/YomadoAgent");
const LOG = join(homedir(), "Library/Logs/yomado-agent.log");

export class Session {
  #socket: Socket<undefined>;
  #buffer = "";
  #nextId = 0;
  #waiting = new Map<number, { resolve: (reply: Reply) => void; reject: (error: Error) => void }>();
  #events: SessionEvent[] = [];
  #closed = false;
  screen!: Screen;
  session!: number;

  private constructor(socket: Socket<undefined>) {
    this.#socket = socket;
  }

  static async connect(screen: string): Promise<Session> {
    let socket = await tryConnect();
    if (!socket) {
      if (!existsSync(HELPER)) throw new SessionError("yomado_unreachable", `helper not found at ${HELPER}`);
      Bun.spawn([HELPER], { stdin: "ignore", stdout: Bun.file(LOG), stderr: Bun.file(LOG), detached: true }).unref();
      for (let attempt = 0; attempt < 50 && !socket; attempt++) {
        await Bun.sleep(100);
        socket = await tryConnect();
      }
      if (!socket) throw new SessionError("yomado_unreachable", `the helper did not open ${SOCKET} within 5 s; see ${LOG}`);
    }
    const session = new Session(socket.socket);
    socket.attach(session);
    const opened = (await session.request("open", { screen })) as { session: number; screen: Screen };
    session.session = opened.session;
    session.screen = opened.screen;
    return session;
  }

  /** Feeds bytes from the socket; resolves waiting requests in order. */
  receive(text: string): void {
    this.#buffer += text;
    for (let newline = this.#buffer.indexOf("\n"); newline >= 0; newline = this.#buffer.indexOf("\n")) {
      const reply = JSON.parse(this.#buffer.slice(0, newline)) as Reply;
      this.#buffer = this.#buffer.slice(newline + 1);
      this.#waiting.get(reply.id)?.resolve(reply);
      this.#waiting.delete(reply.id);
    }
  }

  ended(): void {
    this.#closed = true;
    for (const { reject } of this.#waiting.values()) reject(new SessionError("yomado_unreachable", "the helper closed the session"));
    this.#waiting.clear();
  }

  async request(op: string, args: Record<string, unknown> = {}): Promise<unknown> {
    if (this.#closed) throw new SessionError("yomado_unreachable", "the session is closed");
    const id = ++this.#nextId;
    const reply = await new Promise<Reply>((resolve, reject) => {
      this.#waiting.set(id, { resolve, reject });
      this.#socket.write(`${JSON.stringify({ ...args, id, op })}\n`);
    });
    this.#events.push(...reply.events);
    if (!reply.ok) throw new SessionError(reply.error.code, reply.error.message);
    return reply.result;
  }

  /** Returns and clears the events received so far. */
  drainEvents(): SessionEvent[] {
    return this.#events.splice(0);
  }

  status() { return this.request("status") as Promise<Status>; }
  windows() { return this.request("windows") as Promise<{ windows: Window[] }>; }
  /** `windows` may be empty: a document app launched in the background can open none until asked (`key({app: pid}, ["cmd+n"])`). */
  launch(app: string) { return this.request("launch", { app }) as Promise<{ windows: Window[]; pid: number; bundleId: string }>; }
  adopt(window: number) { return this.request("adopt", { window }) as Promise<{ window: Window }>; }
  capture(options: { window?: number; path?: string; pointer?: boolean } = {}) {
    return this.request("capture", options) as Promise<Capture>;
  }
  ax(window: number) { return this.request("ax", { window }) as Promise<{ elements: Element[] }>; }
  press(ref: string, action?: string) { return this.request("press", { ref, ...(action ? { action } : {}) }) as Promise<{}>; }
  set(ref: string, value: string) { return this.request("set", { ref, value }) as Promise<{}>; }
  move(window: number, x: number, y: number) { return this.request("move", { window, x, y }) as Promise<{ pointer: Pointer }>; }
  click(window: number, x?: number, y?: number, options: { button?: "left" | "right"; count?: 1 | 2 | 3 } = {}) {
    return this.request("click", { window, ...(x === undefined ? {} : { x, y }), ...options }) as Promise<{ pointer: Pointer }>;
  }
  drag(window: number, to: Point, options: { from?: Point; steps?: number } = {}) {
    return this.request("drag", { window, to, ...options }) as Promise<{ pointer: Pointer }>;
  }
  scroll(window: number, dy: number, options: { dx?: number; x?: number; y?: number } = {}) {
    return this.request("scroll", { window, dy, ...options }) as Promise<{ pointer: Pointer }>;
  }
  type(window: number, text: string) { return this.request("type", { window, text }) as Promise<{ typed: number }>; }
  /** Keys to an owned window; with `{app}` (pid or bundle id), only menu shortcuts such as `cmd+n`. */
  key(target: number | { app: number | string }, keys: string[]) {
    return this.request("key", { ...(typeof target === "number" ? { window: target } : target), keys }) as Promise<{
      keys: { key: string; via: "menu" | "menu_disabled" | "event"; menu?: string }[];
    }>;
  }
  handoff(windows: number[]) {
    return this.request("handoff", { windows }) as Promise<{ target: { workspace: string } | { display: number }; windows: Window[] }>;
  }
  quit(app: number | string) { return this.request("quit", { app }) as Promise<{}>; }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#socket.end();
  }
}

type Pending = { socket: Socket<undefined>; attach(session: Session): void };

async function tryConnect(): Promise<Pending | null> {
  let target: Session | null = null;
  const early: string[] = [];
  try {
    const socket = await Bun.connect({
      unix: SOCKET,
      socket: {
        data(_socket, data) {
          const text = data.toString();
          if (target) target.receive(text);
          else early.push(text);
        },
        close() { target?.ended(); },
        error() { target?.ended(); },
      },
    });
    return {
      socket,
      attach(session) {
        target = session;
        for (const text of early.splice(0)) session.receive(text);
      },
    };
  } catch {
    return null;
  }
}

/** Opens a session on the named yomado screen (started or created if needed). Keep it in a global across eval cells. */
export function connect(options: { screen?: string } = {}): Promise<Session> {
  return Session.connect(options.screen ?? "Agent");
}
