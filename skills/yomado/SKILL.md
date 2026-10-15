---
name: yomado
description: "Prepare and manage yomado virtual work screens on macOS using existing computer-use tools. Use when an agent needs to create or name a work screen, move authorized app windows into it, verify visual access, or return those windows after a task."
---

# yomado

Let the agent prepare its own work screen; the user does not need to create it manually. Manage screens with yomado's `screen` command and move windows through the installed app with the agent's existing computer-use tools. This skill supplies the workflow, not a separate screenshot/input tool.

## Before changing anything

- Confirm yomado is installed and the agent has tools for reading the actual native UI, screenshots and input. Use the available tool's documentation for its calls; do not invent an API. If the app is missing, use the official [download](https://yomado.app/) within the user's installation authority.
- Check that the capture tool supports selecting a non-primary display or its target window before creating a screen or moving apps. If it is known to capture only the primary display, stop before moving windows; a new screen will not fix that limitation.
- The macOS desktop must be logged in and unlocked. The user handles first-time macOS permission grants and any authentication. yomado needs window-control permission; the agent's tools need their own capture/input permissions.
- Identify the task's apps and windows from the user's request. Inspect the current screen layout, physical main display, virtual display names/IDs, bounds and scale, plus the original bounds of the windows that may move. Keep this recovery record local; do not publish window titles, screenshots or machine identifiers.
- Reuse a suitable screen belonging to this task when possible. A familiar name does not prove ownership: do not reuse, rename or close another task's screen without authority. Coordinate with any existing desktop owner before GUI operations.
- Virtual screens share the login session, focus, keyboard and pointer. They do not provide independent agent input. When uninterrupted personal computer use is required, establish that the actual tool supports the needed non-interference before input; otherwise stop and explain the limitation.

## Prepare the screen

Run screen management through the app binary. It never opens the panel, and every reply that reaches yomado is one JSON object on stdout (usage errors and an unreachable yomado print an `error:` line on stderr):

```sh
Y=/Applications/Yomado.app/Contents/MacOS/Yomado
$Y screen list
```

1. Run `$Y screen list`. It starts yomado in the background when it is not running. Each screen has an `id`, `name`, `title`, `running`, size and HiDPI setting; running screens also report `displayID` and `verified`.
2. If a suitable task-owned screen is saved but closed, `$Y screen start SCREEN`. Otherwise `$Y screen create --name "Codex · Blender"` (add `--size 2560x1440` or `--hidpi` when needed). `SCREEN` is an id, a name or a full title. Both commands return after display verification; a non-zero exit carries the reason in `error`.
3. To rename an existing screen, `$Y screen rename SCREEN NEW_NAME`. A renamed running screen keeps its old macOS display name until it is started again (`systemNameUpdatesOnNextStart`); do not restart merely to synchronize the name.
4. Record the screen's `displayID`, and its bounds and scale from the display inventory.
5. Compare the display arrangement and main display with the checkpoint before moving apps. Adding or removing displays can rearrange the desktop in released versions. If an existing screen moved, stop and report the discrepancy; do not continue moving user windows or silently change the main display. Resolve layout only within the user's authority.

Keep physical outputs enabled and a physical display as main during ordinary setup. Do not change power, lock, login or display settings just because the task needs a work screen. `$Y screen configure SCREEN --size … --hidpi|--no-hidpi` applies only to a closed screen; do not close an occupied screen to change it.

## Move only the task's windows

Choose the narrowest supported operation after inspecting its scope:

| Control | Windows it selects |
| --- | --- |
| Drag an app icon from one screen tile to another | That app's ordinary windows on the source screen |
| Target screen **+** → `App · 实体屏` | That app's ordinary windows across **all physical screens** |
| Target screen **+** → `App · <virtual screen>` | That app's ordinary windows on the named virtual source |
| Drop a running `.app` bundle from Finder | That app's ordinary windows across screens |

An icon is an app/window group, not a single-window or process selector. If the selected group includes personal or other-task windows, do not use that group operation. Use a verified per-window move supported by the existing computer-use tool, if available and authorized; otherwise obtain a narrower selection from the user. Do not collect all windows to make capture easier.

Drag into the target screen tile, or use its **+** chooser only when the chooser's full scope is authorized. Check fresh window bounds and the screen's app inventory after the move. An icon/count describes detected visible windows, not GPU activity or proof of agent access. Some apps refuse Accessibility positioning.

If the header shows a lock icon, window movement needs permission. The icon opens the relevant macOS settings page; let the user grant access. Opening settings is not authorization. Do not reset permissions or keep retrying the same failed move.

## Verify before working

1. Select the actual target display/window in the agent's capture tool. Acquire a fresh target-app screenshot and current window bounds, pixel dimensions and scale; discard pre-move coordinates. A correct, fresh target screenshot is required before any test input.
2. Perform one authorized, reversible operation in the real target app, such as opening and dismissing a menu or changing and restoring a view. Confirm the change in a new screenshot before claiming visual operation works.
3. If targeting fails only after the move, stop input and safely return only this task's moved windows using their checkpoint. If recovery cannot be verified, leave the screen running and report the pending recovery. Do not make the virtual screen primary or move unrelated windows as a workaround.
4. Stop on blank/stale capture, wrong-window input, unexpected layout changes, login/security prompts or rejected movement. Use the same scoped recovery path for failed capture/input. On a login/security prompt, return only the moved app's windows to their recorded physical display if safe, then let the user handle the prompt. Do not repeatedly attempt login or dismiss security checks.

Screen creation, an accessibility tree, a running process or a synthetic preview is not evidence of target-app visual input. Keep claims specific to the app and operation actually observed. This skill does not establish locked-session operation or input isolation.

## Return windows and finish

- Save task work as authorized before recovery. Return only the windows moved for this task. Inspect scope again if new windows appeared during the task.
- For a yomado-managed app, its icon on a virtual screen offers a return menu (right-click, or focus and press Space/Return where supported). Opening that menu does not itself restore the app. Select `返回原显示器`; without a stored checkpoint the label is `移回实体屏`.
- Ordinary app checkpoints are held in memory for the current yomado run and survive transfers between virtual screens. Returning to the recorded original physical screen restores its placement. A different destination, or no checkpoint, centers windows instead; use the private pre-move record to verify/recover exact placement when supported. Do not promise exact restoration without evidence.
- WeChat has additional recovery behavior: a pending checkpoint takes priority and returns to its original physical display. Return it there before a further virtual-screen transfer. Restoring its window cannot restore an expired login.
- Confirm restored bounds. Close a task-created screen only after its work is saved, its windows are accounted for, and no other task needs it. Use `$Y screen close SCREEN`; never quit yomado to close one screen. `close` first returns the screen's yomado-managed windows; when it cannot (for example, Accessibility permission is missing while windows remain), it exits non-zero and keeps the screen. Verify the remaining layout afterwards, and report a refused or uncertain recovery instead of retrying. `$Y screen delete SCREEN` removes a closed screen's saved profile when it is no longer wanted.
- Report the screen used, apps moved, screenshot/input checks actually completed, and whether the screen remains available or was closed. State any unresolved recovery or targeting limitation.

## Command-line boundary

`Yomado screen list|create|start|close|rename|configure|delete` manages screens; `Yomado screen help` prints its usage. Exit status is 0 on success, 1 when yomado refuses or the operation fails, 2 on a usage error, and 3 when yomado cannot be reached. Window movement has no command; use the app's UI as described above.

`--diagnose` prints local capability/display diagnostics; do not add `--include-device-identifiers` to shared diagnostics. `--preview-ui` renders sample data, while `--self-test` and `--watchdog-test` are developer tests that can change displays; none is a work-screen setup command. Do not probe other arguments: unknown arguments open the normal app UI.
