# Make your first EmberPDF extension

An EmberPDF extension can add its own commands, keep state, respond to document events, and compose a native panel. Your JavaScript defines the behavior; the app provides permission-checked APIs for documents, notes, navigation, reading colors, and storage. The examples are starting points for new workflows.

This tutorial targets **EmberPDF 0.9.0, build 27**, on **macOS 14 or later**. Use that build or a later build supporting schema 6 and API 1; the version number `0.9.0` alone does not identify the required build. You need a plain-text editor and the repository's example folder. You do not need a PDF, Node.js, or a Swift compiler for this tutorial.

[한국어](PLUGIN-DEVELOPMENT.md) · [API reference](PLUGIN-HOST-API.md) · [TypeScript types](PluginSDK/emberpdf.d.ts) · [Examples](../Examples/Plugins/README.md)

## 1. Install an example that already works

Copy the complete [HelloEmber.hwattakplugin](../Examples/Plugins/HelloEmber.hwattakplugin) folder to a place where you can edit it. Keep its contents unchanged for this first run. Run the following command from the repository root, with a destination that does not already exist. If `work/MyExtension.hwattakplugin` exists, choose a different folder name to avoid nesting one package inside another.

```sh
mkdir -p work
cp -R Examples/Plugins/HelloEmber.hwattakplugin work/MyExtension.hwattakplugin
```

`MyExtension.hwattakplugin` is a folder. `manifest.json` and `main.js` must be directly inside it, alongside the example's README and license.

1. In EmberPDF, choose **Plugins → Manage Plugins… → Install Plugin…** and select `MyExtension.hwattakplugin`.
2. Review its one permission, **Run while using the app**, then install it. This lets the extension remain available while the app window is open.
3. Return to the main EmberPDF window. Press **Shift–Command–P**, search for **Hello Ember**, and press Enter. You can also run **Hello Ember** from the **Plugins** menu.
4. In the panel, click **Record an idea**. The count changes from `0` to `1`.
5. Click **Close panel**, then run **Hello Ember** again. The count is still `1`.

The counter belongs to this window's running extension. Closing its panel preserves it; stopping/restarting the extension, closing the window, or quitting the app resets it. Another window gets its own counter. This example does not save data or read any document.

If the command is missing, check that the plugin is enabled and **Pause all plugins** is off. The command palette belongs to the main window; close or move focus away from the plugin manager first.

## 2. Understand the two working files

`manifest.json` tells EmberPDF which package it is loading, which code to run, and which permissions to review. This is the complete manifest from the example:

```json
{
  "schemaVersion": 6,
  "identifier": "org.emberpdf.examples.hello-ember",
  "displayName": "Hello Ember",
  "version": "1.0.0",
  "author": "EmberPDF SDK Examples",
  "description": "A first independent extension with its own command, panel and per-window counter. Works without an open PDF.",
  "minimumHostVersion": "0.9.0",
  "capabilities": ["backgroundExecution"],
  "actions": [],
  "runtime": {
    "apiVersion": 1,
    "entry": "main.js",
    "sha256": "4c2e55462065cbd4d5a71c1e869bd9ab5fbdfe51b1cd5361381dec50b386afc3",
    "activation": "window",
    "capabilities": ["backgroundExecution"]
  }
}
```

For your own published plugin, replace `identifier`, `displayName`, and `author`. Keep your identifier stable across updates, and do not publish under the example identifier. Renaming the folder does not change the plugin's identity.

The important fields are:

| Field | Meaning in this example |
| --- | --- |
| `schemaVersion: 6` | An extension that runs for the lifetime of an app window |
| `runtime.entry` | The JavaScript file to execute; API 1 uses `main.js` |
| `runtime.sha256` | The SHA-256 of the exact `main.js` bytes being approved |
| `activation: "window"` | Start after approval while this app window is open |
| Both `capabilities` arrays | Permissions used by the runtime; here, only `backgroundExecution` |
| `actions: []` | No declarative actions; JavaScript registers its own command |

`main.js` implements the counter and its panel. These are the exact bytes used for the manifest digest above, including the final newline:

```javascript
// SPDX-License-Identifier: MIT
let count = 0;

async function renderPanel() {
  await ember.ui.render({
    title: 'Hello Ember',
    text: `Ideas recorded in this window: ${count}`,
    actions: [
      { id: 'add-idea', label: 'Record an idea' },
      { id: 'close', label: 'Close panel' }
    ]
  });
}

ember.commands.register({
  id: 'open-hello',
  title: 'Hello Ember',
  run: async () => {
    await renderPanel();
    await ember.ui.open();
  }
});

ember.on('view.action', async ({ id }) => {
  if (id === 'add-idea') {
    count += 1;
    await renderPanel();
  } else if (id === 'close') {
    await ember.ui.close();
  }
});
```

`commands.register` adds **Hello Ember** to the window's command surfaces. `ui.render` supplies the panel's text and buttons, and `ui.open` shows it. Clicking a button emits `view.action`; its `id` selects the corresponding behavior. `ui.close` hides the panel while the JavaScript state remains alive.

The panel is native EmberPDF UI described with data. It supports text, lists, fields, and buttons; it does not run HTML or CSS. Use the [UI types](PluginSDK/emberpdf.d.ts) for accepted fields.

## 3. Change the code and install the update

Make one visible change first: change `Record an idea` to `Count an idea` in **your copied** `main.js`. Then:

1. Save `main.js` as UTF-8 plain text.
2. Calculate its new digest from the repository root:

   ```sh
   shasum -a 256 work/MyExtension.hwattakplugin/main.js
   ```

3. Copy the first 64 hexadecimal characters into `runtime.sha256` in your copied `manifest.json`. Do not include the filename.
4. Change the plugin's `version` to `1.0.1`. Keep its identifier unchanged for this update.
5. Use **Install Plugin…** again and select the same development folder. Review and approve the replacement.
6. Return to the main window and run **Hello Ember**. The renamed button should appear, and the new runtime starts with count `0`.

Editing your development folder does not update the installed copy automatically. Reinstall after every code or manifest change; do not edit the app's installed package directly. Even a whitespace or line-ending change in `main.js` requires a new digest. The digest checks that approved code has not changed; it does not verify who published it.

With this source checkout and the macOS Swift/Xcode toolchain, you can also run the optional package validator:

```sh
zsh scripts/validate_plugin.sh work/MyExtension.hwattakplugin
```

Expect `PLUGIN VALID:` and a zero exit status. The first run builds the validator's test module. This checks package structure, permissions, and hashes without installing into your user registry or executing the extension. Try the update in the app as well.

## 4. Add one document API

Now show the active PDF's name and page next to the counter. This needs the **Read document name and page information** permission (`documentMetadata`). It does not need permission to read PDF text.

In your copied manifest, change **both** the root `capabilities` and `runtime.capabilities` arrays to `["backgroundExecution", "documentMetadata"]`. With no declarative actions, these arrays contain the same permissions.

Replace the entire `renderPanel` function in `main.js` with this function. Leave the counter, command registration, and button event handler unchanged:

```javascript
async function renderPanel() {
  const context = await ember.call('app.getContext');
  let documentLabel = 'No PDF is open.';
  if (context.hasDocument) {
    try {
      const info = await ember.call('document.getInfo');
      documentLabel = `${info.name} · ${info.pageNumber}/${info.pageCount}`;
    } catch (error) {
      // The PDF may have closed between checking and reading it.
      if ((await ember.call('app.getContext')).hasDocument) throw error;
    }
  }
  await ember.ui.render({
    title: 'Hello Ember',
    text: `${documentLabel}\nIdeas recorded in this window: ${count}`,
    actions: [
      { id: 'add-idea', label: 'Count an idea' },
      { id: 'close', label: 'Close panel' }
    ]
  });
}
```

Repeat the update steps: calculate the new `main.js` digest, replace `runtime.sha256`, increment the version, and reinstall. The review now includes the new document permission. The runtime needs all its declared permissions; revoking a required permission stops it.

Run **Hello Ember** without a PDF to see `No PDF is open.` Then open a test PDF and run the command again to see its name and page. This example refreshes when the command or counter button runs. To refresh automatically as the reader moves, subscribe to document/page events as shown in [Research Trail](../Examples/Plugins/ResearchTrail.hwattakplugin/main.js).

`app.getContext` is safe to call without a PDF. Document calls refer to the active document when called. If the context changes during a request, `CONTEXT_CHANGED` tells the extension to discard that request and use the new context.

## 5. Build your own workflow

Choose an API according to the information or operation your feature needs:

| Goal | API and permission |
| --- | --- |
| Read the active document's name/page | `document.getInfo` · `documentMetadata` |
| Read selected text | `document.getSelection` · `selectedText` |
| Read the current page | `document.getPageText` · `currentPageText` or `documentTextRead` |
| Read another page without navigating | `document.getPageText({pageNumber})` · `documentTextRead` |
| List/search already open documents | `workspace.listDocuments/search` · `openDocumentsRead` |
| Navigate to an open tab/page | `workspace.navigate` · `workspaceNavigation` |
| Add a native highlight or underline | `commands.execute` · `annotationWrite` and `selectedText` |
| Append to the current note | `notes.append` · `notesWrite`; attached files also need `fileReadWrite` |
| Change reading colors | `appearance.get/set` · `appearanceWrite` |
| Keep data between runtime launches | `storage.get/set/compareAndSet` · `pluginStorage` |

Declare every permission you use in `runtime.capabilities` and the root `capabilities`. The root must equal the union of runtime and declarative-action requirements. Permission settings let users revoke individual grants. PDF copy/edit restrictions and the host's Undo/save rules still apply.

Start with these references when extending the example:

- [SDK API and UI declarations](PluginSDK/emberpdf.d.ts): exact parameters, results, and events. TypeScript is optional; if used, bundle it into one `main.js` and keep development files outside the package.
- [Host API reference](PLUGIN-HOST-API.md): permission boundaries and native operations.
- [Research Trail](../Examples/Plugins/ResearchTrail.hwattakplugin/README.md): document/page events and persistent reading history while the panel is closed. Shared storage is per plugin across windows; its bounded compare-and-set loop prevents one window overwriting another's update.
- [Compatibility](PLUGIN-COMPATIBILITY.md), [package format](PLUGINS.md), and [security](PLUGIN-SECURITY.md): versions, limits, and installation behavior.

Register event handlers at the top level or synchronously inside `load`. An asynchronous `load` does not delay `app.ready`; subscribing after an awaited call can miss the first event. `ember.dispose` is for best-effort local cleanup. Save important data during normal operation because forced termination may skip cleanup callbacks.

Extensions use isolated JavaScript workers, with at most eight across the app. They have execution, call-rate, and message-size limits. The SDK has no Node.js, DOM, direct filesystem/network, or shell access. New JavaScript logic using existing APIs ships as a plugin; a native resource not exposed by the SDK needs an [API proposal](PLUGIN-COMPATIBILITY.md).

For new independent extensions, start with schema 6. Earlier formats remain supported for these uses:

| Schema | Use |
| --- | --- |
| 1–2 | Declarative text, links, and supported host panels |
| 3 | Preset native document commands; see [Community Starter](../Examples/Plugins/CommunityStarter.hwattakplugin/README.md) |
| 4 | Additional host panels such as notes and reading colors |
| 5 | JavaScript tied to one document panel; see [Reading Lab](../Examples/Plugins/ReadingLab.hwattakplugin/README.md) |

A schema-6 package may also declare supported host actions, but it cannot contain a legacy `scriptPanel` action alongside its runtime. Historical build differences belong in the compatibility reference; test against every actual app build you claim to support.

## 6. Troubleshoot and share

| Symptom | Check |
| --- | --- |
| Installation rejects the code hash | Recalculate the digest after saving, and update `runtime.sha256` |
| Installation rejects permissions | Check both arrays, their spelling, and the required `backgroundExecution` |
| The command is missing | Focus the main window; check enabled status, permission grants, and **Pause all plugins** |
| The extension stopped | Look at its error in the **Extensions** panel; fix/reinstall it and restart. Check whether the eight-worker limit was reached |
| A document call fails | Check the permission, open document, PDF restrictions, and `CONTEXT_CHANGED` |
| The count reset | This example keeps only in-memory state; install/update/restart/window closure starts it again |
| The source change is invisible | Reinstall the copied development folder; it is separate from the installed package |

Before sharing, test installation, your command, closing/reopening the panel, permission revocation, disable/re-enable, and replacement. Test document-dependent features with harmless sample files and without an open document.

Include `manifest.json` **and** `main.js`. Keep the README and applicable license notices. Do not put project dependencies, hidden files, subdirectories, or symlinks inside the installable folder. The [format reference](PLUGINS.md) lists all allowed files and limits.

For this tutorial's folder, create and inspect a ZIP from the repository root:

```sh
cd work
zip -X -r MyExtension-1.0.1.zip MyExtension.hwattakplugin \
  -i 'MyExtension.hwattakplugin/manifest.json' \
     'MyExtension.hwattakplugin/main.js' \
     'MyExtension.hwattakplugin/README.md' \
     'MyExtension.hwattakplugin/LICENSE'
unzip -l MyExtension-1.0.1.zip
```

Use your actual version in the ZIP name. The recipient extracts it and selects the `.hwattakplugin` folder in **Install Plugin…**. Validate and try that extracted folder before publishing it.

Before your first public release, choose your own identifier, such as `dev.yourname.my-extension`, and replace the example name and author. Changing the identifier creates a separate installed plugin; keep it stable for later updates.

In the README, explain what the plugin does, its permissions, whether it saves or sends data, the exact tested app build/OS, and how to report problems. Preserve Hello Ember's MIT license notices when reusing its code. EmberPDF currently has no online marketplace, automatic plugin updates, or publisher identity verification. Never package private PDFs, personal information, or API keys.
