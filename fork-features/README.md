# Fork features

Customizations this fork carries on top of `chekusu/yomado`. Each feature lists where it touches upstream files so a rebase can re-check them.

## control: `Yomado screen …`

Manages named virtual screens from the command line: `list`, `create`, `start`, `close`, `rename`, `configure`, `delete`. User-facing behaviour is documented in the main README under "Control screens from the command line".

Why it lives in the app binary: a virtual display belongs to the process that created it, so screens can only be created and removed inside the running app. The CLI is a client that sends one JSON request over `~/Library/Application Support/dev.chekusu.yomado/control.sock` (mode 0600, directory 0700) and prints the JSON reply.

```mermaid
sequenceDiagram
    participant CLI as Yomado screen … (client process)
    participant Sock as control.sock
    participant App as running Yomado (main queue)
    CLI->>Sock: connect (if absent and app not running: open -g -j --args --background)
    CLI->>App: {"command":"start","screen":"Agent"}
    App->>App: create:/stop: (same path as the menu), poll displayOperationInProgress
    App-->>CLI: {"ok":true,"screen":{…}} or {"ok":false,"error":…}
```

Files:

- `fork-features/control/YMControl.{h,m}`: request type and validation, socket server, CLI client, and `YMControlSend` (also used by the agent helper).
- `app/Yomado.m`, marked `fork:`:
  - imports `YMControl.h`;
  - adds the `controlServer` and `controlRequestActive` properties;
  - `applicationDidFinishLaunching:` starts the server and skips `showWindow:` under `--background`;
  - `reportTopologyError:` and `reportApplicationError:` show no alert while a CLI request is active, and the reply carries their text instead;
  - `addDisplay:` now shares `appendProfileNamed:width:hiDPI:` with `screen create`;
  - `applicationWillTerminate:` closes the socket;
  - the `ADController (YMControl)` category at the end of the file implements the request handler;
  - `main()` routes `screen` to the client.
- `build.sh` and `scripts/test-controller-safety.sh`: add the include path and `YMControl.m`.
- Docs: `README.md`, `README.zh-CN.md`, `skills/yomado/SKILL.md`.

Rebase check: if upstream adds its own scripting or control interface, migrate to it and drop this feature. Otherwise re-verify on the installed build that `screen create/start/close` change `aerospace list-monitors` (or System Settings → Displays) without showing the panel, and that `close` refuses with a reason while a window remains on the screen and Accessibility permission is off.

## agent: agent sessions (`Yomado agent`, code-mode clients)

Lets an AI agent operate apps on a yomado screen without the user's pointer, focus or front app, from a REPL or from omp `eval` code. The design, protocol and clients are in [agent/README.md](agent/README.md) and its appendices.

Files:

- `fork-features/agent/YomadoAgent.m` and `Info.plist`: the helper, built as the nested bundle `Contents/Helpers/YomadoAgent.app`.
- `fork-features/agent/YMAgentClient.{h,m}`, `YMAgentPaths.h`: the `Yomado agent` REPL and shared paths.
- `fork-features/agent/client/yomado.{ts,py}`: code-mode clients, installed in `Contents/Resources/agent/`.
- `app/Yomado.m`, marked `fork:`: imports `YMAgentClient.h`; `main()` routes `agent` to the REPL.
- `build.sh`: builds and signs the helper bundle, copies the clients; `scripts/test-controller-safety.sh`: include path and `YMAgentClient.m`.

Rebase check: re-verify on the installed build that a code-mode session launches an app onto the agent screen, that a background click reaches a SwiftUI control (Calculator keypad), and that the user's front app and AeroSpace focus are unchanged; this relies on the private `CGEventSetWindowLocation` and `_AXUIElementGetWindow`.
