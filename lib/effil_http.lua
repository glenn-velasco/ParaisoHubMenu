-- effil_http.lua
-- Asynchronous HTTP(S) for MoonLoader scripts.
--
-- Plain LuaSocket/LuaSec requests block the calling coroutine, and MoonLoader
-- runs every script on the single game thread. A synchronous HTTPS call
-- therefore freezes rendering and input for the whole duration of the request.
-- This module moves each request into a native OS thread via `effil`, so the
-- game thread only ever polls a cheap status flag. Callbacks are dispatched
-- back on the game thread from `M.pump()`, so it is safe to touch SAMP/mimgui
-- state inside them.
--
-- Two hard-won constraints shape the design (see inline comments):
--   1. effil serializes the thread function with `lua_dump` and rejects
--      non-primitive upvalues. The worker is therefore compiled from a plain
--      source STRING (no captured locals) and receives everything as arguments.
--   2. Concurrent LuaSec/OpenSSL handshakes from two effil threads crash the
--      process natively (OpenSSL has no locking callbacks in this build).
--      All requests are serialized: exactly one worker is ever in flight.
--
-- Public API:
--   M.request(opts, callback)   opts = { url, method='GET', headers={}, body=nil, timeout=30 }
--                               callback(response, err)
--                               response = { status=number, body=string, headers=table }
--   M.pump()                    call from the game thread (main loop / lua_thread)
--   M.run(interval)             convenience: spawn a lua_thread that pumps forever
--
-- Requires: effil, and the `requests` library (LuaSocket + LuaSec) available
-- inside a freshly spawned effil Lua state.

local ok_effil, effil = pcall(require, 'effil')
if not ok_effil then effil = nil end

local M = {}

-- ────────────────────────────────────────────────────────────────────────
-- Worker source, kept as a STRING on purpose.
--
-- effil dumps the thread function via lua_dump and refuses to transmit a
-- function whose upvalues are not primitives. Compiling this text with
-- loadstring yields a function with NO upvalues (under Lua 5.1 the environment
-- is not serialized either), so effil can always transmit it. The worker
-- receives its inputs as plain string/number arguments and returns only plain
-- scalars — never tables, which effil would otherwise turn into effil.table
-- proxies. Headers cross the boundary as a "name\tvalue\n" blob.
-- ────────────────────────────────────────────────────────────────────────
local WORKER_SRC = [==[
return function(method, url, headers_blob, body, timeout)
    local ok_req, requests = pcall(require, 'requests')
    if not ok_req or type(requests) ~= 'table' then
        return 'requests_unavailable', 0, '', ''
    end

    -- Decode the request headers blob back into a table.
    local headers = {}
    for name, value in tostring(headers_blob or ''):gmatch('([^\t\n]*)\t([^\n]*)\n') do
        if name ~= '' then headers[name] = value end
    end

    method = tostring(method or 'GET'):upper()
    local fn = requests[method:lower()]
    if type(fn) ~= 'function' then
        return 'unsupported_method_' .. method, 0, '', ''
    end

    local opts = { headers = headers, timeout = tonumber(timeout) or 30 }
    if body ~= nil and body ~= '' then opts.data = tostring(body) end

    -- This is the blocking call. It runs here, in the effil thread, so the
    -- game thread is never stalled by the SSL handshake or the round trip.
    local ok_call, resp = pcall(fn, url, opts)
    if not ok_call then
        return 'transport_error', 0, '', ''
    end

    local status = tonumber(resp and resp.status_code) or 0
    local resp_body = tostring((resp and (resp.text or resp.content)) or '')

    -- Encode response headers with the same tab/newline scheme.
    local out = {}
    local rh = resp and resp.headers
    if type(rh) == 'table' then
        for k, v in pairs(rh) do
            out[#out + 1] = tostring(k) .. '\t' .. tostring(v) .. '\n'
        end
    end

    return '', status, resp_body, table.concat(out)
end
]==]

-- ────────────────────────────────────────────────────────────────────────
-- State
-- ────────────────────────────────────────────────────────────────────────
local queue = {}       -- FIFO of pending requests
local active = nil     -- the single in-flight request, or nil when the slot is free
local runner = nil     -- cached effil runner (building it is not free)
local runner_err = nil -- sticky build error

-- header table  <->  "name\tvalue\n" blob. Newlines in header values are
-- illegal in HTTP anyway; tabs in names never occur.
-- ponytail: naive tab/newline framing, fine for real HTTP headers. Swap for a
-- length-prefixed codec only if some server emits tabs inside header values.
local function encode_headers(h)
    if type(h) ~= 'table' then return '' end
    local out = {}
    for k, v in pairs(h) do
        out[#out + 1] = tostring(k) .. '\t' .. tostring(v) .. '\n'
    end
    return table.concat(out)
end

local function decode_headers(blob)
    local h = {}
    for name, value in tostring(blob or ''):gmatch('([^\t\n]*)\t([^\n]*)\n') do
        if name ~= '' then h[name] = value end
    end
    return h
end

-- Build (and cache) the effil runner from the worker source. The runner is a
-- reusable factory: calling it spawns a fresh worker thread each time.
local function build_runner()
    if runner then return runner end
    if runner_err then return nil end
    if not effil then runner_err = 'effil_unavailable'; return nil end

    local chunk, e = loadstring(WORKER_SRC, '@effil_http_worker')
    if not chunk then runner_err = 'worker_compile: ' .. tostring(e); return nil end
    local ok_fn, fn = pcall(chunk)
    if not ok_fn or type(fn) ~= 'function' then
        runner_err = 'worker_init: ' .. tostring(fn)
        return nil
    end
    local ok_r, r = pcall(effil.thread, fn)
    if not ok_r or r == nil then runner_err = 'effil_thread: ' .. tostring(r); return nil end
    runner = r
    return runner
end

local function dispatch(cb, resp, err)
    local ok, e = pcall(cb, resp, err)
    if not ok then print('[effil-http] callback error: ' .. tostring(e)) end
end

-- ────────────────────────────────────────────────────────────────────────
-- Public API
-- ────────────────────────────────────────────────────────────────────────

-- Queue a request. Returns immediately; the callback fires later from pump().
function M.request(opts, callback)
    assert(type(opts) == 'table' and type(opts.url) == 'string', 'effil_http: opts.url (string) required')
    assert(type(callback) == 'function', 'effil_http: callback (function) required')
    queue[#queue + 1] = {
        url = opts.url,
        method = tostring(opts.method or 'GET'),
        headers = opts.headers or {},
        body = opts.body,
        timeout = tonumber(opts.timeout) or 30,
        cb = callback,
    }
end

-- Drive the queue. MUST be called from the game thread (a lua_thread or the
-- main loop). Non-blocking: it polls the worker's status and returns at once.
function M.pump()
    -- 1) Service the in-flight worker.
    if active then
        local w = active.worker
        local sok, st = pcall(function() return w:status() end)
        if not sok then
            if not active.abandoned then dispatch(active.cb, nil, 'worker_status_error') end
            active = nil
        elseif st == 'completed' or st == 'failed' or st == 'cancelled' then
            if not active.abandoned then
                -- get(0) is effil's non-blocking fetch; the thread is finished here.
                local gok, err_s, status, body, hblob = pcall(function() return w:get(0) end)
                if gok and type(status) == 'number' then
                    if err_s ~= nil and err_s ~= '' then
                        dispatch(active.cb, nil, tostring(err_s))
                    else
                        dispatch(active.cb, { status = status, body = body or '', headers = decode_headers(hblob) }, nil)
                    end
                else
                    dispatch(active.cb, nil, 'worker_get_error')
                end
            end
            -- Freeing the slot here also releases an abandoned worker that has
            -- finally settled; only now is it safe to start the next request.
            active = nil
        elseif (not active.abandoned) and os.time() >= active.deadline then
            -- Timeout. We must NEVER call worker:cancel() — cancellation
            -- unwinds a thread parked inside a native LuaSec call and segfaults.
            -- Instead: report the timeout now, but keep the slot OCCUPIED so we
            -- never open a second concurrent SSL handshake. The slot is freed
            -- above, once this worker settles on its own.
            active.abandoned = true
            dispatch(active.cb, nil, 'timeout')
        end
    end

    -- 2) Start the next queued request if the slot is free.
    if not active and #queue > 0 then
        local req = table.remove(queue, 1)
        local r = build_runner()
        if not r then
            dispatch(req.cb, nil, runner_err or 'no_worker')
            return
        end
        -- All arguments are plain scalars — effil cannot marshal tables here
        -- without turning them into effil.table proxies.
        local sp_ok, worker = pcall(r, req.method, req.url, encode_headers(req.headers), req.body or '', req.timeout)
        if not sp_ok or worker == nil then
            dispatch(req.cb, nil, 'spawn_error: ' .. tostring(worker))
            return
        end
        active = {
            worker = worker,     -- keep a reference so the GC never collects a live thread
            cb = req.cb,
            deadline = os.time() + req.timeout, -- wall clock; os.clock() is CPU time and stalls while idle
            abandoned = false,
        }
    end
end

-- Convenience: spawn a dedicated lua_thread that pumps forever. Use this if the
-- host script has no main loop of its own. MoonLoader terminates the thread on
-- script unload.
function M.run(interval)
    interval = tonumber(interval) or 50
    lua_thread.create(function()
        while true do
            M.pump()
            wait(interval)
        end
    end)
end

return M
