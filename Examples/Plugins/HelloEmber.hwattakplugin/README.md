# Hello Ember

Start here to make your first independent EmberPDF extension. This small example
adds its own **Hello Ember** command, opens a native panel, and counts clicks on
**Record an idea**. All of this behavior is defined in `main.js`.

1. Use an EmberPDF build that supports schema 6 and extension API version 1.
2. In the plugin manager, choose this `.hwattakplugin` folder and review its single
   `backgroundExecution` permission. It keeps the extension available while the
   app window is open, including when the extension's panel is closed.
3. Run **Hello Ember** from the command palette or plugin menu. No PDF is needed.
4. Click **Record an idea**, close the panel, then run **Hello Ember** again.

The count stays in memory for this app window. Closing the panel preserves it;
stopping or restarting the extension, closing the window, or quitting EmberPDF
resets it. Other windows have their own counts. This example does not use saved
storage and requests no document, file, clipboard, or network access.

Copy the folder, replace its identifier, name and author, then edit `main.js`.
Whenever its bytes change, update `runtime.sha256` in `manifest.json`, validate
the package, and reinstall it so EmberPDF can review the new code.

Next, try [Research Trail](../ResearchTrail.hwattakplugin/README.md) for document
events and shared persistent storage. Both examples use the same public SDK.
