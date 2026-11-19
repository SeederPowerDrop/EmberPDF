// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import JavaScriptCore

// This executable is a disposable computation process, not the application.
// It exposes no ObjC objects, paths, Foundation APIs, filesystem or networking
// functions to JavaScript. The parent owns authorization and a hard watchdog.
private let maximumLineBytes = 256 * 1_024
private let maximumMessagesPerDispatch = 64

private func output(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          data.count <= maximumLineBytes else { exit(70) }
    var line = data
    line.append(10)
    do { try FileHandle.standardOutput.write(contentsOf: line) }
    catch { exit(74) }
}

private func fail(_ message: String, code: Int32 = 65) -> Never {
    output(["type": "error", "message": String(message.prefix(2_048))])
    exit(code)
}

/// Reads bounded chunks without readLine(), which could allocate an arbitrary
/// amount before finding a newline in malformed parent input.
private struct InputLines {
    private var pending = Data()
    private var eof = false

    mutating func next() -> Data? {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard line.count <= maximumLineBytes else { fail("Input exceeds the message limit") }
                return line
            }
            guard pending.count <= maximumLineBytes else { fail("Input exceeds the message limit") }
            if eof {
                guard pending.isEmpty else { fail("Input ended before a complete message") }
                return nil
            }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { fail("Input cannot be read", code: 74) }
            if count == 0 { eof = true }
            else { pending.append(contentsOf: bytes.prefix(count)) }
        }
    }
}

private func boundedJSON(_ value: Any, depth: Int = 0) -> Bool {
    guard depth <= 24 else { return false }
    if let object = value as? [String: Any] {
        return object.count <= 128 && object.allSatisfy {
            $0.key.utf8.count <= 256 && boundedJSON($0.value, depth: depth + 1)
        }
    }
    if let array = value as? [Any] {
        return array.count <= 1_024 && array.allSatisfy { boundedJSON($0, depth: depth + 1) }
    }
    if let text = value as? String { return text.utf8.count <= maximumLineBytes }
    if let number = value as? NSNumber { return number.doubleValue.isFinite }
    return value is NSNull
}

private let bootstrap = #"""
(() => {
  'use strict';
  const nativePost = globalThis.__post;
  delete globalThis.__post;
  const stringify = JSON.stringify.bind(JSON);
  const parse = JSON.parse.bind(JSON);
  const NativePromise = Promise;
  const resolvePromise = Promise.resolve.bind(Promise);
  const then = Function.prototype.call.bind(Promise.prototype.then);
  const handlers = new Map();
  const commands = new Map();
  const pending = new Map();
  const cleanups = new Set();
  let extensionDisposed = false;
  let sequence = 0;
  let handlerCount = 0;
  let commandsPublicationQueued = false;
  const validID = value => typeof value === 'string' && /^[a-zA-Z][a-zA-Z0-9._-]{0,79}$/.test(value);
  const validEventName = value => typeof value === 'string' && /^[a-zA-Z][a-zA-Z0-9._:-]{0,95}$/.test(value);
  const call = (method, params = {}) => new NativePromise((resolve, reject) => {
    try {
      if (extensionDisposed) throw new Error('Extension is inactive');
      if (!validID(method)) throw new Error('Invalid API method');
      if (!params || typeof params !== 'object' || Array.isArray(params)) throw new Error('Parameters must be an object');
      if (pending.size >= 32) throw new Error('Too many outstanding requests');
      const id = String(++sequence);
      if (!Number.isSafeInteger(sequence)) throw new Error('Request limit reached');
      const encoded = stringify({type: 'request', id, method, params});
      if (encoded.length > 262144) throw new Error('Request exceeds the message limit');
      pending.set(id, {resolve, reject});
      try { nativePost(encoded); } catch (error) { pending.delete(id); throw error; }
    } catch (error) { reject(error); }
  });
  const publishCommands = () => call('ui.commands', {commands: Array.from(commands, ([id, item]) => ({id, title: item.title}))});
  const observe = result => then(resolvePromise(result), undefined, error => {
    // A normal document switch invalidates outstanding reads without disabling
    // the extension. Other callback failures remain visible to the host.
    if (extensionDisposed || error?.code === 'CONTEXT_CHANGED') return;
    call('runtime.error', {message: String(error?.message || error || 'Plugin callback failed').slice(0, 512)});
  });
  const scheduleCommandsPublication = () => {
    if (commandsPublicationQueued) return;
    commandsPublicationQueued = true;
    // Registering a complete command set is one metadata update, not one RPC
    // per command. This stays within the parent's concurrent-request budget.
    observe(then(resolvePromise(), () => {
      commandsPublicationQueued = false;
      return publishCommands();
    }));
  };
  const ember = Object.freeze({
    apiVersion: 1,
    call,
    dispose(callback) {
      if (extensionDisposed || typeof callback !== 'function' || cleanups.size >= 32) throw new Error('Invalid or excessive cleanup');
      cleanups.add(callback);
      return () => cleanups.delete(callback);
    },
    on(name, handler) {
      if (extensionDisposed || !validEventName(name) || typeof handler !== 'function') throw new Error('Invalid event handler');
      if (handlerCount >= 32) throw new Error('Too many event handlers');
      if (!handlers.has(name)) handlers.set(name, new Set());
      const entries = handlers.get(name);
      if (!entries.has(handler)) { entries.add(handler); handlerCount++; }
      let disposed = false;
      return () => {
        if (disposed) return;
        disposed = true;
        if (entries.delete(handler)) handlerCount--;
        if (!entries.size) handlers.delete(name);
      };
    },
    ui: Object.freeze({
      render: view => call('ui.render', {view}),
      open: () => call('ui.open'),
      close: () => call('ui.close')
    }),
    commands: Object.freeze({
      register(command) {
        if (!command || !validID(command.id) || command.id.length > 80 || typeof command.title !== 'string' ||
            !command.title.trim() || command.title.length > 120 || typeof command.run !== 'function')
          throw new Error('Invalid command');
        if (commands.has(command.id) || commands.size >= 24) throw new Error('Duplicate or excessive command');
        commands.set(command.id, {title: command.title, run: command.run});
        scheduleCommandsPublication();
        let disposed = false;
        return () => {
          if (disposed) return;
          disposed = true;
          commands.delete(command.id);
          scheduleCommandsPublication();
        };
      }
    })
  });
  Object.defineProperty(globalThis, 'ember', {value: ember, writable: false, configurable: false});
  // Swift retains this function then removes its global name. Untrusted code
  // cannot replace dispatch or obtain the private native output function.
  globalThis.__dispatch = encoded => {
    const message = parse(encoded);
    if (message.type === 'response') {
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      if (message.error != null) {
        const error = new Error(String(message.error).slice(0, 2048));
        if (message.errorCode === 'CONTEXT_CHANGED') error.code = 'CONTEXT_CHANGED';
        request.reject(error);
      }
      else request.resolve(message.result);
    } else if (message.type === 'event') {
      for (const handler of Array.from(handlers.get(message.name) || [])) observe(handler(message.payload));
    } else if (message.type === 'command') {
      const command = commands.get(message.id);
      if (command) observe(command.run());
    } else if (message.type === 'deactivate') {
      extensionDisposed = true;
      for (const cleanup of Array.from(cleanups)) {
        try { observe(cleanup()); } catch (_) { /* Authoritative host cleanup follows. */ }
      }
      cleanups.clear(); handlers.clear(); commands.clear();
      for (const request of pending.values()) request.reject(new Error('Extension is inactive'));
      pending.clear();
    }
  };
})();
"""#

private final class Worker {
    private let context: JSContext
    private var dispatch: JSValue!
    private var loaded = false
    private var emittedMessages = 0
    private var sawException = false

    init() {
        guard let context = JSContext() else { fail("JavaScript runtime is unavailable", code: 70) }
        self.context = context
        context.exceptionHandler = { [weak self] _, exception in
            self?.sawException = true
            output(["type": "error", "message": String((exception?.toString() ?? "JavaScript failed").prefix(2_048))])
        }
        let post: @convention(block) (String) -> Void = { [weak self] encoded in
            guard let self else { return }
            guard encoded.utf8.count <= maximumLineBytes,
                  let data = encoded.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let object = value as? [String: Any],
                  Set(object.keys) == ["type", "id", "method", "params"],
                  object["type"] as? String == "request",
                  let id = object["id"] as? String, (1...64).contains(id.utf8.count),
                  id.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let method = object["method"] as? String, (1...80).contains(method.utf8.count),
                  method.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }),
                  object["params"] is [String: Any], boundedJSON(object),
                  self.emittedMessages < maximumMessagesPerDispatch else {
                self.context.exception = JSValue(newErrorFromMessage: "Invalid or excessive host request", in: self.context)
                return
            }
            self.emittedMessages += 1
            output(object)
        }
        context.setObject(post, forKeyedSubscript: "__post" as NSString)
        context.evaluateScript(bootstrap)
        guard !sawException, let value = context.objectForKeyedSubscript("__dispatch"), !value.isUndefined else {
            fail("JavaScript bootstrap failed", code: 70)
        }
        dispatch = value
        context.evaluateScript("delete globalThis.__dispatch;")
    }

    func accept(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              boundedJSON(object), let type = object["type"] as? String else { fail("Invalid protocol message") }
        emittedMessages = 0
        sawException = false
        switch type {
        case "load":
            guard !loaded, Set(object.keys) == ["type", "source"], let source = object["source"] as? String,
                  source.utf8.count <= maximumLineBytes else { fail("Invalid or repeated source load") }
            loaded = true
            context.evaluateScript("(function(ember) { 'use strict';\n" + source + "\n})(globalThis.ember);")
        case "response":
            guard loaded, Set(object.keys).isSubset(of: ["type", "id", "result", "error", "errorCode"]),
                  let id = object["id"] as? String, (1...64).contains(id.utf8.count) else { fail("Invalid host response") }
            _ = dispatch.call(withArguments: [String(decoding: data, as: UTF8.self)])
        case "event":
            guard loaded, Set(object.keys).isSubset(of: ["type", "name", "payload"]),
                  let name = object["name"] as? String, (1...96).contains(name.utf8.count) else { fail("Invalid host event") }
            _ = dispatch.call(withArguments: [String(decoding: data, as: UTF8.self)])
        case "command":
            guard loaded, Set(object.keys) == ["type", "id"],
                  let id = object["id"] as? String, (1...96).contains(id.utf8.count) else { fail("Invalid host command") }
            _ = dispatch.call(withArguments: [String(decoding: data, as: UTF8.self)])
        case "deactivate":
            guard loaded, Set(object.keys) == ["type"] else { fail("Invalid deactivation") }
            _ = dispatch.call(withArguments: [String(decoding: data, as: UTF8.self)])
        default:
            fail("Unknown protocol message")
        }
        // This is written by native code only, after JavaScript and its jobs
        // return. A JS infinite loop cannot forge an idle to reset the parent
        // deadline. The helper intentionally has no native timers/run loop.
        output(["type": "idle"])
    }
}

// Never create a core dump containing captured PDF text. CPU and memory are
// primarily enforced by the parent watchdog; macOS has no reliable per-JSC
// heap hard limit exposed by this API, so this helper does not claim one.
var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
_ = setrlimit(RLIMIT_CORE, &coreLimit)
// A unique exact native role branches before any JavaScript context exists.
if CommandLine.arguments.dropFirst().contains("--tag-read-auxiliary") {
    exit(TagReadAuxiliaryRole.run(arguments: Array(CommandLine.arguments.dropFirst())))
}
signal(SIGPIPE, SIG_IGN)
private let worker = Worker()
private var input = InputLines()
while let line = input.next() { autoreleasepool { worker.accept(line) } }
