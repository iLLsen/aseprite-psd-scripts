-- Import PSD to Aseprite
-- This script imports PSD files exported by "Export as psd.lua" back to Aseprite
-- Based on the subset of PSD format used by the export script
-- Supports both RGB (3 channels) and RGBA (4 channels) PSD files
-- Fully supports PSD group/folder structures with proper Layer.isGroup mapping

if not app then return end

-- ==============================
-- UTF-8 Safety Functions
-- ==============================

---Convert UTF-16BE to UTF-8
---@param utf16 string UTF-16BE encoded string
---@return string utf8 UTF-8 encoded string
local function utf16beToUtf8(utf16)
    local utf8 = {}
    for i = 1, #utf16, 2 do
        if i + 1 <= #utf16 then
            local code = string.unpack(">I2", utf16:sub(i, i+1))
            if code >= 0xD800 and code <= 0xDFFF then
                -- Surrogate pair handling (rare in PSD, skip for now)
                utf8[#utf8+1] = "?"
            else
                -- Convert Unicode code point to UTF-8
                if code <= 0x7F then
                    utf8[#utf8+1] = string.char(code)
                elseif code <= 0x7FF then
                    local b1 = 0xC0 + math.floor(code / 64)
                    local b2 = 0x80 + (code % 64)
                    utf8[#utf8+1] = string.char(b1, b2)
                elseif code <= 0xFFFF then
                    local b1 = 0xE0 + math.floor(code / 4096)
                    local b2 = 0x80 + math.floor((code % 4096) / 64)
                    local b3 = 0x80 + (code % 64)
                    utf8[#utf8+1] = string.char(b1, b2, b3)
                else
                    utf8[#utf8+1] = "?"
                end
            end
        end
    end
    return table.concat(utf8)
end

---Ensure string is safe UTF-8 (fallback for corrupted strings)
---@param str string
---@return string
local function safeUtf8(str)
    if not str or str == "" then return "" end
    
    -- Simple UTF-8 validation: check for invalid byte sequences
    local result = {}
    local i = 1
    local valid = true
    
    while i <= #str do
        local b1 = string.byte(str, i)
        
        if b1 <= 0x7F then
            -- ASCII character (0xxxxxxx)
            result[#result + 1] = string.char(b1)
            i = i + 1
        elseif b1 >= 0xC2 and b1 <= 0xDF then
            -- 2-byte sequence (110xxxxx 10xxxxxx)
            if i + 1 <= #str then
                local b2 = string.byte(str, i + 1)
                if b2 >= 0x80 and b2 <= 0xBF then
                    result[#result + 1] = str:sub(i, i + 1)
                    i = i + 2
                else
                    valid = false
                    break
                end
            else
                valid = false
                break
            end
        elseif b1 >= 0xE0 and b1 <= 0xEF then
            -- 3-byte sequence (1110xxxx 10xxxxxx 10xxxxxx)
            if i + 2 <= #str then
                local b2 = string.byte(str, i + 1)
                local b3 = string.byte(str, i + 2)
                if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
                    result[#result + 1] = str:sub(i, i + 2)
                    i = i + 3
                else
                    valid = false
                    break
                end
            else
                valid = false
                break
            end
        elseif b1 >= 0xF0 and b1 <= 0xF4 then
            -- 4-byte sequence (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx)
            if i + 3 <= #str then
                local b2 = string.byte(str, i + 1)
                local b3 = string.byte(str, i + 2)
                local b4 = string.byte(str, i + 3)
                if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
                    result[#result + 1] = str:sub(i, i + 3)
                    i = i + 4
                else
                    valid = false
                    break
                end
            else
                valid = false
                break
            end
        else
            -- Invalid byte
            valid = false
            break
        end
    end
    
    if valid then
        return str
    else
        -- Replace all non-ASCII bytes with underscore to prevent crashes
        return (str:gsub("[\128-\255]", "_"))
    end
end



-- ==============================
-- Helper Functions for Binary Reading
-- ==============================

---Read unsigned 16-bit big-endian integer
---@param file file*
---@return integer
local function readU16BE(file)
    return string.unpack(">I2", file:read(2))
end

---Read signed 16-bit big-endian integer
---@param file file*
---@return integer
local function readI16BE(file)
    return string.unpack(">i2", file:read(2))
end

---Read unsigned 32-bit big-endian integer
---@param file file*
---@return integer
local function readU32BE(file)
    return string.unpack(">I4", file:read(4))
end

---Read signed 32-bit big-endian integer
---@param file file*
---@return integer
local function readI32BE(file)
    return string.unpack(">i4", file:read(4))
end

---Read unsigned 8-bit integer
---@param file file*
---@return integer
local function readU8(file)
    return string.unpack("B", file:read(1))
end

---Read Pascal string (length-prefixed, padded to 4-byte boundary)
---@param file file*
---@return string
local function readPascalString(file)
    local len = readU8(file)
    local str = ""
    if len > 0 then
        str = file:read(len)
    end
    local padBytes = (4 - ((len + 1) % 4)) % 4
    if padBytes > 0 then
        file:read(padBytes)
    end
    return str
end

-- ==============================
-- PackBits Decoder
-- ==============================

---Decode PackBits compressed data
---@param data string
---@return string
local function unpackBits(data)
    local result = {}
    local i = 1
    
    while i <= #data do
        local n = string.byte(data, i)
        i = i + 1
        
        if n <= 127 then
            -- Literal run: copy next n+1 bytes
            local count = n + 1
            if i + count - 1 <= #data then
                result[#result + 1] = data:sub(i, i + count - 1)
                i = i + count
            else
                break
            end
        elseif n >= 129 then
            -- Replicate run: repeat next byte (257-n) times
            if i <= #data then
                local byte = data:sub(i, i)
                local count = 257 - n
                result[#result + 1] = byte:rep(count)
                i = i + 1
            else
                break
            end
        end
        -- n == 128: NOP (do nothing)
    end
    
    return table.concat(result)
end

-- ==============================
-- Blend Mode Mapping
-- ==============================

local blendModeMap = {
    ["norm"] = BlendMode.NORMAL,
    ["mul "] = BlendMode.MULTIPLY,
    ["scrn"] = BlendMode.SCREEN,
    ["over"] = BlendMode.OVERLAY,
    ["dark"] = BlendMode.DARKEN,
    ["lite"] = BlendMode.LIGHTEN,
    ["div "] = BlendMode.COLOR_DODGE,
    ["idiv"] = BlendMode.COLOR_BURN,
    ["hLit"] = BlendMode.HARD_LIGHT,
    ["sLit"] = BlendMode.SOFT_LIGHT,
    ["diff"] = BlendMode.DIFFERENCE,
    ["smud"] = BlendMode.EXCLUSION,
    ["hue "] = BlendMode.HSL_HUE,
    ["sat "] = BlendMode.HSL_SATURATION,
    ["colr"] = BlendMode.HSL_COLOR,
    ["lum "] = BlendMode.HSL_LUMINOSITY,
    ["lddg"] = BlendMode.ADDITION,
    ["fsub"] = BlendMode.SUBTRACT,
    ["fdiv"] = BlendMode.DIVIDE,
}

-- ==============================
-- Layer Data Structures
-- ==============================

---@class LayerInfo
---@field name string
---@field bounds {top: integer, left: integer, bottom: integer, right: integer}
---@field channels {id: integer, size: integer}[]
---@field blendMode string
---@field opacity integer
---@field visible boolean
---@field isGroup boolean
---@field groupType integer|nil -- 0=other, 1=open folder, 2=closed folder, 3=bounding divider
---@field channelData string[]

-- ==============================
-- PSD Import Function
-- ==============================

---Import PSD file and create Aseprite sprite
---@param filename string
---@return boolean success
---@return string|nil errorMessage
local function importFromPsd(filename)
    local file = io.open(filename, "rb")
    if not file then
        return false, "Failed to open PSD file: " .. filename
    end
    
    -- ==============================
    -- File Header Section
    -- ==============================
    
    -- Check signature
    local signature = file:read(4)
    if signature ~= "8BPS" then
        file:close()
        return false, "Not a valid PSD file (invalid signature)"
    end
    
    -- Check version
    local version = readU16BE(file)
    if version ~= 1 then
        file:close()
        return false, "Unsupported PSD version: " .. version
    end
    
    -- Skip reserved bytes
    file:read(6)
    
    -- Read channels count
    local channels = readU16BE(file)
    if channels ~= 3 and channels ~= 4 then
        file:close()
        return false, "Unsupported channel count: " .. channels .. " (only 3 or 4 allowed)"
    end
    local hasAlpha = (channels == 4)
    
    -- Read dimensions
    local height = readU32BE(file)
    local width = readU32BE(file)
    
    -- Check depth
    local depth = readU16BE(file)
    if depth ~= 8 then
        file:close()
        return false, "Unsupported bit depth: " .. depth .. " (expected 8)"
    end
    
    -- Check color mode
    local colorMode = readU16BE(file)
    if colorMode ~= 3 then
        file:close()
        return false, "Unsupported color mode: " .. colorMode .. " (expected 3 for RGB)"
    end
    
    -- ==============================
    -- Color Mode Data Section
    -- ==============================
    
    local colorModeDataLength = readU32BE(file)
    if colorModeDataLength > 0 then
        file:read(colorModeDataLength)
    end
    
    -- ==============================
    -- Image Resources Section
    -- ==============================
    
    local imageResourcesLength = readU32BE(file)
    if imageResourcesLength > 0 then
        file:read(imageResourcesLength)
    end
    
    -- ==============================
    -- Layer and Mask Information Section
    -- ==============================
    
    local layerAndMaskLength = readU32BE(file)
    local layerAndMaskEnd = file:seek("cur") + layerAndMaskLength
    
    local layerInfoLength = readU32BE(file)
    -- Bookmark the start of the layer info block (which begins with the layer count)
    local layerInfoStart = file:seek("cur")

    local layerCount = readI16BE(file)
    
    if layerCount < 0 then
        layerCount = -layerCount -- Absolute value for layer count
    end
    
    -- Read layer records
    local layers = {} ---@type LayerInfo[]
    
    for i = 1, layerCount do
        local layer = {} ---@type LayerInfo
        
        -- Read bounds
        layer.bounds = {
            top = readI32BE(file),
            left = readI32BE(file),
            bottom = readI32BE(file),
            right = readI32BE(file)
        }
        
        -- Read channel count and channel info
        local channelCount = readU16BE(file)
        layer.channels = {}
        
        for j = 1, channelCount do
            local channelId = readI16BE(file)
            local channelSize = readU32BE(file)
            layer.channels[j] = {id = channelId, size = channelSize}
        end
        
        -- Read blend mode signature
        local blendSig = file:read(4)
        if blendSig ~= "8BIM" then
            file:close()
            return false, "Invalid blend mode signature in layer " .. i
        end
        
        -- Read blend mode
        layer.blendMode = file:read(4)
        
        -- Read opacity
        layer.opacity = readU8(file)
        
        -- Read clipping (skip)
        readU8(file)
        
        -- Read flags
        local flags = readU8(file)
        layer.visible = (flags & 2) == 0 -- Bit 1: visibility (0 = visible)
        
        -- Read filler
        readU8(file)
        
        -- Read extra data field length
        local extraLength = readU32BE(file)
        local extraStart = file:seek("cur")
        
        -- Skip layer mask (always 0 in our export)
        local maskLength = readU32BE(file)
        if maskLength > 0 then
            file:read(maskLength)
        end
        
        -- Skip blending ranges (always 0 in our export)
        local blendingRangesLength = readU32BE(file)
        if blendingRangesLength > 0 then
            file:read(blendingRangesLength)
        end
        
        -- Read layer name
        layer.name = readPascalString(file)
        
        -- Check for additional layer information (lsct)
        layer.isGroup = false
        layer.groupType = nil
        
        ----------------------------------------------------------------
        -- Scan entire additional information area (previous single-if → while-loop)
        ----------------------------------------------------------------
        local curPos       = file:seek("cur")
        local processed    = curPos - extraStart
        local remaining    = extraLength - processed

        while remaining >= 12 do                        -- Continue if header is larger than 12 bytes
            local addSig  = file:read(4)                  -- "8BIM"
            local addKey  = file:read(4)                  -- "luni" / "lsct" etc.
            local addLen  = readU32BE(file)               -- payload length
            local padded  = addLen + (addLen % 2)         -- 2-byte even padding
            remaining = remaining - (12 + padded)

            if addSig ~= "8BIM" then                      -- Unexpected signature
                file:seek("cur", -8)                        -- Rewind and skip remaining
                if remaining > 0 then file:read(remaining) end
                break
            end

            if addKey == "lsct" and addLen >= 4 then      -- ★ Folder information found
                layer.groupType = readU32BE(file)           -- 0=other, 1/2=opener, 3=closer
                layer.isGroup   = (layer.groupType == 1 or layer.groupType == 2 or layer.groupType == 3)
                if padded > 4 then                          -- Skip remaining
                    file:read(padded - 4)
                end
            elseif addKey == "luni" and addLen >= 4 then   -- ★ Unicode layer name found
                local count = readU32BE(file)               -- UTF-16 code unit count
                local bytesToRead = count * 2
                if bytesToRead > 0 and bytesToRead <= addLen - 4 then
                    local utf16 = file:read(bytesToRead)    -- Read UTF-16BE data
                    layer.name = utf16beToUtf8(utf16)       -- Convert to UTF-8
                    if padded > 4 + bytesToRead then        -- Skip remaining padding
                        file:read(padded - 4 - bytesToRead)
                    end
                else
                    -- Invalid data, skip entire block
                    if padded > 4 then
                        file:read(padded - 4)
                    end
                end
            else
                -- Uninterested block: skip entire payload
                if padded > 0 then file:read(padded) end
            end
        end
        
        -- ALWAYS ensure the file pointer is perfectly aligned to the end of the extra data block
        file:seek("set", extraStart + extraLength)
        
        layers[i] = layer
    end

    -- Read channel image data
    for i = 1, layerCount do
        local layer = layers[i]
        layer.channelData = {}
        
        -- Create channel data mapping by channel ID
        local channelDataByID = {}
        
        for j = 1, #layer.channels do
            local channelInfo = layer.channels[j]
            local channelData = file:read(channelInfo.size)
            
            local decodedData = ""
            if #channelData >= 2 then
                local compression = string.unpack(">I2", channelData:sub(1, 2))
                if compression == 0 then
                    decodedData = channelData:sub(3)
                elseif compression == 1 then
                    -- RLE compression
                    local imageHeight = layer.bounds.bottom - layer.bounds.top
                    if imageHeight > 0 and #channelData > 2 then
                        local rowSizeTableSize = imageHeight * 2
                        if #channelData >= 2 + rowSizeTableSize then
                            local rowSizesData = channelData:sub(3, 2 + rowSizeTableSize)
                            local compressedRowsData = channelData:sub(3 + rowSizeTableSize)

                            local decodedChunks = {}
                            local dataOffset = 1

                            for y = 1, imageHeight do
                                local rowSize = string.unpack(">I2", rowSizesData:sub((y-1)*2 + 1, y*2))
                                if dataOffset + rowSize - 1 <= #compressedRowsData then
                                    local compressedRow = compressedRowsData:sub(dataOffset, dataOffset + rowSize - 1)
                                    decodedChunks[#decodedChunks + 1] = unpackBits(compressedRow)
                                    dataOffset = dataOffset + rowSize
                                else
                                    -- Data is truncated or corrupt, stop processing this channel
                                    break
                                end
                            end
                            decodedData = table.concat(decodedChunks)
                        end
                    end
                elseif compression == 2 or compression == 3 then
                    -- ZIP / ZIP with prediction compression (used by Photopea) is not supported.
                    file:close()
                    return false, "Unsupported compression method (" .. compression .. ") in layer '" .. layer.name .. "'.\n\nThis file uses ZIP compression, which is common for PSDs saved from Photopea. This script cannot decompress ZIP data because Aseprite's Lua environment does not provide the necessary tools."
                else
                    file:close()
                    return false, "Unsupported compression method (" .. compression .. ") in layer '" .. layer.name .. "'."
                end
            end
            
            -- Map channel data by ID: 0=R, 1=G, 2=B, -1=A
            channelDataByID[channelInfo.id] = decodedData
        end
        
        -- Store in standard order: R, G, B, A
        layer.channelData[1] = channelDataByID[0] or ""  -- Red
        layer.channelData[2] = channelDataByID[1] or ""  -- Green
        layer.channelData[3] = channelDataByID[2] or ""  -- Blue
        layer.channelData[4] = channelDataByID[-1] or channelDataByID[0xFFFF] or "" -- Alpha
    end
    
    file:close()
    
    -- ==============================
    -- Create Aseprite Sprite
    -- ==============================
    
    local sprite = Sprite(width, height, ColorMode.RGB)
    sprite:deleteLayer(sprite.layers[1]) -- Remove default layer
    
    -- Process layers in reverse order to match PSD layer stack (Top→Bottom becomes Bottom→Top)
    local groupStack = {} ---@type Layer[]
    
    for i = layerCount, 1, -1 do
        local layerInfo = layers[i]
        
        ------------------------------------------------------------
        -- (1) Overall structure for layer/group creation
        ------------------------------------------------------------
        if layerInfo.isGroup then
            ----------------------------------------------------------
            -- A. Opener: type 1·2  →  Create folder and continue
            ----------------------------------------------------------
            if layerInfo.groupType == 1 or layerInfo.groupType == 2 then

                local grp = sprite:newGroup()
                grp.name       = safeUtf8(layerInfo.name)
                grp.isVisible  = layerInfo.visible
                grp.isExpanded = (layerInfo.groupType ~= 2)

                -- Assign parent folder
                if #groupStack > 0 then
                    grp.parent = groupStack[#groupStack]
                end
                grp.stackIndex = 1            -- Move to bottom
                table.insert(groupStack, grp) -- push

                ------------------------- Important -------------------------
                goto nextRecord              -- Must end here to prevent double creation
                --------------------------------------------------------
            ----------------------------------------------------------
            -- B. Closer: type 3  →  Close folder and continue (no layer)
            ----------------------------------------------------------
            elseif layerInfo.groupType == 3 then
                if #groupStack > 0 then 
                    table.remove(groupStack)
                end
                goto nextRecord
            end
        end

        ------------------------------------------------------------
        -- (2) Regular layer processing (isGroup == false) ---------
        ------------------------------------------------------------
        local lay = sprite:newLayer()
        lay.name      = safeUtf8(layerInfo.name)
        lay.isVisible = layerInfo.visible
        lay.opacity   = layerInfo.opacity

        if blendModeMap[layerInfo.blendMode] then
            lay.blendMode = blendModeMap[layerInfo.blendMode]
        end

        if #groupStack > 0 then 
            lay.parent = groupStack[#groupStack]
        end
        lay.stackIndex = 1

        -- Create image if layer has content
        local layerWidth = layerInfo.bounds.right - layerInfo.bounds.left
        local layerHeight = layerInfo.bounds.bottom - layerInfo.bounds.top
        
        if layerWidth > 0 and layerHeight > 0 and #layerInfo.channelData >= 4 then
            local image = Image(layerWidth, layerHeight, ColorMode.RGB)
            
            -- Decode channel data
            local rData = layerInfo.channelData[1] or ""
            local gData = layerInfo.channelData[2] or ""
            local bData = layerInfo.channelData[3] or ""
            local aData = layerInfo.channelData[4] -- may be nil
            
            -- If no alpha channel, create opaque alpha data
            local opaque = string.char(255):rep(layerWidth * layerHeight)
            if not aData or #aData == 0 then 
                aData = opaque 
            end
            
            local expectedSize = layerWidth * layerHeight
            
            for y = 0, layerHeight - 1 do
                for x = 0, layerWidth - 1 do
                    local pixelIndex = y * layerWidth + x + 1
                    
                    local r = 0
                    local g = 0
                    local b = 0
                    local a = 255
                    
                    if pixelIndex <= #rData then
                        r = string.byte(rData, pixelIndex)
                    end
                    if pixelIndex <= #gData then
                        g = string.byte(gData, pixelIndex)
                    end
                    if pixelIndex <= #bData then
                        b = string.byte(bData, pixelIndex)
                    end
                    if pixelIndex <= #aData then
                        a = string.byte(aData, pixelIndex)
                    end
                    
                    local color = app.pixelColor.rgba(r, g, b, a)
                    image:drawPixel(x, y, color)
                end
            end
            
            local cel = sprite:newCel(lay, 1, image, Point(layerInfo.bounds.left, layerInfo.bounds.top))
        end

        ::nextRecord::
        -- ↓ continue for-loop
    end
    

    
    return true, nil
end

-- ==============================
-- UI and Entry Point
-- ==============================

if app.apiVersion < 1 then
    if app.isUIAvailable then
        app.alert({
            title = "Import Failed",
            text = "This script requires Aseprite v1.2.10-beta3 or above.",
            buttons = "OK"
        })
    else
        io.stderr:write("Import failed: this script requires Aseprite v1.2.10-beta3 or above.")
    end
    return
end

local function showImportDialog()
    -- Get desktop path as default starting location
    local desktopPath = ""
    
    -- Try different methods to get desktop path
    if os.getenv("USERPROFILE") then
        -- Windows: %USERPROFILE%\Desktop
        desktopPath = os.getenv("USERPROFILE") .. "\\Desktop"
    elseif os.getenv("HOME") then
        -- macOS/Linux: $HOME/Desktop
        desktopPath = os.getenv("HOME") .. "/Desktop"
    end
    -- If path is empty, Aseprite will use its default starting location
    
    local dialog = Dialog()
    dialog:file {
        id = "filename",
        label = "PSD File",
        title = "Select PSD File...",
        open = true,
        filetypes = { "psd" },
        filename = desktopPath, -- Start from desktop if available
    }:button {
        id = "ok",
        text = "&Import",
        focus = true
    }:button {
        id = "cancel",
        text = "&Cancel"
    }:label {
        text = "PSD → Aseprite Import Tool\n(RGB/RGBA 8bit + Group Structure Support)"
    }
    
    dialog:show()
    
    if dialog.data.ok then
        local filename = dialog.data.filename
        if filename and filename ~= "" then
            local success, errorMessage = importFromPsd(filename)
            
            if success then
                app.alert({
                    title = "Import Complete",
                    text = "PSD file imported successfully!\n" .. filename,
                    buttons = "OK"
                })
            else
                app.alert({
                    title = "Import Failed",
                    text = "An error occurred while importing the PSD file:\n" .. (errorMessage or "Unknown error"),
                    buttons = "OK"
                })
            end
        end
    end
end

local function getOptionsFromCLI()
    local filename = nil
    
    for key, value in pairs(app.params) do
        key = key:lower()
        if key == "filename" or key == "file" or key == "f" then
            filename = value
        end
    end
    
    return filename
end

if app.isUIAvailable then
    showImportDialog()
else
    local filename = getOptionsFromCLI()
    if filename then
        local success, errorMessage = importFromPsd(filename)
        if success then
            print("PSD file imported successfully: " .. filename)
        else
            io.stderr:write("Import failed: " .. (errorMessage or "Unknown error"))
        end
    else
        io.stderr:write("Usage: aseprite -b -script 'import from psd.lua' --filename=file.psd")
    end
end
