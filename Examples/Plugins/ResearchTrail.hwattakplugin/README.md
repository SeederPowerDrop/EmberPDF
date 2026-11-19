# Research Trail

A schema-6 EmberPDF extension, written entirely against the public SDK. It records
up to 50 document/page visits and provides its own “Show reading trail” command.
It continues observing navigation while its panel is closed and across tab or
workspace changes in the same app window. Opening another window creates an
independent runtime, while the plugin's approved local storage is shared.
Each history update uses atomic `storage.compareAndSet`, re-reads on conflict,
and retries at most eight times so another window's visits are not overwritten.
If contention continues, the panel offers a refresh action and displays a retry
message. Reopening the trail refreshes its shared history.

Install this package through EmberPDF's plugin manager and review its permissions.
Use the command palette to run **Show reading trail · 읽기 여정 보기**. Close its
panel, visit another PDF/page, then run the command again. It also starts safely
when no PDF is open. Disable the extension or revoke **앱을 사용하는 동안 동작**
to stop it.

The three requested permissions have distinct purposes:

- `backgroundExecution`: stay available while the app window is open.
- `documentMetadata`: read the document's display name and page number.
- `pluginStorage`: save the trail in this plugin's local storage.

The example reads no PDF text, opens no external connection, and writes no user
file. “Clear trail” removes its saved history. Its JavaScript owns the history
logic and view content; EmberPDF owns access checks, isolation and native UI.

After editing `main.js`, update `runtime.sha256` in `manifest.json` with the file's
SHA-256, then validate and reinstall the package so the changed bytes are reviewed.
