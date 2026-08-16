-- example.lua
-- MoonLoader script demonstrating effil_http.
--
-- Place effil_http.lua in moonloader/lib/ (or next to this script) and drop
-- this file in moonloader/. It queues two GET requests plus a POST with a JSON
-- body and prints the resulting status codes to chat.

script_name('effil-http example')
script_author('t9foon1337')

local http = require('effil_http')

function main()
    while not isSampAvailable() do wait(100) end

    -- Spawn the pump thread. Callbacks below run on the game thread.
    http.run()

    sampAddChatMessage('[effil-http] sending 2 GET + 1 POST...', 0x88CCFF)

    -- Two GETs queued back to back. They run sequentially (one worker at a
    -- time), not in parallel — the library serializes SSL by design.
    http.request({ url = 'https://httpbin.org/get' }, function(resp, err)
        if err then
            sampAddChatMessage('[effil-http] GET #1 error: ' .. tostring(err), 0xFF5555)
        else
            sampAddChatMessage('[effil-http] GET #1 status: ' .. tostring(resp.status), 0x88FF88)
        end
    end)

    http.request({ url = 'https://httpbin.org/ip' }, function(resp, err)
        if err then
            sampAddChatMessage('[effil-http] GET #2 error: ' .. tostring(err), 0xFF5555)
        else
            sampAddChatMessage('[effil-http] GET #2 status: ' .. tostring(resp.status), 0x88FF88)
        end
    end)

    -- POST with a JSON body.
    http.request({
        url = 'https://httpbin.org/post',
        method = 'POST',
        headers = { ['Content-Type'] = 'application/json' },
        body = '{"hello":"world","n":42}',
        timeout = 20,
    }, function(resp, err)
        if err then
            sampAddChatMessage('[effil-http] POST error: ' .. tostring(err), 0xFF5555)
        else
            sampAddChatMessage('[effil-http] POST status: ' .. tostring(resp.status), 0x88FF88)
        end
    end)

    wait(-1)
end
