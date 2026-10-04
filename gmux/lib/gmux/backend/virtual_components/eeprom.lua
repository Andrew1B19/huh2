return function(options)
    if options == nil then
        options = {}
    end
    local eeprom = {
        type = "eeprom",
        address = options.address or "virtual0-eepr-om00-0000-component000",
    }
    local store = options.store or ""
    local store_size = options.store_size or 4096
    local label = options.label or "EEPROM"
    local data = options.data or ""
    local data_size = options.data_size or 256
    local readonly = options.readonly or false

    function eeprom.get()
        return store
    end
    function eeprom.set(value)
        if readonly then
            return
        end
        store = value:sub(1, store_size)
        if options.onset then
            options.onset(value)
        end
    end
    function eeprom.getLabel()
        return label
    end
    function eeprom.setLabel(value)
        label = value
    end
    function eeprom.getSize()
        return store_size
    end
    function eeprom.getDataSize()
        return data_size
    end
    function eeprom.getData()
        return data
    end
    function eeprom.setData(value)
        if readonly then
            return
        end
        data = value:sub(1, data_size)
    end
    function eeprom.getChecksum()
        return ""
    end
    function eeprom.makeReadonly(checksum)
        if checksum == eeprom.getChecksum() then
            readonly = true
        end
    end

    function eeprom._dump()
        return {
            address = eeprom.address,
            store = store,
            store_size = store_size,
            label = label,
            data = data,
            data_size = data_size,
            readonly = readonly,
        }
    end

    return eeprom
end
