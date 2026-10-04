local _package = {}
for k, v in pairs(require("package")) do
    _package[k] = v
end
local __package = _G.package

local _require = require

return function(instances)
    local package = {}
    
    local metatable = {
        __index = _package,
        __pairs = function(t)
            local parent = false
            return function(_, key)
                if parent then
                    return next(_package, key)
                else
                    local k, v = next(t, key)
                    if not k then
                        parent = true
                        return next(_package)
                    else
                        return k, v
                    end
                end
            end
        end
    }
    setmetatable(package, metatable)

    package.path = _package.path
    local loaded = {}
    local loading = {}
    package.loaded = loaded
    package.preload = {}
    for k, v in pairs(_package.preload or {}) do
        package.preload[k] = v
    end
    package.searchers = {}
    
    setmetatable(package.loaded, {
        __index = function(t, k)
            if _package.loaded[k] then
                return _package.loaded[k]
            end
            return nil
        end,
        __pairs = function(t)
            local parent = false
            return function(_, key)
                if parent then
                    return next(_package.loaded, key)
                end
                local k, v = next(t, key)
                if not k then
                    parent = true
                    return next(_package.loaded)
                else
                    return k, v
                end
            end
        end
    })

    function package.searchpath(name, path, sep, rep)
        checkArg(1, name, "string")
        checkArg(2, path, "string")
        sep = sep or '.'
        rep = rep or '/'
        sep, rep = '%' .. sep, rep
        name = string.gsub(name, sep, rep)
        local fs = _require("filesystem")
        local errorFiles = {}
        for subPath in string.gmatch(path, "([^;]+)") do
          subPath = string.gsub(subPath, "?", name)
          if subPath:sub(1, 1) ~= "/" and os.getenv then
            subPath = fs.concat(os.getenv("PWD") or "/", subPath)
          end
          if fs.exists(subPath) then
            local file = fs.open(subPath, "r")
            if file then
              file:close()
              return subPath
            end
          end
          table.insert(errorFiles, "\tno file '" .. subPath .. "'")
        end
        return nil, table.concat(errorFiles, "\n")
      end
    

    table.insert(package.searchers, function(module)
        if package.preload[module] then
            return package.preload[module]
        end
        
        return "no field package.preload['" .. module .. "']"
    end)
    table.insert(package.searchers, function(module)
        local library, path, status
  
        path, status = package.searchpath(module, package.path)
        if not path then
            return status
        end
  
        library, status = loadfile(path)
        if not library then
            error(string.format("error loading module '%s' from file '%s':\n\t%s", module, path, status))
        end
  
        return library, module
    end)

    function package.require(module)
        checkArg(1, module, "string")
        if loaded[module] ~= nil then
          return loaded[module]
        elseif loading[module] then
          error("already loading: " .. module .. "\n" .. debug.traceback(), 2)
        else
          local library, status, arg
          local errors = ""
      
          if type(package.searchers) ~= "table" then error("'package.searchers' must be a table") end
          for _, searcher in pairs(package.searchers) do
            library, arg = searcher(module)
            if type(library) == "function" then break end
            if type(library) ~= nil then
              errors = errors .. "\n\t" .. tostring(library)
              library = nil
            end
          end
          if not library then error(string.format("module '%s' not found:%s", module, errors)) end
      
          loading[module] = true
          library, status = pcall(library, arg or module)
          loading[module] = false
          assert(library, string.format("module '%s' load failed:\n%s", module, status))
          loaded[module] = status
          return status
        end
      end

    instances.package = package

    table.insert(instances.loads.load, function()
        _G.require = package.require
        _G.package = package
    end)

    table.insert(instances.loads.unload, function()
        _G.require = _require
        _G.package = __package
    end)
end
