// SPDX-License-Identifier: MPL-2.0

/** EmberPDF isolated JavaScript SDK v1.
 * This file describes the host API; it does not grant permissions. Calls are
 * checked against the installed package's manifest and current grant at runtime.
 * There is no window/document DOM, Node.js, shell, arbitrary filesystem, or direct
 * network API. Host-owned UI is described through ember.ui.render().
 */
declare namespace EmberPDF {
  type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };
  type Empty = Record<string, never>;
  type AppearanceMode = "system" | "light" | "dark";
  type PaperColor = "original" | "soft" | "sepia" | "night";

  /** Scope is this app window. IDs are opaque; no document path is exposed. */
  interface AppContext {
    apiVersion: 1;
    windowID: string;
    workspaceID: string;
    tabID: string | null;
    hasDocument: boolean;
  }

  type NativeCommand =
    | { kind: "highlight" | "underline"; color?: string; width?: number; opacity?: number }
    | { kind: "pen"; color?: string; width?: number }
    | { kind: "eraser" | "selection" | "viewerMode" | "editingMode" | "studyMode" | "nextPage" | "previousPage" };

  interface DocumentInfo {
    /** Display name only; the source path and security bookmark are never returned. */
    name: string;
    /** Page numbers use 1-based indexing. */
    pageNumber: number;
    pageCount: number;
    revision: string;
    copyAllowed: boolean;
    workspaceID?: string;
    tabID?: string;
  }

  interface TextSnapshot {
    /** At most 16,000 characters and 64 KiB UTF-8. */
    text: string;
    truncated: boolean;
    revision: string;
    pageNumber?: number;
  }

  interface OpenDocument {
    workspaceID: string;
    workspaceName: string;
    tabID: string;
    name: string;
    pageNumber: number;
    pageCount: number;
    active: boolean;
  }

  interface Appearance {
    mode: AppearanceMode;
    paper: PaperColor;
    /** Night paper currently applies a dark appearance while preserving mode. */
    effectiveMode: AppearanceMode;
  }

  interface SearchDocument {
    workspaceID: string;
    tabID: string;
    name: string;
    /** A filename-only match can have an empty matches array. */
    matches: { pageNumber: number; snippet: string }[];
  }

  interface SearchResult {
    documents: SearchDocument[];
    /** True when the document/result limit was reached or a document was skipped. */
    partial: boolean;
    scannedDocuments: number;
  }

  interface Methods {
    /** Window runtimes can call this with no open PDF and no document permission. */
    "app.getContext": { params: Empty; result: AppContext };
    /** Requires documentMetadata. */
    "document.getInfo": { params: Empty; result: DocumentInfo };
    /** Requires selectedText and PDF copying rights. Only this document's selection is accepted. */
    "document.getSelection": { params: Empty; result: TextSnapshot };
    /** Requires currentPageText OR documentTextRead for the visible page. Reading
     * any other page requires documentTextRead. PDF copying rights always apply.
     * Omitting pageNumber reads the current page; 1-based indexing, no navigation.
     */
    "document.getPageText": { params: { pageNumber?: number }; result: TextSnapshot & { pageNumber: number } };
    /** Native commands use the same mode, PDF rights and Undo boundaries as the UI.
     * highlight/underline require annotationWrite + selectedText and an owned
     * selection with PDF copying rights. pen/eraser/selection require toolControl;
     * page/mode commands require workspaceNavigation. Color is #RRGGBB, width is
     * 0.2...32, opacity is 0.1...1. Styles are accepted only by the kinds below.
     */
    "commands.execute": {
      params: NativeCommand;
      result: { executed: true; kind: NativeCommand["kind"]; revision: string; pageNumber: number };
    };
    /** Requires openDocumentsRead. Lists at most 128 already open documents without waking them. */
    "workspace.listDocuments": {
      params: Empty;
      result: { documents: OpenDocument[]; truncated: boolean };
    };
    /** Requires workspaceNavigation. IDs must belong to this window's open documents. */
    "workspace.navigate": {
      params: { workspaceID: string; tabID: string; pageNumber?: number };
      result: { workspaceID: string; tabID: string; pageNumber: number };
    };
    /** Requires openDocumentsRead. Nonempty query, at most 1,024 UTF-8 bytes.
     * Searches at most 8 open PDFs and returns at most 24 text matches, 3 per PDF.
     * Protected text requires the PDF's copying rights; scans without text need OCR.
     */
    "workspace.search": { params: { query: string }; result: SearchResult };
    /** Requires notesWrite. An attached Markdown file additionally requires fileReadWrite. */
    "notes.get": {
      params: Empty;
      result: { text: string; truncated: boolean; modified: boolean };
    };
    /** Requires notesWrite, plus fileReadWrite for an attached Markdown file.
     * Appends to the current in-memory note; never silently saves or overwrites a file.
     * The resulting note is limited to 1 MiB and NUL characters are rejected.
     */
    "notes.append": {
      params: { text: string };
      result: { modified: boolean; byteCount: number };
    };
    /** Both appearance methods require appearanceWrite. */
    "appearance.get": { params: Empty; result: Appearance };
    "appearance.set": { params: { mode?: AppearanceMode; paper?: PaperColor }; result: Appearance };
    /** Requires pluginStorage. Data is namespaced to the installed plugin, at most
     * 64 KiB when JSON-encoded. A plugin with no saved value receives null.
     */
    "storage.get": { params: Empty; result: { value: JSONValue } };
    "storage.set": { params: { value: JSONValue }; result: { saved: true } };
    /** Requires pluginStorage. Atomically writes value only if current JSON equals
     * expected; use null for an absent value. Both expected and value are limited
     * to 64 KiB each. Object key order does not matter; true and 1 are different.
     * A conflict returns {saved:false} without modifying storage. Re-read and
     * retry a bounded number of times to merge independent window updates.
     */
    "storage.compareAndSet": {
      params: { expected: JSONValue; value: JSONValue };
      result: { saved: boolean };
    };
  }

  type MethodName = keyof Methods;
  type CallArguments<M extends MethodName> = {} extends Methods[M]["params"]
    ? [params?: Methods[M]["params"]]
    : [params: Methods[M]["params"]];

  /** A complete replacement of the plugin's host-rendered panel, at most 64 KiB
   * when JSON-encoded. Text is literal; HTML, remote images, and CSS are not run.
   * At most 100 items, 12 fields, and 24 actions. Field/action IDs are unique per
   * kind, at most 80 ASCII letters/digits/periods/underscores/hyphens. Labels are
   * at most 160 characters; an initial field value is at most 4,096 UTF-8 bytes.
   */
  interface PanelDescription {
    title?: string;
    text?: string;
    items?: { title: string; detail?: string }[];
    fields?: { id: string; label: string; value?: string }[];
    actions?: { id: string; label: string }[];
  }

  interface Command {
    /** Starts with an ASCII letter; at most 80 letters/digits/periods/underscores/hyphens. */
    id: string;
    /** Nonblank, at most 120 UTF-16 code units. */
    title: string;
    run: () => void | Promise<void>;
  }

  interface EventPayloads {
    /** Legacy schema-5 panel initialization. Schema-6 runtimes receive app.ready. */
    load: Empty;
    "app.ready": AppContext;
    "workspace.changed": AppContext;
    "document.changed": AppContext;
    "documents.changed": AppContext;
    /** Schema-5 panels emit an empty payload; call document.getInfo for details. */
    "page.changed": AppContext | Empty;
    "selection.changed": AppContext | Empty;
    "view.action": { id: string; values: Record<string, string> };
    "view.input": { id: string; value: string };
  }

  interface API {
    readonly apiVersion: 1;
    /** Host calls reject unsupported parameters, absent/revoked grants, and stale
     * document access. Native document/notes/appearance API parameters are at most
     * 64 KiB JSON. Keep requests sequential: the host caps 16 in-flight requests and
     * 240 requests per minute, including UI updates and command-list publication.
     */
    call<M extends MethodName>(method: M, ...args: CallArguments<M>): Promise<Methods[M]["result"]>;
    /** Returns an idempotent disposer; at most 32 registered handlers.
     * Schema-6 runtime activation follows the app window. Closing its panel or
     * changing tabs/workspaces does not end its commands or event subscriptions.
     * Schema-5 scriptPanel actions retain their panel/document-bound lifetime.
     * Disabling, revoking required permissions, closing the window, or a runtime
     * failure stops the extension and removes all host-owned contributions.
     */
    on<E extends keyof EventPayloads>(event: E, callback: (payload: EventPayloads[E]) => void | Promise<void>): () => void;
    /** Best-effort synchronous cleanup when the host deactivates the extension.
     * Returns an unregister function; at most 32 callbacks. Crashes or enforced
     * termination can skip callbacks, and native API calls are unavailable during
     * disposal. Persist meaningful state during normal operation instead.
     */
    dispose(callback: () => void): () => void;
    ui: {
      /** Updates panel content without requiring that the panel be visible. */
      render(description: PanelDescription): Promise<null>;
      /** Schema-6 runtimes may show/hide their native panel while staying active. */
      open(): Promise<null>;
      close(): Promise<null>;
    };
    commands: {
      /** Registers at most 24 commands for this extension. The host receives
       * only the complete list of { id, title } metadata; run callbacks stay in the
       * isolated worker. Returns a synchronous, idempotent disposer. Registration
       * and disposal coalesce into one updated-list publication per microtask.
       * This function does not await native acknowledgment. Commands appear in
       * the panel and command palette while this runtime remains active.
       */
      register(command: Command): () => void;
    };
  }
}

/** Installed on globalThis before the plugin entry point executes. */
declare const ember: EmberPDF.API;
