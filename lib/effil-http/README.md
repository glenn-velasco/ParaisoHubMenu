# effil-http

Asynchronous HTTP(S) for [MoonLoader](https://www.blast.hk/threads/19294/) scripts.
Requests run on a native OS thread via [effil](https://github.com/effil/effil); the
game thread only polls a status flag and dispatches your callback when the
response arrives.

## Why

MoonLoader runs every script on the single game thread. A plain LuaSocket /
LuaSec request blocks the calling coroutine for the entire round trip, which
freezes rendering and input while the socket waits. Moving the request onto its
own OS thread keeps the frame loop responsive; the result is handed back on the
game thread, so touching SAMP or mimgui state from the callback is safe.

`effil` is used because it runs each thread in an independent Lua VM with real
OS-level parallelism (Lua's usual coroutines cannot, and MoonLoader has no other
threading primitive).

## The two landmines

**1. effil cannot serialize upvalues.** effil ships the thread function to the
new VM with `lua_dump` and refuses any function that captures a non-primitive
upvalue. The worker is therefore stored as a plain source **string**, compiled
with `loadstring` at spawn time. The resulting function has no upvalues and
receives every input as a plain string/number argument. Results come back as
plain scalars only — never tables, which effil would otherwise convert into
`effil.table` proxies. Request and response headers cross the boundary as a
`name\tvalue\n` blob.

**2. Concurrent SSL handshakes crash the process.** Two effil threads running
LuaSec/OpenSSL at the same time cause a native access violation — this OpenSSL
build has no threading locking callbacks. The library therefore keeps a FIFO
queue and allows **exactly one worker in flight**. On timeout it never calls
`worker:cancel()` (cancelling a thread parked in a native SSL call segfaults);
instead it reports the timeout to your callback immediately but keeps the queue
slot occupied until the abandoned worker settles on its own, so a second SSL
handshake never overlaps the first.

## Install

1. Install `effil` and the `requests` library (which pulls in LuaSocket and
   LuaSec) into your MoonLoader Lua environment.
2. Copy `effil_http.lua` into `moonloader/lib/`.
3. `local http = require('effil_http')`

## Usage

```lua
local http = require('effil_http')

-- Option A: let the library run its own pump thread.
http.run()

-- Option B: pump from your own main loop instead of http.run():
-- function main()
--     while true do http.pump(); wait(50) end
-- end

http.request({ url = 'https://example.com/api' }, function(resp, err)
    if err then
        print('failed: ' .. err)
    else
        print(resp.status)   -- number
        print(resp.body)     -- string
        print(resp.headers['Content-Type'])
    end
end)
```

See `example.lua` for two GETs plus a JSON POST.

## API

### `http.request(opts, callback)`

Queue a request. Returns immediately.

| `opts` field | type | default | notes |
|--------------|------|---------|-------|
| `url`        | string | (required) | |
| `method`     | string | `'GET'` | any method the `requests` lib supports (GET/POST/PUT/DELETE/PATCH/HEAD) |
| `headers`    | table  | `{}`    | `{ ['Header-Name'] = 'value' }` |
| `body`       | string | `nil`   | request body; sent for non-empty values |
| `timeout`    | number | `30`    | seconds |

`callback(response, err)` runs on the game thread from `pump()`:
- success: `err` is `nil`, `response = { status = number, body = string, headers = table }`
- failure/timeout: `response` is `nil`, `err` is a string (`'timeout'`,
  `'transport_error'`, `'unsupported_method_...'`, ...)

### `http.pump()`

Advances the queue: polls the in-flight worker, resolves timeouts, dispatches
callbacks, and starts the next queued request. Non-blocking. Call it from the
game thread — a `lua_thread` or your `main()` loop.

### `http.run(interval)`

Convenience wrapper that spawns a `lua_thread` calling `pump()` every `interval`
milliseconds (default 50). Use it when the host script has no loop of its own.

## Limitations

- **One request in flight.** Requests are strictly sequential by design — this
  is the SSL crash workaround, not a performance tradeoff you can tune away.
- Header framing uses tab/newline delimiters; header values containing literal
  tabs or newlines are not supported (neither is valid in HTTP).
- Response bodies and headers are returned as-is; JSON parsing is left to the
  caller.

## License

MIT. See `LICENSE`.
