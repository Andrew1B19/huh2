-- ocemu scenario: proves each job's virtual filesystem is actually rooted/isolated under real
-- OpenOS - job A writes a file, job B (different base_path, same backing real fs) must not see it,
-- and a path-traversal attempt from job B must not escape its own root.
local core = require("smux/backend/core")
local process = require("smux/backend/process")
local real_fs = require("filesystem")

if not real_fs.exists("/mnt/161/jobs") then real_fs.makeDirectory("/mnt/161/jobs") end
-- get() resolves the actual writable HDD mounted at /mnt/161 (not whichever filesystem happens
-- to list first - there's also the read-only OpenOS loot disk).
local real_hdd = real_fs.get("/mnt/161")

-- path here is relative to the filesystem PROXY's own root ("/jobs/a"), not the OS-level mount
-- point ("/mnt/161/jobs/a") - a component proxy's open()/exists() etc. don't know about OpenOS's
-- mount aliasing at all, that's a layer above the component itself.
local fs_a = core.virtual_components.filesystem({ id = "a", path = "/jobs/a", filesystem = real_hdd })
local fs_b = core.virtual_components.filesystem({ id = "b", path = "/jobs/b", filesystem = real_hdd })

core.load()

local a_wrote, b_sees_a, b_escape_blocked = false, nil, nil

process.create_process({
    name = "job_a",
    error_handler = function(proc, err) print("job_a ERROR: " .. tostring(err)) end,
    main = function()
        -- options.components (array of strings) only borrows REAL primaries by type at creation;
        -- a virtual (synthetic) component is added from inside the process itself, via its own
        -- patched `component` instance, then explicitly made primary so getPrimary() finds it.
        local component = require("component")
        component._add_component(fs_a)
        component.setPrimary("filesystem", fs_a.address)
        require("event").pull(0.05)
        -- Raw numeric-handle convention (not an io.open()-style object): open/write/close all
        -- take the handle as an explicit argument, matching the real component filesystem API
        -- this virtual filesystem wraps.
        local comp = component.getPrimary("filesystem")
        local handle = comp.open("/secret.txt", "w")
        comp.write(handle, "job a's secret")
        comp.close(handle)
        a_wrote = true
    end,
})

process.create_process({
    name = "job_b",
    error_handler = function(proc, err) print("job_b ERROR: " .. tostring(err)) end,
    main = function()
        local component = require("component")
        component._add_component(fs_b)
        component.setPrimary("filesystem", fs_b.address)
        require("event").pull(0.1) -- after job_a has written
        local comp = component.getPrimary("filesystem")
        b_sees_a = comp.exists("/secret.txt")
        -- Path traversal attempt: try to escape job_b's own root back to job_a's directory.
        -- KNOWN GAP (forked as-is from Gmux, flagged for the follow-up to fix properly): when
        -- wrap() blocks a path by returning nil, filesystem.lua's open() doesn't check for that
        -- before calling the real fs.open(nil, mode) - which raises a raw error instead of a
        -- clean "access denied" return. The escape is still blocked (no data crosses roots), just
        -- via an uncaught error rather than a graceful nil - so this has to be pcall'd here, not
        -- because that's the right behavior long-term, but because it's what the forked code
        -- actually does today.
        local ok = pcall(function() return comp.open("/../a/secret.txt", "r") end)
        b_escape_blocked = not ok
    end,
})

core.loop(function(stop)
    if a_wrote and b_sees_a ~= nil and b_escape_blocked ~= nil then stop() end
end)

core.finish()

print("a_wrote=" .. tostring(a_wrote))
print("b_sees_a=" .. tostring(b_sees_a))
print("b_escape_blocked=" .. tostring(b_escape_blocked))

assert(a_wrote, "job_a should have written its file")
assert(b_sees_a == false, "job_b must not see job_a's file - different roots on the same real fs")
assert(b_escape_blocked == true, "a path-traversal attempt must not escape job_b's own root")
print("FILESYSTEM ISOLATION: PASS")
