# Reading Lab

This is an executable schema 5 community SDK example. Its page analysis is implemented entirely in `main.js`, not in the host application.

It demonstrates commands, page events, native custom views, namespaced JSON settings and notes. It only reads the current page. It has no filesystem, network, shell or clipboard API. It runs while its panel is visible; switching to another script stops it. Saving to a note edits the local draft and does not save an external Markdown file.

See `Documentation/PluginSDK/emberpdf.d.ts` and `Documentation/PLUGIN-HOST-API.md`. After changing main.js, recompute SHA-256 into the action scriptSHA256 and install the package again through review.

License: MIT.
