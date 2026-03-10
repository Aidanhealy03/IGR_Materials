/*
    IGR PK2 Quartz Workstation Sink Variant + Batch Render Generator
    ---------------------------------------------------------------
    Workflow:
      1) Recursively scan source folder for .max scenes
      2) For each source scene, build finish variants by reassigning materials
      3) Save variant scene file
      4) Update preset Batch Render views (View01 / View02) output paths
      5) Auto-fix view camera + scene state mapping
      6) Auto-sync Corona Slicer cap override on Slice_Sink to current quartz
      7) Submit both views to Backburner (manager: 10.10.0.59)
*/

(
    /* ============================
       User-editable settings
       ============================ */

    -- Material libraries
    global IGR_QuartzLibPath = @"R:\Creative\3D Library\3D Library\Material Library\Quartz.mat"
    global IGR_AccessoryLibPath = @"R:\Creative\3D Library\3D Library\Material Library\Quartz_PK2_Color_Matched_Accessories.mat"
    global IGR_CuttingBoardLibPath = @"R:\Creative\3D Library\3D Library\Material Library\Cuttingboards.mat"

    -- Source + output behavior
    global IGR_SourceRoot = @"C:\Users\AHealy\Desktop\PK2's IGR"
    global IGR_UseOutputRoot = false
    global IGR_OutputRoot = ""

    -- Batch render / Backburner settings
    global IGR_BackburnerManager = "10.10.0.59"
    global IGR_BackburnerPriority = 50
    global IGR_RenderExt = ".jpg"

    -- Render destination search root (recursive)
    global IGR_RenderDestinationRoot = @"V:\KCL_144_FDA_Quartz Workstation PK2s\Deliverables\IGR"

    -- Preset batch view names and required camera/state
    global IGR_View01Name = "View01"
    global IGR_View02Name = "View02"
    global IGR_View01CameraName = "Corona Camera 001"
    global IGR_View02CameraName = "Corona Camera 002"
    global IGR_View01State = "Full_Build"
    global IGR_View02State = "slice"

    -- Task naming
    -- Example: KCL_144_IGR1_FDA_Quartz-Workstation-PK2s_QUWS-875-PK2_WH
    global IGR_TaskNamePrefix = "KCL_144_IGR"
    global IGR_TaskNameMiddle = "_FDA_Quartz-Workstation-PK2s_"

    local buildDefs = #(
        -- #("DisplayName", "Suffix", "SinkQuartzMat", "AccessoryMat", "CuttingBoardMat")
        #("WHITE",    "_WH", "White_Quartz",       "White",    "bamboo"),
        #("BLACK",    "_BL", "Black_Quartz",       "Black",    "acacia IGR"),
        #("CONCRETE", "_CN", "Concrete_Quartz_02", "Concrete", "bamboo"),
        #("BROWN",    "_BR", "Brown_Quartz_02",    "Brown",    "acacia IGR"),
        #("GREY",     "_GR", "Grey_Quartz_02",     "Grey",     "acacia IGR"),
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

    fn ensureFolderExists folderPath = makeDir folderPath all:true

    fn removeFileExtension p =
    (
        getFilenamePath p + getFilenameFile p
    )

    fn forceJpgOutputPath p =
    (
        (removeFileExtension p) + IGR_RenderExt
    )

    fn addSuffixToFilePath p suffix =
    (
        local pathPart = getFilenamePath p
        local basePart = getFilenameFile p
        pathPart + basePart + suffix + IGR_RenderExt
    )

    fn appendNodeUnique nodeArr n =
    (
        if n != undefined and (findItem nodeArr n) == 0 do append nodeArr n
        nodeArr
    )

    fn collectDescendantsRecursive n resultArr =
    (
        appendNodeUnique resultArr n
        for c in n.children do collectDescendantsRecursive c resultArr
        resultArr
    )

    fn findNodesByNameContains substring =
    (
        local result = #()
        local needle = lowerSafe substring
        for n in objects where (findString (lowerSafe n.name) needle) != undefined do append result n
        result
    )

    fn findHierarchyNodesByNameContains substring =
    (
        local directMatches = findNodesByNameContains substring
        local expanded = #()
        for n in directMatches do collectDescendantsRecursive n expanded
        expanded
    )

    fn removeNodesByReference sourceArr removeArr =
    (
        local out = #()
        for n in sourceArr where (findItem removeArr n) == 0 do append out n
        out
    )

    fn loadTempLibraryOrThrow libPath label =
    (
        if libPath == undefined or libPath == "" do throw (label + " path is empty.")
        if not (doesFileExist libPath) do throw (label + " library file not found: " + libPath)

        local lib = loadTempMaterialLibrary libPath
        if lib == undefined do throw ("Failed to load " + label + " library: " + libPath)
        lib
    )

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

        local assignedCount = 0
        for n in nodeArr do
        (
            if isProperty n #material then
            (
                n.material = matToAssign
                assignedCount += 1
            )
        )

        format "[INFO] Assigned '%' to % object(s) in category '%'.\n" matToAssign.name assignedCount categoryName
        true
    )

    fn isGeneratedVariantSourceFile filePath =
    (
        local baseName = toUpper (getFilenameFile filePath)
        (matchPattern baseName pattern:"*_WH") or
        (matchPattern baseName pattern:"*_BL") or
        (matchPattern baseName pattern:"*_CN") or
        (matchPattern baseName pattern:"*_BR") or
        (matchPattern baseName pattern:"*_GR") or
        (matchPattern baseName pattern:"*_BI")
    )

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


    fn collectDirectoriesRecursive rootFolder =
    (
        local pendingDirs = #(ensureTrailingBackslash rootFolder)
        local results = #()

        while pendingDirs.count > 0 do
        (
            local currentDir = pendingDirs[pendingDirs.count]
            deleteItem pendingDirs pendingDirs.count

            local childDirs = getDirectories (currentDir + "*")
            for d in childDirs do
            (
                append results d
                append pendingDirs (ensureTrailingBackslash d)
            )
        )

        results
    )

    -- QTWS-875-PK2_BL -> QTWS-875-PK2BL
    fn buildDeliveryFolderToken variantScenePath =
    (
        local baseName = getFilenameFile variantScenePath
        if baseName.count > 3 and (substring baseName (baseName.count - 2) 1) == "_" then
        (
            local left = substring baseName 1 (baseName.count - 3)
            local right = substring baseName (baseName.count - 1) 2
            left + right
        )
        else baseName
    )

    fn findFirstMatchingDeliveryFolder variantScenePath =
    (
        if IGR_RenderDestinationRoot == undefined or IGR_RenderDestinationRoot == "" then return undefined

        local targetToken = lowerSafe (buildDeliveryFolderToken variantScenePath)
        local dirs = collectDirectoriesRecursive IGR_RenderDestinationRoot

        for d in dirs do
        (
            if (lowerSafe (filenameFromPath d)) == targetToken do return (ensureTrailingBackslash d)
        )
        undefined
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

    fn buildFallbackRenderPath variantScenePath viewName suffix sourceRoot =
    (
        local sceneDir = getFilenamePath variantScenePath
        local relPath = ""
        local srcRootNorm = ensureTrailingBackslash sourceRoot
        local sceneDirNorm = ensureTrailingBackslash sceneDir

        if pathStartsWith sceneDirNorm srcRootNorm then
        (
            local relLen = sceneDirNorm.count - srcRootNorm.count
            if relLen > 0 then relPath = substring sceneDirNorm (srcRootNorm.count + 1) relLen
        )

        local miscRoot = ensureTrailingBackslash sourceRoot + "generated\\misc\\"
        local outDir = miscRoot + relPath
        ensureFolderExists outDir

        local baseScene = getFilenameFile variantScenePath
        outDir + baseScene + "_" + viewName + suffix + IGR_RenderExt
    )

    fn getNodeByExactName nName =
    (
        local found = getNodeByName nName exact:true
        if found == undefined then found = getNodeByName nName
        found
    )

    fn setPropertyIfExists obj propName propValue =
    (
        if obj != undefined and isProperty obj propName then
        (
            setProperty obj propName propValue
            true
        )
        else false
    )

    fn setFirstExistingProperty obj propNames propValue =
    (
        for p in propNames do
        (
            if setPropertyIfExists obj p propValue then return true
        )
        false
    )

    fn getFirstExistingProperty obj propNames =
    (
        for p in propNames do
        (
            if isProperty obj p do return (getProperty obj p)
        )
        undefined
    )

    fn getBatchViewByName targetName =
    (
        if batchRenderMgr == undefined then return undefined
        for i = 1 to batchRenderMgr.numViews do
        (
            local v = batchRenderMgr.getView i
            local vn = getFirstExistingProperty v #(#name,#viewName)
            if vn != undefined and (lowerSafe vn) == (lowerSafe targetName) do return v
        )
        undefined
    )

    fn setBatchViewOutput v outputPath =
    (
        local ok = setFirstExistingProperty v #(#outputFilename,#outputFile,#fileName,#filename) outputPath
        if not ok do format "[WARN] Could not set output path on batch view '%'.\n" (getFirstExistingProperty v #(#name,#viewName))
        ok
    )

    fn setBatchViewCameraAndState v camNode stateName =
    (
        if camNode != undefined do
        (
            local camSet = setFirstExistingProperty v #(#camera,#cameraNode,#viewNode) camNode
            if not camSet do format "[WARN] Could not force camera on view '%'.\n" (getFirstExistingProperty v #(#name,#viewName))
        )

        local stSet = setFirstExistingProperty v #(#sceneStateName,#sceneState) stateName
        if not stSet do format "[WARN] Could not force scene state on view '%'.\n" (getFirstExistingProperty v #(#name,#viewName))
    )

    fn setBackburnerTaskInfo v taskName managerIP priority =
    (
        -- Different 3ds Max/renderer versions expose different property names.
        setFirstExistingProperty v #(#netRender,#networkRender,#submitToNetwork) true
        setFirstExistingProperty v #(#managerName,#manager,#managerIP) managerIP
        setFirstExistingProperty v #(#jobName,#taskName,#nameOverride) taskName
        setFirstExistingProperty v #(#priority,#jobPriority) priority
    )


    fn prepareBackburnerSilentSession managerIP priority =
    (
        local ok = true

        -- Set as many known network-render properties as possible without UI.
        try (if isProperty netrender #manager do netrender.manager = managerIP) catch(ok = false)
        try (if isProperty netrender #managername do netrender.managername = managerIP) catch(ok = false)
        try (if isProperty netrender #priority do netrender.priority = priority) catch()
        try (if isProperty netrender #jobPriority do netrender.jobPriority = priority) catch()

        -- Common dialog-suppression/autoconnect flags (availability varies by Max version).
        try (if isProperty netrender #autoConnect do netrender.autoConnect = true) catch()
        try (if isProperty netrender #connectAutomatically do netrender.connectAutomatically = true) catch()
        try (if isProperty netrender #showDialog do netrender.showDialog = false) catch()
        try (if isProperty netrender #showJobAssignment do netrender.showJobAssignment = false) catch()
        try (if isProperty netrender #useJobAssignmentDialog do netrender.useJobAssignmentDialog = false) catch()
        try (if isProperty netrender #skipOutputTest do netrender.skipOutputTest = true) catch()
        try (if isProperty netrender #silentMode do netrender.silentMode = true) catch()

        -- Best-effort explicit manager connection before submission.
        try (netrender.connect managerIP) catch()

        ok
    )

    fn restoreSceneStateByName stName =
    (
        local ok = false
        try (sceneStateMgr.RestoreState stName; ok = true) catch()
        try (if not ok do (sceneStateMgr.restoreState stName; ok = true)) catch()
        ok
    )

    fn updateCoronaSlicerCapOverride quartzMat =
    (
        local sliceNode = getNodeByExactName "Slice_Sink"
        if sliceNode == undefined then
        (
            format "[WARN] Slice_Sink node not found; slicer cap override sync skipped.\n"
            return false
        )

        local m = sliceNode.material
        if m == undefined then
        (
            format "[WARN] Slice_Sink has no material; slicer cap override sync skipped.\n"
            return false
        )

        local classLower = lowerSafe (classOf m)
        if (findString classLower "slicer") == undefined then
        (
            format "[WARN] Slice_Sink material '%' is not a slicer material class.\n" (classOf m)
        )

        local setOK = false
        setOK = setOK or (setPropertyIfExists m #overrideCapMtl quartzMat)
        setOK = setOK or (setPropertyIfExists m #capMaterial quartzMat)
        setOK = setOK or (setPropertyIfExists m #capMtl quartzMat)
        setOK = setOK or (setPropertyIfExists m #override_cap_material quartzMat)

        if setOK then
            format "[INFO] Synced Slice_Sink slicer cap override to quartz material '%'.\n" quartzMat.name
        else
            format "[WARN] Could not find slicer cap-override property on Slice_Sink material.\n"

        setOK
    )

    fn getOrBuildOutputForView viewObj fallbackVariantPath viewName suffix sourceRoot =
    (
        local currentOut = getFirstExistingProperty viewObj #(#outputFilename,#outputFile,#fileName,#filename)
        local targetFolder = findFirstMatchingDeliveryFolder fallbackVariantPath

        local baseNameNoSuffix = undefined
        if currentOut != undefined and currentOut != "" then baseNameNoSuffix = getFilenameFile currentOut
        if baseNameNoSuffix == undefined or baseNameNoSuffix == "" then baseNameNoSuffix = getFilenameFile fallbackVariantPath

        -- No explicit view suffix injection; keep base naming source, only add finish suffix.
        local finalFileName = baseNameNoSuffix + suffix + IGR_RenderExt

        if targetFolder != undefined then
        (
            targetFolder + finalFileName
        )
        else if currentOut == undefined or currentOut == "" then
        (
            buildFallbackRenderPath fallbackVariantPath viewName suffix sourceRoot
        )
        else
        (
            (getFilenamePath currentOut) + finalFileName
        )
    )

    fn buildTaskName sceneBase suffix igrIndex =
    (
        IGR_TaskNamePrefix + (igrIndex as string) + IGR_TaskNameMiddle + sceneBase + suffix
    )

    fn submitBatchRenderViews variantScenePath suffix sourceRoot =
    (
        local ok = true

        if batchRenderMgr == undefined then
        (
            format "[ERROR] batchRenderMgr is unavailable in this 3ds Max session.\n"
            return false
        )

        local view1 = getBatchViewByName IGR_View01Name
        local view2 = getBatchViewByName IGR_View02Name

        if view1 == undefined then (format "[ERROR] Batch view '%' not found.\n" IGR_View01Name; ok = false)
        if view2 == undefined then (format "[ERROR] Batch view '%' not found.\n" IGR_View02Name; ok = false)
        if not ok then return false

        local cam1 = getNodeByExactName IGR_View01CameraName
        local cam2 = getNodeByExactName IGR_View02CameraName

        if cam1 == undefined then format "[WARN] Camera '%' not found.\n" IGR_View01CameraName
        if cam2 == undefined then format "[WARN] Camera '%' not found.\n" IGR_View02CameraName

        setBatchViewCameraAndState view1 cam1 IGR_View01State
        setBatchViewCameraAndState view2 cam2 IGR_View02State

        -- Also restore scene states now to ensure any dependent render state is valid.
        if not (restoreSceneStateByName IGR_View01State) do format "[WARN] Could not restore scene state '%'.\n" IGR_View01State
        if not (restoreSceneStateByName IGR_View02State) do format "[WARN] Could not restore scene state '%'.\n" IGR_View02State

        local out1 = getOrBuildOutputForView view1 variantScenePath IGR_View01Name suffix sourceRoot
        local out2 = getOrBuildOutputForView view2 variantScenePath IGR_View02Name suffix sourceRoot

        out1 = forceJpgOutputPath out1
        out2 = forceJpgOutputPath out2

        ensureFolderExists (getFilenamePath out1)
        ensureFolderExists (getFilenamePath out2)

        setBatchViewOutput view1 out1
        setBatchViewOutput view2 out2

        local sceneBase = getFilenameFile variantScenePath
        local task1 = buildTaskName sceneBase "" 1
        local task2 = buildTaskName sceneBase "" 2

        setBackburnerTaskInfo view1 task1 IGR_BackburnerManager IGR_BackburnerPriority
        setBackburnerTaskInfo view2 task2 IGR_BackburnerManager IGR_BackburnerPriority

        -- Global backburner settings best-effort (silences assignment dialogs where supported)
        prepareBackburnerSilentSession IGR_BackburnerManager IGR_BackburnerPriority

        format "[INFO] View01 output: %\n" out1
        format "[INFO] View02 output: %\n" out2
        format "[INFO] Submitting Backburner tasks: '%' and '%'.\n" task1 task2

        local submitOK = true
        try (batchRenderMgr.netRender = true) catch()
        try (batchRenderMgr.render()) catch (submitOK = false)

        if submitOK then
            format "[SUCCESS] Batch render submitted to Backburner without manual assignment (if supported by this Max/Backburner build).\n"
        else
            format "[ERROR] Failed to submit batch render to Backburner.\n"

        submitOK
    )

    fn processOneScene sourceFile quartzLib accessoryLib cbLib outputRoot sourceRoot buildDefs =
    (
        format "\n==================================================\n"
        format "[SCENE] Processing: %\n" sourceFile

        local loaded = loadMaxFile sourceFile quiet:true useFileUnits:true
        if not loaded then
        (
            format "[ERROR] Could not load scene: %\n" sourceFile
            return #(0,1,0,0) -- #(saved, failed, skipped, submitted)
        )

        local sinkNodes = findHierarchyNodesByNameContains "PK2"
        local drainNodes = findHierarchyNodesByNameContains "QBS"
        local colanderNodes = findHierarchyNodesByNameContains "COL"
        local dryingRackNodes = findHierarchyNodesByNameContains "DR"
        local cuttingBoardNodes = findHierarchyNodesByNameContains "CB"

        -- Prevent cross-category overwrites when hierarchies overlap
        local quartzTargets = sinkNodes + drainNodes
        local accessoryTargets = colanderNodes + dryingRackNodes
        cuttingBoardNodes = removeNodesByReference cuttingBoardNodes (quartzTargets + accessoryTargets)

        if sinkNodes.count == 0 then
        (
            format "[ERROR] No sink objects found (contains 'PK2'). Scene skipped: %\n" sourceFile
            return #(0,0,1,0)
        )

        if colanderNodes.count == 0 do format "[WARN] No COL objects found in scene.\n"
        if dryingRackNodes.count == 0 do format "[WARN] No DR objects found in scene.\n"
        if cuttingBoardNodes.count == 0 do format "[WARN] No CB objects found in scene.\n"
        if drainNodes.count > 0 do format "[INFO] QBS drain objects found: % (will receive Quartz with PK2).\n" drainNodes.count

        local savedCount = 0
        local failedCount = 0
        local skippedCount = 0
        local submitCount = 0

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
                if drainNodes.count > 0 do assignMaterialToNodes drainNodes sinkMat "Drain (QBS)"
                if colanderNodes.count > 0 do assignMaterialToNodes colanderNodes accessoryMat "Colander (COL)"
                if dryingRackNodes.count > 0 do assignMaterialToNodes dryingRackNodes accessoryMat "Drying Rack (DR)"
                if cuttingBoardNodes.count > 0 do assignMaterialToNodes cuttingBoardNodes cbMat "Cutting Board (CB)"

                updateCoronaSlicerCapOverride sinkMat

                local outPath = buildVariantOutputPath sourceFile outputRoot sourceRoot suffix
                local ok = saveMaxFile outPath clearNeedSaveFlag:true useNewFile:false quiet:true

                if ok then
                (
                    savedCount += 1
                    format "[SUCCESS] Saved: %\n" outPath

                    if submitBatchRenderViews outPath suffix sourceRoot then
                        submitCount += 1
                    else
                        failedCount += 1
                )
                else
                (
                    failedCount += 1
                    format "[ERROR] Failed to save: %\n" outPath
                )
            )
        )

        #(savedCount, failedCount, skippedCount, submitCount)
    )

    /* ============================
       Main
       ============================ */
    format "\n=== IGR PK2 Variant Generator + Batch Render Started ===\n"

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

    format "[INFO] Backburner manager: %\n" IGR_BackburnerManager
    format "[INFO] Backburner priority: %\n" IGR_BackburnerPriority

    local allMaxFiles = collectMaxFilesRecursive sourceRoot
    local sourceFiles = #()
    for f in allMaxFiles where not (isGeneratedVariantSourceFile f) do append sourceFiles f

    if sourceFiles.count == 0 then
    (
        messageBox "No source .max files found in selected folder/subfolders (after excluding generated variants)."
        throw "No source files to process."
    )

    format "[INFO] Source .max files found: %\n" sourceFiles.count

    local totalSaved = 0
    local totalFailed = 0
    local totalSkipped = 0
    local totalSubmitted = 0

    for src in sourceFiles do
    (
        local result = processOneScene src quartzLib accessoryLib cbLib outputRoot sourceRoot buildDefs
        totalSaved += result[1]
        totalFailed += result[2]
        totalSkipped += result[3]
        totalSubmitted += result[4]
    )

    format "\n=== IGR PK2 Variant Generator + Batch Render Completed ===\n"
    format "[INFO] Source scenes processed: %\n" sourceFiles.count
    format "[INFO] Variant files saved: %\n" totalSaved
    format "[INFO] Variant save/render failures: %\n" totalFailed
    format "[INFO] Scene/finish skips: %\n" totalSkipped
    format "[INFO] Backburner submissions: %\n" totalSubmitted

    messageBox (
        "Batch generation/render submission complete.\n\n" +
        "Source scenes processed: " + (sourceFiles.count as string) + "\n" +
        "Variant files saved: " + (totalSaved as string) + "\n" +
        "Variant save/render failures: " + (totalFailed as string) + "\n" +
        "Scene/finish skips: " + (totalSkipped as string) + "\n" +
        "Backburner submissions: " + (totalSubmitted as string)
    ) title:"IGR PK2 Variant Generator + Batch Render"
)
