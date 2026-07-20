local cache = {}

local level_aliases = {
    err = "error",
    fatal = "critical",
    panic = "critical",
    warn = "warning"
}

function enrich(tag, timestamp, record)
    local path = record["container_path"]
    if path then
        local cid = path:match("containers/(%x+)/")
        if cid then
            if not cache[cid] then
                local file = io.open("/var/lib/docker/containers/" .. cid .. "/config.v2.json", "r")
                if file then
                    local data = file:read("*a")
                    file:close()
                    local name = data:match('"Name":"/([^" ]+)"')
                    cache[cid] = name or cid:sub(1, 12)
                else
                    cache[cid] = cid:sub(1, 12)
                end
            end
            record["container_name"] = cache[cid]
        end
        record["container_path"] = nil
    end

    local log = record["log"]
    if type(log) == "string" then
        local level = log:match('"level"%s*:%s*"([%a]+)"')
            or log:match('%f[%w]level=([%a]+)')
        if level then
            level = level:lower()
            record["level"] = level_aliases[level] or level
        end
    end

    record["host"] = "vps"
    return 1, timestamp, record
end
