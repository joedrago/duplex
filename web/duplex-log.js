// Mirrors browser console output to the duplex server when --js-logs is on.
// Loaded as a classic (non-module) script BEFORE hls.min.js and app.js so the
// console patches are installed before any other code runs — that way we also
// capture hls.js's own logs and any error thrown during its initialization.
//
// When window.__DUPLEX_CONFIG__.jsLogs is false (or the global is missing),
// this script no-ops and adds zero runtime overhead.
;(function () {
    var cfg = window.__DUPLEX_CONFIG__
    if (!cfg || !cfg.jsLogs) return

    var ENDPOINT = "/_debug/log"
    var FLUSH_MS = 30
    var MAX_MSG_BYTES = 16 * 1024
    var TRUNC_SUFFIX = " …[truncated]"

    // Keep originals before we patch — call these from inside the wrappers so
    // (a) the dev-tools console still gets the message, and (b) any console
    // calls made by fetch internals don't infinite-loop through the shim.
    var origLog = console.log.bind(console)
    var origInfo = console.info.bind(console)
    var origWarn = console.warn.bind(console)
    var origError = console.error.bind(console)

    var queue = []
    var flushTimer = null

    function safeStringify(v) {
        var seen = new WeakSet()
        try {
            return JSON.stringify(v, function (_k, val) {
                if (typeof val === "bigint") return val.toString() + "n"
                if (typeof val === "function") return "[Function " + (val.name || "anonymous") + "]"
                if (val instanceof Error) return val.stack || val.message || String(val)
                if (typeof val === "object" && val !== null) {
                    if (seen.has(val)) return "[Circular]"
                    seen.add(val)
                }
                return val
            })
        } catch (_) {
            try {
                return String(v)
            } catch (_) {
                return "[unstringifiable]"
            }
        }
    }

    function serializeArg(a) {
        if (a === null) return "null"
        if (a === undefined) return "undefined"
        var t = typeof a
        if (t === "string") return a
        if (t === "number" || t === "boolean" || t === "bigint") return String(a)
        if (a instanceof Error) return a.stack || a.message || String(a)
        return safeStringify(a)
    }

    function serializeArgs(args) {
        var parts = new Array(args.length)
        for (var i = 0; i < args.length; i++) parts[i] = serializeArg(args[i])
        var s = parts.join(" ")
        if (s.length > MAX_MSG_BYTES) s = s.slice(0, MAX_MSG_BYTES) + TRUNC_SUFFIX
        return s
    }

    function enqueue(entry) {
        try {
            queue.push(entry)
            if (flushTimer == null) {
                flushTimer = setTimeout(flush, FLUSH_MS)
            }
        } catch (_) {
            // never let logging crash the app
        }
    }

    function flush() {
        flushTimer = null
        if (queue.length === 0) return
        var batch = queue
        queue = []
        try {
            fetch(ENDPOINT, {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify(batch),
                keepalive: true
            }).catch(function () {
                // Drop silently on network error — a failed log must never
                // produce a console.error storm.
            })
        } catch (_) {
            // ignore
        }
    }

    function flushBeacon() {
        if (queue.length === 0) return
        var batch = queue
        queue = []
        try {
            var blob = new Blob([JSON.stringify(batch)], { type: "application/json" })
            navigator.sendBeacon(ENDPOINT, blob)
        } catch (_) {
            // ignore
        }
    }

    function patch(level, orig) {
        console[level] = function () {
            try {
                orig.apply(console, arguments)
            } catch (_) {
                // never let a misbehaving devtools shim crash the app
            }
            try {
                enqueue({ level: level, ts: Date.now(), msg: serializeArgs(arguments) })
            } catch (_) {
                // logging is best-effort; drop on any serialization failure
            }
        }
    }

    patch("log", origLog)
    patch("info", origInfo)
    patch("warn", origWarn)
    patch("error", origError)

    window.addEventListener("error", function (e) {
        try {
            var msg = e.message || "error"
            var stack = (e.error && e.error.stack) || null
            if (!stack && (e.filename || e.lineno || e.colno)) {
                stack = "at " + (e.filename || "?") + ":" + (e.lineno || 0) + ":" + (e.colno || 0)
            }
            enqueue({ level: "error", ts: Date.now(), msg: msg, stack: stack || undefined })
        } catch (_) {
            // defensive: error-listener itself must never throw
        }
    })

    window.addEventListener("unhandledrejection", function (e) {
        try {
            var r = e.reason
            var msg = "unhandledrejection: " + (r instanceof Error ? r.message || String(r) : serializeArg(r))
            var stack = r && r.stack ? r.stack : undefined
            enqueue({ level: "error", ts: Date.now(), msg: msg, stack: stack })
        } catch (_) {
            // defensive: rejection-listener itself must never throw
        }
    })

    // End-of-life flushes — sendBeacon is reliable across navigation/unload
    // in a way that fetch (even with keepalive) isn't always.
    window.addEventListener("pagehide", flushBeacon)
    window.addEventListener("visibilitychange", function () {
        if (document.visibilityState === "hidden") flushBeacon()
    })
})()
