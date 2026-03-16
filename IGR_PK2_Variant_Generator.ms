/*
    IGR PK2 Quartz Workstation Sink Variant + Batch Render Generator
    ---------------------------------------------------------------
    Workflow:
      1) Recursively scan source folder for .max scenes
      2) For each source scene, build finish variants by reassigning materials
      3) Save variant scene file
      4) Update preset Batch Render View03 output path
      5) Auto-fix view camera + scene state mapping
      6) Auto-sync Corona Slicer cap override on Slice_Sink to current quartz
      7) Submit View03 to Backburner (manager: 10.10.0.59)
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
    global IGR_View03Name = "View03"
    global IGR_View01CameraName = "Corona Camera 001"
    global IGR_View02CameraName = "Corona Camera 002"
    global IGR_View03CameraName = "Corona Camera 001"
    global IGR_View01State = "Full_Build"
    global IGR_View02State = "slice"
    global IGR_View03State = "Empty"

    -- Task naming
    -- Example: KCL_144_IGR1_FDA_Quartz-Workstation-PK2s_QUWS-875-PK2_WH
    global IGR_TaskNamePrefix = "KCL_144_IGR"
    global IGR_TaskNameMiddle = "_FDA_Quartz-Workstation-PK2s_"

    -- Network Job Assignment automation
    global IGR_AutoNetworkDialogTitleToken = "Network Job Assignment"
    global IGR_NetAssignTimer = undefined
    global IGR_NetAssignDesiredJobName = ""
    global IGR_NetAssignDesiredPriority = 50
    global IGR_NetAssignDesiredManager = ""

    global IGR_buildDefs = #(
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

    fn getFinishCodeFromSuffix suffix =
    (
        if suffix != undefined and suffix.count == 3 and (substring suffix 1 1) == "_" then
            (substring suffix 2 2)
        else
            suffix
    )

    fn normalizeBaseNameForFinish baseName suffix =
    (
        local finishCode = getFinishCodeFromSuffix suffix
        local bn = baseName

        if bn == undefined then bn = ""

        -- Strip any trailing finish chain like _WH or _WH_CN_GR_BL before appending target finish.
        -- This prevents duplicated/stacked suffixes across repeated processing passes.
        local rx = dotNetObject "System.Text.RegularExpressions.Regex" "(?:_[A-Za-z]{2})+$"
        bn = rx.Replace bn ""

        if bn == "" then bn = "VARIANT"

        bn + "_" + finishCode
    )

    fn addSuffixToFilePath p suffix =
    (
        local pathPart = getFilenamePath p
        local basePart = normalizeBaseNameForFinish (getFilenameFile p) suffix
        pathPart + basePart + IGR_RenderExt
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
    fn extractSkuFromName baseName =
    (
        local sku = ""
        local rx = dotNetObject "System.Text.RegularExpressions.Regex" "([A-Za-z]+-[0-9]+)"
        local m = rx.Match baseName
        if m.Success then
            sku = m.Groups.Item[1].Value
        else
        (
            local parts = filterString baseName "_"
            if parts.count > 0 then sku = parts[1] else sku = baseName
        )
        sku
    )

    -- Find first folder under delivery root where folder name contains SKU and ends with finish code (no underscore)
    fn findFirstMatchingDeliveryFolder variantScenePath suffix =
    (
        if IGR_RenderDestinationRoot == undefined or IGR_RenderDestinationRoot == "" then return undefined

        local sceneBase = getFilenameFile variantScenePath
        local sku = lowerSafe (extractSkuFromName sceneBase)
        local finishCode = lowerSafe (getFinishCodeFromSuffix suffix)

        local dirs = collectDirectoriesRecursive IGR_RenderDestinationRoot
        for d in dirs do
        (
            local dn = lowerSafe (filenameFromPath d)
            if (findString dn sku) != undefined and dn.count >= 2 and (substring dn (dn.count - 1) 2) == finishCode do
                return (ensureTrailingBackslash d)
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

        local sceneBase = normalizeBaseNameForFinish baseName suffix
        pathConfig.appendPath outDir (sceneBase + ".max")
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
        local targetFolder = findFirstMatchingDeliveryFolder fallbackVariantPath suffix

        -- Always key output filename from variant scene name so material ID/suffix is always correct.
        -- Final filename always ENDS with finish code (e.g. _WH / _BL).
        local baseNameNoSuffix = getFilenameFile fallbackVariantPath
        local finalFileName = (normalizeBaseNameForFinish baseNameNoSuffix suffix) + IGR_RenderExt

        if targetFolder != undefined then
        (
            targetFolder + finalFileName
        )
        else if currentOut != undefined and currentOut != "" then
        (
            (getFilenamePath currentOut) + finalFileName
        )
        else
        (
            -- Keep fallback folder behavior, but force normalized finish-safe filename.
            (getFilenamePath (buildFallbackRenderPath fallbackVariantPath viewName suffix sourceRoot)) + finalFileName
        )
    )

    fn configureNetrenderJobDefaults jobName managerIP priority =
    (
        try (if isProperty netrender #jobName do netrender.jobName = jobName) catch()
        try (if isProperty netrender #jobname do netrender.jobname = jobName) catch()
        try (if isProperty netrender #priority do netrender.priority = priority) catch()
        try (if isProperty netrender #jobPriority do netrender.jobPriority = priority) catch()
        try (if isProperty netrender #manager do netrender.manager = managerIP) catch()
        try (if isProperty netrender #managername do netrender.managername = managerIP) catch()
    )

    fn pressFirstMatchingButton parentHwnd captions =
    (
        for c in captions do
        (
            local ok = false
            try (ok = UIAccessor.PressButtonByName parentHwnd c) catch(ok = false)
            if ok then return true
        )
        false
    )

    fn tryAutomateNetworkJobAssignmentDialog =
    (
        local didAnything = false
        local dialogs = #()
        try (dialogs = UIAccessor.GetPopupDialogs()) catch(dialogs = #())

        for h in dialogs do
        (
            local t = ""
            try (t = UIAccessor.GetWindowText h) catch(t = "")
            if (findString (lowerSafe t) (lowerSafe IGR_AutoNetworkDialogTitleToken)) != undefined then
            (
                didAnything = true
                configureNetrenderJobDefaults IGR_NetAssignDesiredJobName IGR_NetAssignDesiredManager IGR_NetAssignDesiredPriority

                -- Try direct connect first.
                try (netrender.connect IGR_NetAssignDesiredManager) catch()

                -- Then push dialog buttons.
                pressFirstMatchingButton h #("Connect","&Connect")
                pressFirstMatchingButton h #("Submit","&Submit","Submit to Network")
            )
        )

        didAnything
    )

    fn stopNetworkAssignmentTimer =
    (
        try
        (
            if IGR_NetAssignTimer != undefined do
            (
                IGR_NetAssignTimer.Stop()
                dotNet.removeAllEventHandlers IGR_NetAssignTimer "Tick"
                IGR_NetAssignTimer = undefined
            )
        ) catch()
    )

    fn onNetworkAssignmentTimerTick sender args =
    (
        try (tryAutomateNetworkJobAssignmentDialog()) catch()
    )

    fn startNetworkAssignmentTimer jobName managerIP priority =
    (
        stopNetworkAssignmentTimer()
        IGR_NetAssignDesiredJobName = jobName
        IGR_NetAssignDesiredManager = managerIP
        IGR_NetAssignDesiredPriority = priority

        IGR_NetAssignTimer = dotNetObject "System.Windows.Forms.Timer"
        IGR_NetAssignTimer.Interval = 250
        dotNet.addEventHandler IGR_NetAssignTimer "Tick" onNetworkAssignmentTimerTick
        IGR_NetAssignTimer.Start()
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

        -- Only View03 is submitted per latest production requirement.
        local view3 = getBatchViewByName IGR_View03Name
        if view3 == undefined then
        (
            format "[ERROR] Batch view '%' not found.\n" IGR_View03Name
            return false
        )

        local cam3 = getNodeByExactName IGR_View03CameraName
        if cam3 == undefined then format "[WARN] Camera '%' not found.\n" IGR_View03CameraName

        setBatchViewCameraAndState view3 cam3 IGR_View03State
        if not (restoreSceneStateByName IGR_View03State) do format "[WARN] Could not restore scene state '%'.\n" IGR_View03State

        local out3 = getOrBuildOutputForView view3 variantScenePath IGR_View03Name suffix sourceRoot
        out3 = forceJpgOutputPath out3
        ensureFolderExists (getFilenamePath out3)
        setBatchViewOutput view3 out3

        local sceneBase = getFilenameFile variantScenePath
        local task3 = buildTaskName sceneBase "" 3
        setBackburnerTaskInfo view3 task3 IGR_BackburnerManager IGR_BackburnerPriority

        prepareBackburnerSilentSession IGR_BackburnerManager IGR_BackburnerPriority

        format "[INFO] View03 output: %\n" out3
        format "[INFO] Submitting Backburner task: '%'.\n" task3

        local submitOK = true
        local primaryJobName = task3

        configureNetrenderJobDefaults primaryJobName IGR_BackburnerManager IGR_BackburnerPriority
        startNetworkAssignmentTimer primaryJobName IGR_BackburnerManager IGR_BackburnerPriority

        try (batchRenderMgr.netRender = true) catch()
        try (batchRenderMgr.render()) catch (submitOK = false)

        stopNetworkAssignmentTimer()

        if submitOK then
            format "[SUCCESS] View03 batch render submitted to Backburner with auto job-assignment handling.\n"
        else
            format "[ERROR] Failed to submit View03 batch render to Backburner.\n"

        submitOK
    )

    fn processOneScene sourceFile quartzLib accessoryLib cbLib outputRoot sourceRoot =
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
            for def in IGR_buildDefs do
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
       Runner + UI
       ============================ */

    fn validateCurrentSettings =
    (
        local issues = #()

        if IGR_SourceRoot == undefined or IGR_SourceRoot == "" do append issues "Source Root is empty."
        if IGR_QuartzLibPath == undefined or IGR_QuartzLibPath == "" do append issues "Quartz material library path is empty."
        if IGR_AccessoryLibPath == undefined or IGR_AccessoryLibPath == "" do append issues "Accessory material library path is empty."
        if IGR_CuttingBoardLibPath == undefined or IGR_CuttingBoardLibPath == "" do append issues "Cutting board material library path is empty."
        if IGR_RenderDestinationRoot == undefined or IGR_RenderDestinationRoot == "" do append issues "Render destination root is empty."
        if IGR_BackburnerManager == undefined or IGR_BackburnerManager == "" do append issues "Backburner manager is empty."

        if IGR_buildDefs == undefined or IGR_buildDefs.count == 0 then
            append issues "No build definitions configured."

        issues
    )

    fn runIGRGenerator dryRun:false =
    (
        local issues = validateCurrentSettings()
        if issues.count > 0 then
        (
            local msg = "Please fix these settings before running:\n\n"
            for i in issues do msg += ("- " + i + "\n")
            messageBox msg title:"IGR Generator - Validation"
            return false
        )

        format "\n=== IGR PK2 Variant Generator + Batch Render Started ===\n"

        local sourceRoot = ensureTrailingBackslash IGR_SourceRoot

        local outputRoot = ""
        if IGR_UseOutputRoot then
        (
            outputRoot = IGR_OutputRoot
            if outputRoot == "" then
            (
                messageBox "Output Root is required when 'Use Output Root' is enabled."
                return false
            )
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
        format "[INFO] Render destination root: %\n" IGR_RenderDestinationRoot
        format "[INFO] Dry run: %\n" dryRun

        local allMaxFiles = collectMaxFilesRecursive sourceRoot
        local sourceFiles = #()
        for f in allMaxFiles where not (isGeneratedVariantSourceFile f) do append sourceFiles f

        if sourceFiles.count == 0 then
        (
            messageBox "No source .max files found in selected folder/subfolders (after excluding generated variants)."
            return false
        )

        format "[INFO] Source .max files found: %\n" sourceFiles.count

        local totalSaved = 0
        local totalFailed = 0
        local totalSkipped = 0
        local totalSubmitted = 0

        if dryRun then
        (
            messageBox ("Dry Run Complete.\n\nSource scenes that would process: " + (sourceFiles.count as string)) title:"IGR Generator Dry Run"
            return true
        )

        for src in sourceFiles do
        (
            local result = processOneScene src quartzLib accessoryLib cbLib outputRoot sourceRoot
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

        true
    )

    rollout IGR_PK2_Generator_RL "IGR PK2 Variant + Render Generator" width:920 height:900
    (
        groupBox gbPaths "Paths" pos:[8,8] width:904 height:190
        editText etSource "Source Root" pos:[20,32] width:760 text:IGR_SourceRoot
        button btSource "..." pos:[790,30] width:30
        editText etQuartz "Quartz MAT" pos:[20,58] width:760 text:IGR_QuartzLibPath
        button btQuartz "..." pos:[790,56] width:30
        editText etAcc "Accessory MAT" pos:[20,84] width:760 text:IGR_AccessoryLibPath
        button btAcc "..." pos:[790,82] width:30
        editText etCB "Cuttingboard MAT" pos:[20,110] width:760 text:IGR_CuttingBoardLibPath
        button btCB "..." pos:[790,108] width:30
        editText etDest "Render Destination Root" pos:[20,136] width:760 text:IGR_RenderDestinationRoot
        button btDest "..." pos:[790,134] width:30
        checkbox chkOut "Use Output Root" pos:[20,162] checked:IGR_UseOutputRoot
        editText etOut "Output Root" pos:[140,160] width:640 text:IGR_OutputRoot
        button btOut "..." pos:[790,158] width:30

        groupBox gbRender "Render / Backburner" pos:[8,204] width:904 height:122
        editText etMgr "Manager" pos:[20,228] width:200 text:IGR_BackburnerManager
        spinner spPriority "Priority" pos:[240,228] width:120 range:[1,100,IGR_BackburnerPriority]
        editText etExt "Image Ext" pos:[380,228] width:80 text:IGR_RenderExt
        checkbox chkAutoDlg "Automate Network Job Assignment Dialog" pos:[480,230] checked:true

        editText etV3 "View03 Name" pos:[20,258] width:120 text:IGR_View03Name
        editText etV3Cam "View03 Camera" pos:[150,258] width:180 text:IGR_View03CameraName
        editText etV3State "View03 State" pos:[340,258] width:120 text:IGR_View03State
        label lVOnly "Only View03 is submitted by this script." pos:[470,260]

        editText etTaskPre "Task Prefix" pos:[20,288] width:220 text:IGR_TaskNamePrefix
        editText etTaskMid "Task Middle" pos:[250,288] width:640 text:IGR_TaskNameMiddle

        groupBox gbBuilds "Build Definitions (Suffix / Sink Quartz / Accessory / Cuttingboard)" pos:[8,332] width:904 height:436

        label l1 "WHITE" pos:[20,356]
        editText b1s "" pos:[90,352] width:50 text:IGR_buildDefs[1][2]
        editText b1q "" pos:[150,352] width:210 text:IGR_buildDefs[1][3]
        editText b1a "" pos:[370,352] width:210 text:IGR_buildDefs[1][4]
        editText b1c "" pos:[590,352] width:210 text:IGR_buildDefs[1][5]

        label l2 "BLACK" pos:[20,386]
        editText b2s "" pos:[90,382] width:50 text:IGR_buildDefs[2][2]
        editText b2q "" pos:[150,382] width:210 text:IGR_buildDefs[2][3]
        editText b2a "" pos:[370,382] width:210 text:IGR_buildDefs[2][4]
        editText b2c "" pos:[590,382] width:210 text:IGR_buildDefs[2][5]

        label l3 "CONCRETE" pos:[20,416]
        editText b3s "" pos:[90,412] width:50 text:IGR_buildDefs[3][2]
        editText b3q "" pos:[150,412] width:210 text:IGR_buildDefs[3][3]
        editText b3a "" pos:[370,412] width:210 text:IGR_buildDefs[3][4]
        editText b3c "" pos:[590,412] width:210 text:IGR_buildDefs[3][5]

        label l4 "BROWN" pos:[20,446]
        editText b4s "" pos:[90,442] width:50 text:IGR_buildDefs[4][2]
        editText b4q "" pos:[150,442] width:210 text:IGR_buildDefs[4][3]
        editText b4a "" pos:[370,442] width:210 text:IGR_buildDefs[4][4]
        editText b4c "" pos:[590,442] width:210 text:IGR_buildDefs[4][5]

        label l5 "GREY" pos:[20,476]
        editText b5s "" pos:[90,472] width:50 text:IGR_buildDefs[5][2]
        editText b5q "" pos:[150,472] width:210 text:IGR_buildDefs[5][3]
        editText b5a "" pos:[370,472] width:210 text:IGR_buildDefs[5][4]
        editText b5c "" pos:[590,472] width:210 text:IGR_buildDefs[5][5]

        label l6 "BISQUE" pos:[20,506]
        editText b6s "" pos:[90,502] width:50 text:IGR_buildDefs[6][2]
        editText b6q "" pos:[150,502] width:210 text:IGR_buildDefs[6][3]
        editText b6a "" pos:[370,502] width:210 text:IGR_buildDefs[6][4]
        editText b6c "" pos:[590,502] width:210 text:IGR_buildDefs[6][5]

        label hlp "Routing: SKU + finish folder match (finish is last 2 chars of folder name)." pos:[20,540]
        label hlp2 "Network dialog automation attempts Rename/Priority/Connect/Submit automatically." pos:[20,560]

        button btValidate "Validate Settings" pos:[20,790] width:150 height:30
        button btDry "Dry Run" pos:[180,790] width:120 height:30
        button btRun "Run Generator + Submit Renders" pos:[310,790] width:270 height:30
        button btClose "Close" pos:[590,790] width:120 height:30

        fn applyUIToGlobals =
        (
            IGR_SourceRoot = etSource.text
            IGR_QuartzLibPath = etQuartz.text
            IGR_AccessoryLibPath = etAcc.text
            IGR_CuttingBoardLibPath = etCB.text
            IGR_RenderDestinationRoot = etDest.text
            IGR_UseOutputRoot = chkOut.checked
            IGR_OutputRoot = etOut.text

            IGR_BackburnerManager = etMgr.text
            IGR_BackburnerPriority = spPriority.value
            IGR_RenderExt = etExt.text

            IGR_View03Name = etV3.text
            IGR_View03CameraName = etV3Cam.text
            IGR_View03State = etV3State.text

            IGR_TaskNamePrefix = etTaskPre.text
            IGR_TaskNameMiddle = etTaskMid.text

            IGR_buildDefs[1] = #(IGR_buildDefs[1][1], b1s.text, b1q.text, b1a.text, b1c.text)
            IGR_buildDefs[2] = #(IGR_buildDefs[2][1], b2s.text, b2q.text, b2a.text, b2c.text)
            IGR_buildDefs[3] = #(IGR_buildDefs[3][1], b3s.text, b3q.text, b3a.text, b3c.text)
            IGR_buildDefs[4] = #(IGR_buildDefs[4][1], b4s.text, b4q.text, b4a.text, b4c.text)
            IGR_buildDefs[5] = #(IGR_buildDefs[5][1], b5s.text, b5q.text, b5a.text, b5c.text)
            IGR_buildDefs[6] = #(IGR_buildDefs[6][1], b6s.text, b6q.text, b6a.text, b6c.text)

            IGR_AutoNetworkDialogTitleToken = if chkAutoDlg.checked then "Network Job Assignment" else "__DISABLED__"
        )

        on btSource pressed do (local p=getSavePath caption:"Select Source Root" initialDir:IGR_SourceRoot; if p!=undefined do etSource.text=p)
        on btQuartz pressed do (local p=getOpenFileName caption:"Select Quartz MAT" filename:IGR_QuartzLibPath types:"MAT (*.mat)|*.mat|"; if p!=undefined do etQuartz.text=p)
        on btAcc pressed do (local p=getOpenFileName caption:"Select Accessory MAT" filename:IGR_AccessoryLibPath types:"MAT (*.mat)|*.mat|"; if p!=undefined do etAcc.text=p)
        on btCB pressed do (local p=getOpenFileName caption:"Select Cuttingboard MAT" filename:IGR_CuttingBoardLibPath types:"MAT (*.mat)|*.mat|"; if p!=undefined do etCB.text=p)
        on btDest pressed do (local p=getSavePath caption:"Select Render Destination Root" initialDir:IGR_RenderDestinationRoot; if p!=undefined do etDest.text=p)
        on btOut pressed do (local p=getSavePath caption:"Select Output Root" initialDir:IGR_OutputRoot; if p!=undefined do etOut.text=p)

        on btValidate pressed do
        (
            applyUIToGlobals()
            local issues = validateCurrentSettings()
            if issues.count == 0 then messageBox "Validation passed." title:"IGR Generator"
            else
            (
                local msg = "Validation issues:\n\n"
                for i in issues do msg += ("- " + i + "\n")
                messageBox msg title:"IGR Generator"
            )
        )

        on btDry pressed do
        (
            applyUIToGlobals()
            runIGRGenerator dryRun:true
        )

        on btRun pressed do
        (
            applyUIToGlobals()
            runIGRGenerator dryRun:false
        )

        on btClose pressed do destroyDialog IGR_PK2_Generator_RL
    )

    try(destroyDialog IGR_PK2_Generator_RL)catch()
    createDialog IGR_PK2_Generator_RL style:#(#style_titlebar, #style_sysmenu, #style_minimizebox)
)
