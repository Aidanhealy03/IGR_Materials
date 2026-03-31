/*
    IGR / IPS Quartz Sink Finish Renderer (Single Scene)
    ----------------------------------------------------
    Rules implemented:
      - Process CURRENTLY OPEN scene only
      - Hardcoded SKU -> size group table
      - Find sink by EXACT node name (SKU)
      - Apply quartz finish materials one-by-one
      - Render camera list by sink size group
      - Save JPG renders to: R:\Aidan\IPS\<SKU>\
      - Filename format: <SKU>_<FINISH>_IPS##.jpg
      - Force render resolution 2000x2000
      - Skip missing SKUs safely

    NOTE:
      - Update camera names in sizeGroupToCameras if your scene uses different names.
      - This script intentionally ignores accessories/drains/racks/cutters.
*/

(
    /* ============================
       User-editable settings
       ============================ */

    global IPS_QuartzLibPath = @"R:\Creative\3D Library\3D Library\Material Library\Quartz.mat"
    global IPS_OutputRoot = @"R:\Aidan\IPS"

    -- Quartz finish definitions: #("FinishCode", "QuartzMaterialName")
    global IPS_Finishes = #(
        #("WH", "White_Quartz"),
        #("BL", "Black_Quartz"),
        #("CN", "Concrete_Quartz_02"),
        #("BR", "Brown_Quartz_02"),
        #("GR", "Grey_Quartz_02"),
        #("BI", "Bisque_Quartz_02")
    )

    -- Hardcoded SKU -> size group lookup table
    -- Add / edit entries as needed.
    global IPS_SkuToSizeGroup = #(
        #("Q-306",      "S"),
        #("Q-315",      "S"),
        #("QUWS-875",   "L"),
        #("QARWS-740",  "M"),
        #("QAWS-000",   "M"),
        #("QTWS-000",   "L")
    )

    -- Size group -> camera names (render order = IPS01, IPS02, ...)
    -- Replace these camera names with your scene's exact camera node names.
    global IPS_SizeGroupToCameras = #(
        #("S", #("Corona Camera 001", "Corona Camera 002", "Corona Camera 003", "Corona Camera 004")),
        #("M", #("Corona Camera 001", "Corona Camera 002", "Corona Camera 003", "Corona Camera 004")),
        #("L", #("Corona Camera 001", "Corona Camera 002", "Corona Camera 003", "Corona Camera 004"))
    )

    -- Apply quartz material to objects whose names start with these prefixes
    global IPS_TargetNamePrefixes = #("Q", "QA", "QAR", "QU", "QT", "QAWS", "QARWS", "QUWS", "QTWS")

    global IPS_RenderWidth = 2000
    global IPS_RenderHeight = 2000
    global IPS_JpegQuality = 100 -- highest quality when supported

    /* ============================
       Helper functions
       ============================ */

    fn lowerSafe s = if s == undefined then "" else toLower (s as string)

    fn ensureTrailingBackslash p =
    (
        if p == undefined or p == "" then "" else
        (
            local c = substring p p.count 1
            if c == "\\" then p else (p + "\\")
        )
    )

    fn ensureFolderExists folderPath = makeDir folderPath all:true

    fn startsWithCI txt prefix =
    (
        local t = lowerSafe txt
        local p = lowerSafe prefix
        if p.count == 0 or t.count < p.count then false else ((substring t 1 p.count) == p)
    )

    fn nodeNameStartsWithAnyPrefix n prefixes =
    (
        for p in prefixes do
        (
            if startsWithCI n.name p do return true
        )
        false
    )

    fn getMaterialFromQuartzLibrary matName =
    (
        if not (doesFileExist IPS_QuartzLibPath) then
        (
            format "[ERROR] Quartz library does not exist: %\n" IPS_QuartzLibPath
            return undefined
        )

        local lib = loadTempMaterialLibrary IPS_QuartzLibPath
        if lib == undefined then
        (
            format "[ERROR] Failed to load Quartz library: %\n" IPS_QuartzLibPath
            return undefined
        )

        local target = lowerSafe matName
        for i = 1 to lib.count do
        (
            local m = lib[i]
            if m != undefined and (lowerSafe m.name) == target do return (copy m)
        )

        format "[WARN] Quartz material not found: %\n" matName
        undefined
    )

    fn findSizeGroupForSku sku =
    (
        for row in IPS_SkuToSizeGroup do
        (
            if (lowerSafe row[1]) == (lowerSafe sku) do return row[2]
        )
        undefined
    )

    fn findCameraListForSizeGroup sizeGroup =
    (
        for row in IPS_SizeGroupToCameras do
        (
            if (lowerSafe row[1]) == (lowerSafe sizeGroup) do return row[2]
        )
        undefined
    )

    fn collectTargetNodesForSku skuNode =
    (
        local out = #()

        -- Include exact SKU node hierarchy
        append out skuNode
        for c in skuNode.children do append out c

        -- Include any scene object whose name starts with known sink prefixes
        for n in objects do
        (
            if nodeNameStartsWithAnyPrefix n IPS_TargetNamePrefixes do
            (
                if (findItem out n) == 0 do append out n
            )
        )

        out
    )

    fn assignQuartzToTargetNodes targetNodes quartzMat sku finishCode =
    (
        if quartzMat == undefined then return false
        local assigned = 0
        for n in targetNodes do
        (
            if isProperty n #material then
            (
                n.material = quartzMat
                assigned += 1
            )
        )

        format "[INFO] SKU % finish % -> assigned quartz '%' to % node(s).\n" sku finishCode quartzMat.name assigned
        true
    )

    fn buildOutputFilePath sku finishCode indexNum =
    (
        local skuFolder = ensureTrailingBackslash IPS_OutputRoot + sku + "\\"
        ensureFolderExists skuFolder

        local idx = formattedPrint indexNum format:"02d"
        skuFolder + sku + "_" + finishCode + "_IPS" + idx + ".jpg"
    )

    fn getCameraNode camName =
    (
        local c = getNodeByName camName exact:true
        if c == undefined then c = getNodeByName camName
        c
    )

    fn setJpegQualityBestEffort =
    (
        try (JpegIO.setQuality IPS_JpegQuality) catch()
        try (if isProperty rendImageType #jpegQuality do rendImageType.jpegQuality = IPS_JpegQuality) catch()
    )

    fn renderSkuForFinish sku finishCode quartzMat cameraNames =
    (
        local renderCount = 0

        for i = 1 to cameraNames.count do
        (
            local camName = cameraNames[i]
            local camNode = getCameraNode camName

            if camNode == undefined then
            (
                format "[WARN] Camera not found for SKU %: %\n" sku camName
                continue
            )

            local outPath = buildOutputFilePath sku finishCode i

            renderWidth = IPS_RenderWidth
            renderHeight = IPS_RenderHeight
            setJpegQualityBestEffort()

            -- Force save-file behavior per render
            rendSaveFile = true
            rendOutputFilename = outPath

            local bmp = render camera:camNode outputFile:outPath vfb:false
            if bmp != undefined do
            (
                close bmp
                renderCount += 1
                format "[SUCCESS] Rendered: %\n" outPath
            )
        )

        renderCount
    )

    fn processSkuInCurrentScene sku =
    (
        local skuNode = getNodeByName sku exact:true
        if skuNode == undefined then
        (
            format "[INFO] SKU not in this scene, skipped: %\n" sku
            return #(0,0) -- #(renders, finishesProcessed)
        )

        local sizeGroup = findSizeGroupForSku sku
        if sizeGroup == undefined then
        (
            format "[WARN] No size group mapping for SKU, skipped: %\n" sku
            return #(0,0)
        )

        local cams = findCameraListForSizeGroup sizeGroup
        if cams == undefined or cams.count == 0 then
        (
            format "[WARN] No camera list for size group '%', SKU skipped: %\n" sizeGroup sku
            return #(0,0)
        )

        local targetNodes = collectTargetNodesForSku skuNode
        local totalRenders = 0
        local finishCount = 0

        for f in IPS_Finishes do
        (
            local finishCode = f[1]
            local matName = f[2]
            local quartzMat = getMaterialFromQuartzLibrary matName
            if quartzMat == undefined then
            (
                format "[WARN] Missing material for SKU % finish %: %\n" sku finishCode matName
                continue
            )

            if assignQuartzToTargetNodes targetNodes quartzMat sku finishCode then
            (
                finishCount += 1
                totalRenders += renderSkuForFinish sku finishCode quartzMat cams
            )
        )

        #(totalRenders, finishCount)
    )

    /* ============================
       Main (CURRENT OPEN SCENE ONLY)
       ============================ */

    format "\n=== IPS Single-Scene Quartz Variant Renderer Started ===\n"

    ensureFolderExists IPS_OutputRoot

    local sceneRenders = 0
    local sceneFinishes = 0
    local sceneSkuProcessed = 0

    for row in IPS_SkuToSizeGroup do
    (
        local sku = row[1]
        local result = processSkuInCurrentScene sku
        if result[2] > 0 do
        (
            sceneSkuProcessed += 1
            sceneRenders += result[1]
            sceneFinishes += result[2]
        )
    )

    format "\n=== IPS Render Completed (Current Scene) ===\n"
    format "[INFO] SKUs processed in scene: %\n" sceneSkuProcessed
    format "[INFO] Finishes processed: %\n" sceneFinishes
    format "[INFO] JPG renders saved: %\n" sceneRenders

    messageBox (
        "IPS render job complete (current scene).\n\n" +
        "SKUs processed: " + (sceneSkuProcessed as string) + "\n" +
        "Finishes processed: " + (sceneFinishes as string) + "\n" +
        "JPG renders saved: " + (sceneRenders as string)
    ) title:"IPS Quartz Variant Renderer"
)
