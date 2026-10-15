# Session protocol operations

This appendix lists the exact shape of every operation of the session protocol defined in [README.md](README.md#session-protocol). It sets no rules of its own beyond the shapes; the rules are in the README.

Conventions:

- `Window` is `{"id": int, "pid": int, "app": string, "bundleId": string, "title": string, "bounds": {"x","y","width","height"}}`. `id` is the CGWindowID (the same number AeroSpace reports). `bounds` are global screen points.
- Points named `x`, `y` in requests and in `ax` results are **window-local points**: origin at the window's top-left corner, in points, not pixels.
- `pointer` is `{"window": int, "x": number, "y": number}`, the session's virtual pointer after the request.
- Every request also carries `"id"` and `"op"`; they are omitted below.

## Operations

| op | Arguments | Result | Errors besides `usage` |
|---|---|---|---|
| `status` | — | `{"version", "pid", "grants": {"accessibility": bool, "screenRecording": bool}, "aerospace": bool, "sessions": int}` | — |
| `open` | `screen`: string, default `"Agent"` | `{"session": int, "screen": {"id", "title", "displayID", "bounds", "workspace"}}`. `workspace` is the AeroSpace workspace visible on the screen, or `null` without AeroSpace. | `no_screen`, `yomado_unreachable`, `permission` |
| `windows` | — | `{"windows": [Window]}`: the session's owned windows | `not_open` |
| `launch` | `app`: application name, bundle id, or `.app` path | `{"windows": [Window], "pid", "bundleId"}`: the new application's windows that appeared within 5 s, now owned and placed on the screen. The application starts hidden and is unhidden after its windows are placed, so they never appear on the user's screen (README, D6). `windows` may be empty: a document app launched without activation can open no window until asked, for example with `key` `{"app": pid, "keys": ["cmd+n"]}`; the application stays hidden until then, and that `key` request places the new window before it answers. Windows the application opens later are adopted automatically. | `app_running`, `launch_failed`, `timeout` |
| `adopt` | `window`: int | `{"window": Window}` | `no_window`, `not_owned` (another session owns it) |
| `capture` | `window`: int, optional (omit for the whole screen); `path`: string, optional; `pointer`: bool, default `true` | `{"path", "pixels": {"width","height"}, "scale", "bounds"}`. `scale` is pixels per point. With `pointer`, the virtual pointer is drawn when it lies in the captured area. | `not_owned`, `capture_failed`, `permission` |
| `ax` | `window`: int | `{"elements": [{"ref", "role", "title", "description", "value", "actions": [string], "settable": bool, "x", "y", "width", "height"}]}`. Only elements that have actions or a settable value are listed; `x`/`y` is the element's top-left corner in window-local points. | `not_owned`, `ax_failed` |
| `press` | `ref`: string; `action`: string, default `"AXPress"` | `{}` | `stale_ref`, `ax_failed`, `focus_stolen` |
| `set` | `ref`: string; `value`: string | `{}` | `stale_ref`, `ax_failed`, `focus_stolen` |
| `move` | `window`, `x`, `y` | `{"pointer"}` | `not_owned` |
| `click` | `window`; `x`, `y` optional (default: the virtual pointer, which must be in `window`); `button`: `"left"` \| `"right"`, default `"left"`; `count`: 1–3, default 1 | `{"pointer"}` | `not_owned`, `usage`, `focus_stolen` |
| `drag` | `window`; `to`: `{"x","y"}`; `from`: `{"x","y"}`, default the virtual pointer; `steps`: int, default 12 | `{"pointer"}` | `not_owned`, `focus_stolen` |
| `scroll` | `window`; `dy`: int lines (positive scrolls content down); `dx`: int lines, default 0; `x`, `y` optional (default: the virtual pointer) | `{"pointer"}` | `not_owned`, `focus_stolen` |
| `type` | `window`; `text`: string | `{"typed": int}`: number of characters | `not_owned`, `focus_stolen` |
| `key` | `window`, or `app` (pid or bundle id of a session application, for menu shortcuts only); `keys`: [string], each like `return`, `cmd+a`, `shift+tab` | `{"keys": [{"key", "via", "menu"}]}`: per combination, `via` is `menu` (the menu item named `menu` was pressed), `menu_disabled` (that item stayed disabled for 0.3 s, so nothing happened), or `event` (posted as a key event) | `not_owned`, `usage`, `focus_stolen` |
| `handoff` | `windows`: [int] | `{"target": {"workspace"} or {"display"}, "windows": [Window]}`: the windows, moved to an empty hidden AeroSpace workspace on a physical monitor (or, without AeroSpace, to the main physical display) and no longer owned | `not_owned`, `no_screen` |
| `quit` | `app`: pid or bundle id of an application this session launched or adopted and has not handed off; it may have no windows left | `{}` | `not_owned`, `timeout` |

`type`, `key` and the pointer operations first make the target application treat itself as active and `window` as its key window (README, D4), without activating the application in WindowServer. A background application does not route posted key events through its menus, so a `key` combination that contains `cmd` and one character (`cmd+a`, `cmd+shift+s`) is performed by pressing the menu item with that key equivalent through Accessibility; other keys, and `cmd` combinations without a menu item, are posted as key events.

## Key names

Letters, digits, and `- = [ ] \ ; ' , . / \``; named keys `return`, `enter`, `tab`, `space`, `delete`, `forwarddelete`, `escape`, `home`, `end`, `pageup`, `pagedown`, `left`, `right`, `up`, `down`, `f1`–`f12`. Modifiers: `cmd`, `shift`, `alt` (also `option`), `ctrl` (also `control`), joined with `+`.

## Errors

| code | Trigger | What the client observes |
|---|---|---|
| `usage` | Malformed JSON, unknown `op`, missing or ill-typed argument, `click` without coordinates while the virtual pointer is in another window | No effect. |
| `not_open` | An operation other than `status` or `open` before `open` | No effect. |
| `no_screen` | `open` matched no screen and the screen could not be created; `handoff` found no target | No effect. |
| `not_owned` | The window or application is not owned by this session, or `adopt` named a window that another session owns | No effect. |
| `app_running` | `launch` named an application that is already running (it may be the user's) | No effect; use `adopt` with a window the user agreed to give. |
| `launch_failed` | LaunchServices could not open the application | No effect. |
| `ax_failed` | An accessibility call returned an error or timed out (1 s per call) | Partial effects of the call are possible. |
| `stale_ref` | The element reference is unknown or its window closed | No effect; call `ax` again. |
| `capture_failed` | ScreenCaptureKit returned no image | No file. |
| `focus_stolen` | An agent application became the front application while the request ran | The input was delivered; the user front application was restored; `error.message` names the application. |
| `permission` | The helper lacks Accessibility or Screen Recording | No effect; the agent's tool needs the grant. |
| `timeout` | A wait inside the request exceeded 15 s | The operation may have partly completed. |
| `yomado_unreachable` | `control.sock` refused the screen request | No effect. |

## Events

| type | Fields | Emitted when |
|---|---|---|
| `focus_restored` | `pid`, `app`, `restoredPid`, `restoredApp` | The focus guard undid an activation of one of this session's agent applications outside a request. |
| `window_adopted` | `window`: Window | A new window of an agent application was placed on the screen and became owned. |
| `window_closed` | `window`: int | An owned window disappeared. |
