/*
    IGR PK2 Quartz Workstation Sink Variant Generator (Batch)
    ----------------------------------------------------------
    Purpose:
      - Traverse a selected folder and all subfolders for .max files
      - Open each source scene
      - Find PK2 sink/accessory objects by name contains rules
      - Assign required materials from fixed .mat libraries
      - Save one .max file per finish variant

    IMPORTANT:
      - Material library paths are hardcoded below so you do NOT have to pick them each run.
      - By default, generated variants save next to each source file.
      - Existing generated variants (_WH/_BL/_CN/_BR/_GR/_BI) are skipped as source files.
*/

(
    /* ============================
       User-editable settings
       ============================ */

    -- Hardcoded material library paths (provided by user)
    global IGR_QuartzLibPath = @"R:\Creative\3D Library\3D Library\Material Library\Quartz.mat"
    global IGR_AccessoryLibPath = @"R:\Creative\3D Library\3D Library\Material Library\Quartz_PK2_Color_Matched_Accessories.mat"
    global IGR_CuttingBoardLibPath = @"R:\Creative\3D Library\3D Library\Material Library\Cuttingboards.mat"

    -- Output behavior:
    -- true  = save variants in a user-picked output root preserving source subfolder structure
    -- false = save variants beside each source file
    global IGR_UseOutputRoot = false
    global IGR_OutputRoot = ""

    -- Source parent folder to scan recursively for .max files
    -- Set to "" to prompt instead.
    global IGR_SourceRoot = @"C:\Users\AHealy\Desktop\PK2's IGR"

    /* ============================
       Build definitions
       ============================ */
    local buildDefs = #(
        -- #("DisplayName", "Suffix", "SinkMat", "AccessoryMat", "CuttingBoardMat")
        #("WHITE",    "_WH", "White_Quartz",       "White",    "bamboo"),
        #("BLACK",    "_BL", "Black_Quartz",       "Black",    "accacia cutting board #3#1"),
        #("CONCRETE", "_CN", "Concrete_Quartz_02", "Concrete", "bamboo"),
        #("BROWN",    "_BR", "Brown_Quartz_02",    "Brown",    "accacia cutting board #3#1"),
        #("GREY",     "_GR", "Grey_Quartz_02",     "Grey",     "accacia cutting board #3#1"),
        #("BISQUE",   "_BI", "Bisque_Quartz_02",   "Bisque",   "bamboo")
    )

    /* ============================
       Helper functions
       ============================ */

    fn lowerSafe s = if s == undefined then "" else toLower (s as string)

    fn ensureTrailingBackslash p =
    (
        if p == undefined or p == "" then "" else
        (
            local lastChar = substring p p.count 1
            if lastChar == "\\" then p else (p + "\\")
        )
    )

    fn pathStartsWith pathFull pathPrefix =
    (
        local full = lowerSafe pathFull
        local pref = lowerSafe pathPrefix
        if pref == "" then false else (substring full 1 pref.count) == pref
    )

    fn ensureFolderExists folderPath =
    (
        local ok = makeDir folderPath all:true
        ok
    )

    -- Returns all scene nodes whose names contain substring (case-insensitive)
    fn findNodesByNameContains substring =
    (
        local result = #()
        local needle = lowerSafe substring
        for n in objects where (findString (lowerSafe n.name) needle) != undefined do append result n
        result
    )

    fn loadTempLibraryOrThrow libPath label =
    (
        if libPath == undefined or libPath == "" do throw (label + " path is empty.")
        if not (doesFileExist libPath) do throw (label + " library file not found: " + libPath)

        local lib = loadTempMaterialLibrary libPath
        if lib == undefined do throw ("Failed to load " + label + " library: " + libPath)
        lib
    )

    -- Finds material by exact name (case-insensitive) from already-loaded library
    fn getMaterialFromLoadedLibrary lib targetMatName =
    (
        local wanted = lowerSafe targetMatName
        for i = 1 to lib.count do
        (
            local m = lib[i]
            if m != undefined and (lowerSafe m.name) == wanted do return (copy m)
        )
        undefined
    )

    fn assignMaterialToNodes nodeArr matToAssign categoryName =
    (
        if nodeArr == undefined or nodeArr.count == 0 then
        (
            format "[WARN] No objects found for category '%'.\n" categoryName
            return false
        )

        if matToAssign == undefined then
        (
            format "[WARN] Missing material for category '%'. Assignment skipped.\n" categoryName
            return false
        )

        for n in nodeArr do n.material = matToAssign
        format "[INFO] Assigned '%' to % object(s) in category '%'.\n" matToAssign.name nodeArr.count categoryName
        true
    )

    fn isGeneratedVariantSourceFile filePath =
    (
        local baseName = getFilenameFile filePath
        local upperName = toUpper baseName
        (matchPattern upperName pattern:"*_WH") or
        (matchPattern upperName pattern:"*_BL") or
        (matchPattern upperName pattern:"*_CN") or
        (matchPattern upperName pattern:"*_BR") or
        (matchPattern upperName pattern:"*_GR") or
        (matchPattern upperName pattern:"*_BI")
    )


    -- Reliable recursive file collection (avoids ** glob compatibility issues)
    fn collectMaxFilesRecursive rootFolder =
    (
        local pendingDirs = #(ensureTrailingBackslash rootFolder)
        local results = #()

        while pendingDirs.count > 0 do
        (
            local currentDir = pendingDirs[pendingDirs.count]
            deleteItem pendingDirs pendingDirs.count

            local currentFiles = getFiles (currentDir + "*.max")
            for f in currentFiles do append results f

            local childDirs = getDirectories (currentDir + "*")
            for d in childDirs do append pendingDirs (ensureTrailingBackslash d)
        )

        results
    )

    fn buildVariantOutputPath sourceFile outputRoot sourceRoot suffix =
    (
        local sourceDir = getFilenamePath sourceFile
        local baseName = getFilenameFile sourceFile
        local outDir = sourceDir

        if outputRoot != undefined and outputRoot != "" and sourceRoot != undefined and sourceRoot != "" then
        (
            local srcRootNorm = ensureTrailingBackslash sourceRoot
            local srcDirNorm = ensureTrailingBackslash sourceDir
            local relPath = ""

            if pathStartsWith srcDirNorm srcRootNorm then
            (
                local relLen = srcDirNorm.count - srcRootNorm.count
                if relLen > 0 then relPath = substring srcDirNorm (srcRootNorm.count + 1) relLen
            )

            outDir = ensureTrailingBackslash outputRoot + relPath
            ensureFolderExists outDir
        )

        pathConfig.appendPath outDir (baseName + suffix + ".max")
    )

    fn processOneScene sourceFile quartzLib accessoryLib cbLib outputRoot sourceRoot buildDefs =
    (
        format "\n==================================================\n"
        format "[SCENE] Processing: %\n" sourceFile

        local loaded = loadMaxFile sourceFile quiet:true useFileUnits:true
        if not loaded then
        (
            format "[ERROR] Could not load scene: %\n" sourceFile
            return #(0,1,0) -- #(saved, failed, skipped)
        )

        local sinkNodes = findNodesByNameContains "PK2"
        local drainNodes = findNodesByNameContains "QBS"
        local colanderNodes = findNodesByNameContains "COL"
        local dryingRackNodes = findNodesByNameContains "DR"
        local cuttingBoardNodes = findNodesByNameContains "CB"

        if sinkNodes.count == 0 then
        (
            format "[ERROR] No sink objects found (contains 'PK2'). Scene skipped: %\n" sourceFile
            return #(0,0,1)
        )

        if colanderNodes.count == 0 do format "[WARN] No COL objects found in scene.\n"
        if dryingRackNodes.count == 0 do format "[WARN] No DR objects found in scene.\n"
        if cuttingBoardNodes.count == 0 do format "[WARN] No CB objects found in scene.\n"
        if drainNodes.count > 0 do format "[INFO] QBS drain objects found: % (left unchanged).\n" drainNodes.count

        local savedCount = 0
        local failedCount = 0
        local skippedCount = 0

        with undo off
        (
            for def in buildDefs do
            (
                local finishName = def[1]
                local suffix = def[2]
                local sinkMatName = def[3]
                local accessoryMatName = def[4]
                local cbMatName = def[5]

                format "\n--- Finish: % ---\n" finishName

                local sinkMat = getMaterialFromLoadedLibrary quartzLib sinkMatName
                local accessoryMat = getMaterialFromLoadedLibrary accessoryLib accessoryMatName
                local cbMat = getMaterialFromLoadedLibrary cbLib cbMatName

                if sinkMat == undefined then
                (
                    format "[ERROR] Missing required sink material '%' in Quartz library. Skipping this finish.\n" sinkMatName
                    skippedCount += 1
                    continue
                )

                assignMaterialToNodes sinkNodes sinkMat "Sink (PK2)"
                if colanderNodes.count > 0 do assignMaterialToNodes colanderNodes accessoryMat "Colander (COL)"
                if dryingRackNodes.count > 0 do assignMaterialToNodes dryingRackNodes accessoryMat "Drying Rack (DR)"
                if cuttingBoardNodes.count > 0 do assignMaterialToNodes cuttingBoardNodes cbMat "Cutting Board (CB)"

                local outPath = buildVariantOutputPath sourceFile outputRoot sourceRoot suffix
                local ok = saveMaxFile outPath clearNeedSaveFlag:true useNewFile:false quiet:true

                if ok then
                (
                    savedCount += 1
                    format "[SUCCESS] Saved: %\n" outPath
                )
                else
                (
                    failedCount += 1
                    format "[ERROR] Failed to save: %\n" outPath
                )
            )
        )

        #(savedCount, failedCount, skippedCount)
    )

    /* ============================
       Main
       ============================ */
    format "\n=== IGR PK2 Variant Generator (Batch) Started ===\n"

    local sourceRoot = IGR_SourceRoot
    if sourceRoot == undefined or sourceRoot == "" then
    (
        sourceRoot = getSavePath caption:"Select SOURCE folder (script will scan subfolders for .max files)"
        if sourceRoot == undefined do throw "User canceled source folder selection."
    )

    sourceRoot = ensureTrailingBackslash sourceRoot

    local outputRoot = ""
    if IGR_UseOutputRoot then
    (
        outputRoot = IGR_OutputRoot
        if outputRoot == "" then outputRoot = getSavePath caption:"Select OUTPUT root folder"
        if outputRoot == undefined or outputRoot == "" do throw "Output root is required when IGR_UseOutputRoot = true."
        outputRoot = ensureTrailingBackslash outputRoot
        ensureFolderExists outputRoot
    )

    local quartzLib = loadTempLibraryOrThrow IGR_QuartzLibPath "Quartz"
    local accessoryLib = loadTempLibraryOrThrow IGR_AccessoryLibPath "Accessory"
    local cbLib = loadTempLibraryOrThrow IGR_CuttingBoardLibPath "Cutting Board"

    format "[INFO] Source root: %\n" sourceRoot
    if outputRoot == "" then
        format "[INFO] Output mode: Save beside source files.\n"
    else
        format "[INFO] Output root: %\n" outputRoot

    format "[INFO] Quartz library: %\n" IGR_QuartzLibPath
    format "[INFO] Accessory library: %\n" IGR_AccessoryLibPath
    format "[INFO] Cutting board library: %\n" IGR_CuttingBoardLibPath

    local allMaxFiles = collectMaxFilesRecursive sourceRoot
    local sourceFiles = #()

    for f in allMaxFiles do
    (
        if not (isGeneratedVariantSourceFile f) do append sourceFiles f
    )

    if sourceFiles.count == 0 then
    (
        messageBox "No source .max files found in selected folder/subfolders (after excluding generated variants)."
        throw "No source files to process."
    )

    format "[INFO] Source .max files found: %\n" sourceFiles.count

    local totalSaved = 0
    local totalFailed = 0
    local totalSkipped = 0

    for src in sourceFiles do
    (
        local result = processOneScene src quartzLib accessoryLib cbLib outputRoot sourceRoot buildDefs
        totalSaved += result[1]
        totalFailed += result[2]
        totalSkipped += result[3]
    )

    format "\n=== IGR PK2 Variant Generator (Batch) Completed ===\n"
    format "[INFO] Source scenes processed: %\n" sourceFiles.count
    format "[INFO] Variant files saved: %\n" totalSaved
    format "[INFO] Variant save failures: %\n" totalFailed
    format "[INFO] Scene/finish skips: %\n" totalSkipped

    messageBox (
        "Batch generation complete.\n\n" +
        "Source scenes processed: " + (sourceFiles.count as string) + "\n" +
        "Variant files saved: " + (totalSaved as string) + "\n" +
        "Variant save failures: " + (totalFailed as string) + "\n" +
        "Scene/finish skips: " + (totalSkipped as string)
    ) title:"IGR PK2 Variant Generator (Batch)"
)
