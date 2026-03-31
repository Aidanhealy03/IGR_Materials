/*
    IGR / IPS Quartz Sink Finish Renderer (Multi-Scene)
    ---------------------------------------------------
    Workflow:
      1) Prompt for a root folder at runtime
      2) Recursively find .max scene files under that folder
      3) Open each scene file
      4) For each SKU found by exact name, apply each quartz finish
      5) Render mapped cameras for the SKU size group
      6) Save JPG renders to: R:\Aidan\IPS\<SKU>\
         Filename format: <SKU>_<FINISH>_IPS##.jpg
      7) Continue through all scene files (skip safely on failures)

    NOTE:
      - Update SKU/camera mappings below to match production data.
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
    global IPS_SkuToSizeGroup = #(
        #("Q-306",      "S"),
        #("Q-315",      "S"),
        #("QUWS-875",   "L"),
        #("QARWS-740",  "M"),
        #("QAWS-000",   "M"),
        #("QTWS-000",   "L")
    )

    -- Size group -> camera names (render order = IPS01, IPS02, ...)
    global IPS_SizeGroupToCameras = #(
        #("S", #("Corona Camera 001", "Corona Camera 002", "Corona Camera 003", "Corona Camera 004")),
        #("M", #("Corona Camera 001", "Corona Camera 002", "Corona Camera 003", "Corona Camera 004")),
        #("L", #("Corona Camera 001", "Corona Camera 002", "Corona Camera 003", "Corona Camera 004"))
    )

    -- Apply quartz material to objects whose names start with these prefixes
    global IPS_TargetNamePrefixes = #("Q", "QA", "QAR", "QU", "QT", "QAWS", "QARWS", "QUWS", "QTWS")

    global IPS_RenderWidth = 2000
    global IPS_RenderHeight = 2000
    global IPS_JpegQuality = 100

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

        append out skuNode
        for c in skuNode.children do append out c

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

    fn renderSkuForFinish sku finishCode cameraNames =
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
            return #(0,0)
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
                totalRenders += renderSkuForFinish sku finishCode cams
            )
        )

        #(totalRenders, finishCount)
    )

    fn collectMaxFilesRecursive rootPath outArr =
    (
        local root = ensureTrailingBackslash rootPath
        if not (doesDirectoryExist root) then return outArr

        local localFiles = getFiles (root + "*.max")
        for f in localFiles do append outArr f

        local subDirs = getDirectories (root + "*")
        for d in subDirs do collectMaxFilesRecursive d outArr

        outArr
    )

    fn promptForSceneRoot =
    (
        local p = getSavePath caption:"Select root folder containing SKU scene files"
        if p == undefined or p == "" then undefined else p
    )

    fn processSceneFile scenePath =
    (
        format "\n=== Opening scene: % ===\n" scenePath

        local loaded = false
        try
        (
            loaded = loadMaxFile scenePath useFileUnits:true quiet:true
        )
        catch
        (
            loaded = false
        )

        if loaded != true then
        (
            format "[WARN] Could not open scene, skipped: %\n" scenePath
            return #(0,0,0)
        )

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

        format "[INFO] Scene complete -> SKUs: %, Finishes: %, Renders: %\n" sceneSkuProcessed sceneFinishes sceneRenders
        #(sceneSkuProcessed, sceneFinishes, sceneRenders)
    )

    /* ============================
       Main
       ============================ */

    format "\n=== IPS Multi-Scene Quartz Variant Renderer Started ===\n"

    ensureFolderExists IPS_OutputRoot

    local rootFolder = promptForSceneRoot()
    if rootFolder == undefined then
    (
        messageBox "No folder selected. Script cancelled." title:"IPS Quartz Variant Renderer"
        format "[INFO] Cancelled: no source root selected.\n"
        return false
    )

    local sceneFiles = #()
    collectMaxFilesRecursive rootFolder sceneFiles

    if sceneFiles.count == 0 then
    (
        messageBox ("No .max files found under:\n" + rootFolder) title:"IPS Quartz Variant Renderer"
        format "[WARN] No scene files found under: %\n" rootFolder
        return false
    )

    format "[INFO] Found % scene file(s) under: %\n" sceneFiles.count rootFolder

    local totalScenesProcessed = 0
    local totalSkusProcessed = 0
    local totalFinishesProcessed = 0
    local totalRenders = 0

    for scenePath in sceneFiles do
    (
        local res = processSceneFile scenePath
        if (res[1] + res[2] + res[3]) > 0 do
        (
            totalScenesProcessed += 1
            totalSkusProcessed += res[1]
            totalFinishesProcessed += res[2]
            totalRenders += res[3]
        )
    )

    format "\n=== IPS Multi-Scene Render Completed ===\n"
    format "[INFO] Source scenes with output: %\n" totalScenesProcessed
    format "[INFO] SKUs processed: %\n" totalSkusProcessed
    format "[INFO] Finishes processed: %\n" totalFinishesProcessed
    format "[INFO] JPG renders saved: %\n" totalRenders

    messageBox (
        "IPS multi-scene render job complete.\n\n" +
        "Source scenes with output: " + (totalScenesProcessed as string) + "\n" +
        "SKUs processed: " + (totalSkusProcessed as string) + "\n" +
        "Finishes processed: " + (totalFinishesProcessed as string) + "\n" +
        "JPG renders saved: " + (totalRenders as string)
    ) title:"IPS Quartz Variant Renderer"
)
