# Session clients

This appendix shows how agents reach the session protocol of [README.md](README.md#session-protocol): the code-mode libraries for omp `eval` and the line REPL. The clients add no behaviour: each call sends one request and returns its `result`.

The installed app carries the clients in `Yomado.app/Contents/Resources/agent/`:

| File | Use |
|---|---|
| `yomado.ts` | Bun / omp `eval` (JS kernel) |
| `yomado.py` | Python 3 / omp `eval` (Python kernel) |

`Yomado agent` (the app binary) is the REPL.

## Starting the helper

A client connects to `agent.sock`. If the socket is absent or refuses the connection, the client spawns `Yomado.app/Contents/Helpers/YomadoAgent.app/Contents/MacOS/YomadoAgent` as a detached child (new session, stdio to `~/Library/Logs/yomado-agent.log`) and retries for up to 5 s. Because the client spawns it, the helper runs with the agent tool's Accessibility and Screen Recording grants (README, D2).

## JS (omp eval, Bun)

```js
const { connect } = await import("/Applications/Yomado.app/Contents/Resources/agent/yomado.ts");
globalThis.ym = await connect({ screen: "Agent" });   // keep it across cells

const [calc] = (await ym.launch("Calculator")).windows;
const shot = await ym.capture({ window: calc.id });    // shot.path → read it
const { elements } = await ym.ax(calc.id);
await ym.type(calc.id, "12*3");
await ym.key(calc.id, ["return"]);
await ym.click(calc.id, 34, 211);
ym.drainEvents();                                       // events received so far
await ym.close();
```

Methods mirror the operations: `status()`, `windows()`, `launch(app)`, `adopt(window)`, `capture({window, path, pointer})`, `ax(window)`, `press(ref, action?)`, `set(ref, value)`, `move(window, x, y)`, `click(window, x?, y?, {button, count})`, `drag(window, to, {from, steps})`, `scroll(window, dy, {dx, x, y})`, `type(window, text)`, `key(window | {app}, keys)`, `handoff(windows)`, `quit(app)`, `close()`. A failed request rejects with an `Error` whose `code` is the protocol error code.

## Python (omp eval)

```python
import sys; sys.path.insert(0, "/Applications/Yomado.app/Contents/Resources/agent")
import yomado
ym = yomado.connect(screen="Agent")

calc = ym.launch("Calculator")["windows"][0]
ym.type(calc["id"], "12*3"); ym.key(calc["id"], ["return"])
print(ym.capture(window=calc["id"])["path"])
```

Same method names with keyword arguments; calls are synchronous; failures raise `yomado.SessionError` with `.code`.

## REPL

```text
$ Yomado agent --screen Agent
> launch Calculator
{"id":1,"ok":true,"result":{"windows":[{"id":6766,...}]},"events":[]}
> type 6766 12*3
> key 6766 return
> click 6766 34 211
> {"op":"capture","window":6766}
```

`Yomado agent` sends `open` first. Each later line is the operation name followed by positional arguments, or a raw JSON request. Positional forms:

| Line | Request |
|---|---|
| `launch APP…` | `launch`, app = rest of line |
| `adopt W` / `ax W` / `windows` / `status` | as named |
| `capture [W]` | `capture` |
| `press REF [ACTION]` | `press` |
| `set REF VALUE…` | `set`, value = rest of line |
| `move W X Y` | `move` |
| `click W [X Y] [right] [double\|triple]` | `click` |
| `drag W X2 Y2 [X1 Y1]` | `drag` |
| `scroll W DY [DX]` | `scroll` at the virtual pointer |
| `type W TEXT…` | `type`, text = rest of line |
| `key W COMBO…` / `key BUNDLE_ID COMBO…` | `key` to a window, or menu shortcuts to a session app |
| `handoff W…` | `handoff` |
| `quit APP` | `quit` |

Each response is printed on one line. End of input (Ctrl-D on an empty line) closes the session. On a terminal the REPL reads input itself rather than in canonical mode, so a line has no 1024-byte limit; it supports Backspace and Ctrl-U (clear line). From a pipe it reads plain lines.
