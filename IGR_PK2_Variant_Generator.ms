/*
    IGR Quartz Sink Backburner Submission (Multi-Scene)
    ----------------------------------------------------
    Workflow:
      1) Prompt for source root folder
      2) Recursively find and open .max scene files
      3) For each mapped SKU found in each scene, apply quartz finishes
      4) For each camera, restore scene state (empty except Camera002 -> Slice)
      5) Save temp scene snapshot and submit render to Backburner via 3dsmaxcmd

    Render output:
      R:\Aidan\IGR\<SKU>\<SKU>_<FINISH>_IGR##.jpg
*/

(
    /* =========================
       USER SETTINGS
       ========================= */
    global OUTPUT_ROOT        = @"R:\Aidan\IGR"
    global QUARTZ_MATLIB      = @"R:\Creative\3D Library\3D Library\Material Library\Quartz.mat"
    global RENDER_WIDTH       = 2000
    global RENDER_HEIGHT      = 2000
    global BACKBURNER_MANAGER = "10.10.0.62"
    global BACKBURNER_PORT    = 3234
    global TEMP_SCENE_FOLDER  = @"R:\Aidan\IGR\_TempScenes"
    global DRY_RUN            = false
    global SUBMISSION_STABILIZE_MS = 250
    global JOB_PRIORITY       = 50
    global MAXCMD_EXE         = (getDir #maxroot) + "3dsmaxcmd.exe"

    global IGR_CAMERA_RENDER_PLAN = #(
        #("Corona Camera001", "Empty"), -- Image 01
        #("Corona Camera002", "Slice")  -- Image 02
    )

    global FINISHES = #(
        #("WH", "White_Quartz"),
        #("BL", "Black_Quartz"),
        #("CN", "Concrete_Quartz_02"),
        #("BR", "Brown_Quartz_02"),
        #("GR", "Grey_Quartz_02"),
        #("BI", "Bisque_Quartz_02")
    )

    global SKU_LIST = #(
        "Q-306",
        "Q-315",
        "QUWS-875",
        "QARWS-740",
        "QAWS-000",
        "QTWS-000"
    )

    global VALID_SINK_PREFIXES = #( "QARWS", "QAWS", "QUWS", "QTWS", "QAR", "QA", "QU", "QT", "Q" )
    global IGR_LogFilePath = undefined

    /* =========================
       LOGGING + HELPERS
       ========================= */
    fn igrTimeStamp = (localTime as string)

    fn safeMakeDir p =
    (
        if p == undefined or p == "" then return false
        if doesDirectoryExist p then return true
        makeDir p all:true
    )

    fn initLog =
    (
        if safeMakeDir OUTPUT_ROOT then
        (
            local stamp = substituteString (substituteString (substituteString (igrTimeStamp()) "/" "-") ":" "-") " " "_"
            IGR_LogFilePath = OUTPUT_ROOT + "\\IGR_Backburner_Log_" + stamp + ".txt"
            try
            (
                local f = createFile IGR_LogFilePath
                format "IGR Quartz Backburner Log\n" to:f
                close f
            ) catch (IGR_LogFilePath = undefined)
        )
    )

    fn logLine msg =
    (
        local line = "[" + igrTimeStamp() + "] " + msg
        format "%\n" line
        if IGR_LogFilePath != undefined then
        (
            try
            (
                local f = openFile IGR_LogFilePath mode:"a"
                format "%\n" line to:f
                close f
            ) catch()
        )
    )

    fn startsWithAny source prefixes =
    (
        if source == undefined then return false
        local upperName = toUpper source
        for p in prefixes do
        (
            if matchPattern upperName pattern:((toUpper p) + "*") ignoreCase:true do return true
        )
        false
    )

    fn isSinkNodeName nodeName = startsWithAny nodeName VALID_SINK_PREFIXES

    fn collectHierarchyWalk n outRef =
    (
        if n == undefined or (not isValidNode n) then return undefined
        append outRef n
        for c in n.children do collectHierarchyWalk c outRef
    )

    fn collectHierarchy n =
    (
        local out = #()
        collectHierarchyWalk n out
        out
    )

    fn collectTargetNodesForSku skuNode =
    (
        local out = collectHierarchy skuNode
        for o in objects where (isValidNode o and isSinkNodeName o.name) do
        (
            if (findItem out o) == 0 do append out o
        )
        out
    )

    fn collectBasketStrainerNodes =
    (
        local out = #()
        for o in objects where (isValidNode o and (matchPattern (toLower o.name) pattern:"*basket strainer*" ignoreCase:true)) do
        (
            local branch = collectHierarchy o
            for n in branch do
            (
                if (findItem out n) == 0 do append out n
            )
        )
        out
    )

    fn selectSkuAndChildren skuNode =
    (
        local nodes = collectHierarchy skuNode
        try (select nodes) catch()
        nodes
    )

    fn selectBasketStrainersAndChildren =
    (
        local nodes = collectBasketStrainerNodes()
        if nodes.count > 0 do try (selectMore nodes) catch()
        nodes
    )

    fn combineUniqueNodes arrA arrB =
    (
        local out = #()
        for n in arrA do if (findItem out n) == 0 do append out n
        for n in arrB do if (findItem out n) == 0 do append out n
        out
    )

    fn getNodeByExactName n = getNodeByName n exact:true ignoreCase:false

    fn loadQuartzMaterialByName matName =
    (
        if not doesFileExist QUARTZ_MATLIB then return undefined
        local ml = undefined
        try (ml = loadTempMaterialLibrary QUARTZ_MATLIB) catch (ml = undefined)
        if ml == undefined then return undefined

        for i = 1 to ml.count do
        (
            local m = ml[i]
            if m != undefined and (toUpper m.name == toUpper matName) then return (copy m)
        )
        undefined
    )

    fn buildOutputFilePath sku finishCode igrIndex =
    (
        local idxStr = formattedPrint igrIndex format:"02d"
        local fileName = sku + "_" + finishCode + "_IGR" + idxStr + ".jpg"
        OUTPUT_ROOT + "\\" + sku + "\\" + fileName
    )

    fn ensureSkuOutputFolder sku = safeMakeDir (OUTPUT_ROOT + "\\" + sku)
    fn ensureTempFolder = safeMakeDir TEMP_SCENE_FOLDER

    fn buildTempScenePath token = (TEMP_SCENE_FOLDER + "\\" + token + ".max")

    fn saveTempSceneSnapshot tempScenePath =
    (
        if DRY_RUN then return true
        local saved = saveMaxFile tempScenePath clearNeedSaveFlag:true useNewFile:false quiet:true
        if saved then doesFileExist tempScenePath else false
    )

    fn restoreSceneStateBestEffort stateName =
    (
        local ok = false
        local errText = ""
        if stateName == undefined or stateName == "" then return false

        local sceneStateCount = 0
        try (sceneStateCount = sceneStateMgr.GetCount()) catch (sceneStateCount = 0)
        logLine ("SceneState restore request: '" + stateName + "' | total states in scene: " + (sceneStateCount as string))

        if sceneStateCount < 1 then
        (
            logLine "ERROR: No scene states are present in this scene."
            return false
        )

        local stateIndex = -1
        try (stateIndex = sceneStateMgr.FindSceneState stateName) catch (stateIndex = -1)
        if stateIndex < 1 then
        (
            logLine ("ERROR: Scene state not found by exact name: '" + stateName + "'")
            local available = ""
            for i = 1 to sceneStateCount do
            (
                local n = ""
                try (n = sceneStateMgr.GetSceneState i) catch (n = "")
                available += n
                if i < sceneStateCount do available += ", "
            )
            logLine ("INFO: Available scene states: " + available)
            return false
        )

        -- Build a broad 'all parts' bitarray for SceneStateMgr.Restore().
        local parts = bitArray 64
        for i = 1 to parts.count do parts[i] = true

        -- Preferred MAXScript API from Autodesk docs:
        -- sceneStateMgr.Restore <string>name <bitArray>parts
        try
        (
            ok = sceneStateMgr.Restore stateName parts
            logLine ("SceneStateMgr.Restore('" + stateName + "') returned: " + (ok as string))
        )
        catch
        (
            errText = (getCurrentException() as string)
            logLine ("ERROR: sceneStateMgr.Restore failed for '" + stateName + "' | " + errText)
        )

        -- Legacy fallback for scenes/plugins exposing sceneStates struct.
        if (not ok) do
        (
            try
            (
                sceneStates.restore stateName
                ok = true
                logLine ("Fallback sceneStates.restore('" + stateName + "') succeeded.")
            )
            catch
            (
                errText = (getCurrentException() as string)
                logLine ("ERROR: sceneStates.restore failed for '" + stateName + "' | " + errText)
            )
        )

        if not ok then logLine ("WARN: Failed to restore scene state: " + stateName)
        ok
    )

    fn submitViaMaxCmd scenePath jobName cameraName outputPath width height =
    (
        if DRY_RUN then return true

        if not doesFileExist MAXCMD_EXE then
        (
            logLine ("ERROR: 3dsmaxcmd.exe not found at: " + MAXCMD_EXE)
            return false
        )

        local cmd = "\"" + MAXCMD_EXE + "\"" + \
            " -submit:" + BACKBURNER_MANAGER + \
            " -port:" + (BACKBURNER_PORT as string) + \
            " -jobName:\"" + jobName + "\"" + \
            " -priority:" + (JOB_PRIORITY as string) + \
            " -camera:\"" + cameraName + "\"" + \
            " -outputName:\"" + outputPath + "\"" + \
            " -stillFrame" + \
            " -w:" + (width as string) + \
            " -h:" + (height as string) + \
            " \"" + scenePath + "\""

        local batFile = TEMP_SCENE_FOLDER + "\\_igr_submit.bat"
        local outFile = TEMP_SCENE_FOLDER + "\\_igr_submit_out.txt"

        try
        (
            local bf = createFile batFile
            format "@echo off\n" to:bf
            format "% > \"%\" 2>&1\n" cmd outFile to:bf
            close bf
        )
        catch
        (
            logLine ("ERROR: Could not write temp bat file: " + batFile)
            return false
        )

        local rc = undefined
        try (rc = DOSCommand batFile) catch (rc = undefined)

        if doesFileExist outFile then
        (
            try
            (
                local lf = openFile outFile mode:"r"
                while not (eof lf) do
                (
                    local line = readLine lf
                    if line != "" do logLine ("  [3dsmaxcmd] " + line)
                )
                close lf
            ) catch()
        )

        if rc == undefined then
        (
            logLine "ERROR: 3dsmaxcmd launch failed (DOSCommand undefined)."
            return false
        )

        (rc == 0 or rc == true)
    )

    fn collectMaxFilesRecursive rootPath outArr =
    (
        local root = rootPath
        if (substring root root.count 1) != "\\" do root += "\\"
        if not (doesDirectoryExist root) then return outArr

        for f in (getFiles (root + "*.max")) do append outArr f
        for d in (getDirectories (root + "*")) do collectMaxFilesRecursive d outArr
        outArr
    )

    fn promptForSceneRoot =
    (
        local p = getSavePath caption:"Select root folder containing SKU scene files"
        if p == undefined or p == "" then undefined else p
    )

    fn applyMaterialToNodes nodeList matObj =
    (
        local assigned = 0
        for n in nodeList where (isValidNode n and isKindOf n GeometryClass) do
        (
            try
            (
                n.material = matObj
                assigned += 1
            ) catch()
        )
        assigned
    )

    fn applyQuartzToOverrideCapMaterial quartzMat =
    (
        local matched = 0
        local updated = 0

        for m in sceneMaterials where (m != undefined and (matchPattern m.name pattern:"*2147026802*" ignoreCase:true)) do
        (
            matched += 1

            local didSet = false
            try (if isProperty m #overrideCapMaterial do (m.overrideCapMaterial = quartzMat; didSet = true)) catch()
            if not didSet do try (if isProperty m #override_cap_material do (setProperty m #override_cap_material quartzMat; didSet = true)) catch()
            if not didSet do try (if isProperty m #overrideMtl do (m.overrideMtl = quartzMat; didSet = true)) catch()
            if not didSet do try (if isProperty m #slicerCapMtl do (m.slicerCapMtl = quartzMat; didSet = true)) catch()

            if didSet then
            (
                updated += 1
                logLine ("Override cap material synced on '" + m.name + "' with quartz '" + quartzMat.name + "'.")
            )
            else
            (
                logLine ("WARN: Matched '" + m.name + "' but no known override-cap property was writable.")
            )
        )

        if matched == 0 then
            logLine "WARN: No material matched '*2147026802*' for override-cap sync."

        updated
    )

    fn applyQuartzToSlicerOverrides quartzMat =
    (
        local sliceNode = getNodeByName "Slice_Sink" exact:true ignoreCase:false
        if sliceNode == undefined then
        (
            logLine "WARN: Node 'Slice_Sink' not found; slicer override-cap sync skipped."
            return 0
        )

        local slicersMatched = 0
        local slicersUpdated = 0

        for md in sliceNode.modifiers do
        (
            local mdName = toLower (md.name as string)
            local mdClass = toLower ((classOf md) as string)
            if (findString mdName "slicer") != undefined or (findString mdClass "slicer") != undefined then
            (
                slicersMatched += 1
                local didSet = false

                -- Enable override switches when present.
                try (if isProperty md #overrideCapMtlOn do md.overrideCapMtlOn = true) catch()
                try (if isProperty md #overrideCapMaterialOn do md.overrideCapMaterialOn = true) catch()
                try (if isProperty md #useOverrideCapMtl do md.useOverrideCapMtl = true) catch()

                -- Try common cap-material slots used by slicer-style modifiers.
                try (if isProperty md #overrideCapMaterial do (md.overrideCapMaterial = quartzMat; didSet = true)) catch()
                if not didSet do try (if isProperty md #override_cap_material do (setProperty md #override_cap_material quartzMat; didSet = true)) catch()
                if not didSet do try (if isProperty md #overrideCapMtl do (md.overrideCapMtl = quartzMat; didSet = true)) catch()
                if not didSet do try (if isProperty md #overrideMtl do (md.overrideMtl = quartzMat; didSet = true)) catch()
                if not didSet do try (if isProperty md #capMtl do (md.capMtl = quartzMat; didSet = true)) catch()
                if not didSet do try (if isProperty md #capMaterial do (md.capMaterial = quartzMat; didSet = true)) catch()
                if not didSet do try (if isProperty md #slicerCapMtl do (md.slicerCapMtl = quartzMat; didSet = true)) catch()

                if didSet then
                (
                    slicersUpdated += 1
                    logLine ("Slicer override cap synced on node 'Slice_Sink', modifier '" + md.name + "' with quartz '" + quartzMat.name + "'.")
                )
                else
                (
                    logLine ("WARN: Slicer modifier found on 'Slice_Sink' (" + md.name + ") but no writable cap override property was detected.")
                )
            )
        )

        if slicersMatched == 0 then
            logLine "WARN: No slicer-like modifiers found on 'Slice_Sink' for override-cap sync."

        slicersUpdated
    )

    fn hideAllSinks =
    (
        for o in objects where (isValidNode o and isSinkNodeName o.name) do try (o.isHidden = true) catch()
    )

    fn showSinkHierarchy skuNode =
    (
        local nodes = collectHierarchy skuNode
        for n in nodes where isValidNode n do try (n.isHidden = false) catch()
    )

    fn processSceneFile scenePath =
    (
        logLine ("Opening scene: " + scenePath)
        local loaded = false
        try (loaded = loadMaxFile scenePath useFileUnits:true quiet:true) catch (loaded = false)
        if loaded != true then
        (
            logLine ("WARN: Could not open scene, skipped: " + scenePath)
            return #(0,0,0)
        )

        local sceneSkus = 0
        local jobsAttempted = 0
        local jobsSubmitted = 0
        local sceneBasketNodes = collectBasketStrainerNodes()
        if sceneBasketNodes.count > 0 then
            logLine ("Detected basket strainer hierarchy node count: " + (sceneBasketNodes.count as string))
        else
            logLine "No basket strainer nodes detected in scene."

        for sku in SKU_LIST do
        (
            local skuNode = getNodeByExactName sku
            if skuNode == undefined do continue
            local targetNodes = combineUniqueNodes (collectTargetNodesForSku skuNode) sceneBasketNodes

            if not ensureSkuOutputFolder sku do continue

            sceneSkus += 1

            for f in FINISHES do
            (
                local finishCode = f[1]
                local matName = f[2]
                local qMat = loadQuartzMaterialByName matName
                if qMat == undefined do
                (
                    logLine ("WARN: Missing material " + matName + " for " + sku + " " + finishCode)
                    continue
                )
                local capUpdatedCount = applyQuartzToOverrideCapMaterial qMat
                local slicerUpdatedCount = applyQuartzToSlicerOverrides qMat
                logLine ("Override-cap materials updated for finish " + finishCode + ": " + (capUpdatedCount as string) + " | slicer modifiers updated: " + (slicerUpdatedCount as string))

                for i = 1 to IGR_CAMERA_RENDER_PLAN.count do
                (
                    local camName = IGR_CAMERA_RENDER_PLAN[i][1]
                    local stateName = IGR_CAMERA_RENDER_PLAN[i][2]
                    local camNode = getNodeByExactName camName
                    if camNode == undefined do
                    (
                        logLine ("WARN: Missing camera " + camName + " for " + sku)
                        continue
                    )

                    if not (restoreSceneStateBestEffort stateName) then
                    (
                        throw ("HardFail: could not restore scene state '" + stateName + "' for camera " + camName + " in scene " + scenePath)
                    )

                    hideAllSinks()
                    showSinkHierarchy skuNode
                    local selectedNodes = selectSkuAndChildren skuNode
                    if selectedNodes != undefined then logLine ("Selected SKU hierarchy node count: " + (selectedNodes.count as string))
                    local basketSelected = selectBasketStrainersAndChildren()
                    if basketSelected.count > 0 then logLine ("Selected basket strainer hierarchy node count: " + (basketSelected.count as string))
                    local assignedCount = applyMaterialToNodes targetNodes qMat
                    logLine ("Applied material '" + matName + "' to " + (assignedCount as string) + " node(s) for " + sku + " before camera " + camName)

                    try (viewport.setCamera camNode) catch()
                    completeRedraw()
                    sleep (SUBMISSION_STABILIZE_MS / 1000.0)

                    local outputPath = buildOutputFilePath sku finishCode i
                    local jobName = sku + "_" + finishCode + "_IGR" + (formattedPrint i format:"02d")

                    local tempScenePath = buildTempScenePath (jobName + "_SRC")
                    if not (saveTempSceneSnapshot tempScenePath) then
                    (
                        logLine ("ERROR: Could not save temp scene: " + tempScenePath)
                        continue
                    )

                    jobsAttempted += 1
                    logLine ("Submitting: " + jobName + " | camera=" + camName + " | state=" + stateName)
                    if submitViaMaxCmd tempScenePath jobName camName outputPath RENDER_WIDTH RENDER_HEIGHT then
                    (
                        jobsSubmitted += 1
                        logLine ("SUBMITTED: " + jobName)
                    )
                    else
                    (
                        logLine ("ERROR: Submission failed: " + jobName)
                    )
                )
            )
        )

        #(sceneSkus, jobsAttempted, jobsSubmitted)
    )

    /* =========================
       MAIN
       ========================= */
    (
        initLog()
        logLine "----------------------------------------"
        logLine "IGR Multi-scene Backburner submission started."
        logLine ("Output root: " + OUTPUT_ROOT)
        logLine ("Temp scenes: " + TEMP_SCENE_FOLDER)
        logLine ("Manager: " + BACKBURNER_MANAGER + ":" + (BACKBURNER_PORT as string))

        if not doesFileExist QUARTZ_MATLIB then
        (
            logLine "ERROR: Quartz material library not found."
            return false
        )
        if not safeMakeDir OUTPUT_ROOT then
        (
            logLine "ERROR: Could not access output root."
            return false
        )
        if not ensureTempFolder() then
        (
            logLine "ERROR: Could not access temp scene folder."
            return false
        )

        local rootFolder = promptForSceneRoot()
        if rootFolder == undefined then
        (
            logLine "Cancelled: no folder selected."
            messageBox "No folder selected. Script cancelled." title:"IGR Quartz Variant Renderer"
            return false
        )

        local sceneFiles = #()
        collectMaxFilesRecursive rootFolder sceneFiles
        if sceneFiles.count == 0 then
        (
            logLine ("No .max files found under: " + rootFolder)
            messageBox ("No .max files found under:\n" + rootFolder) title:"IGR Quartz Variant Renderer"
            return false
        )

        local totalScenes = 0
        local totalSkus = 0
        local totalJobsAttempted = 0
        local totalJobsSubmitted = 0

        for scn in sceneFiles do
        (
            local res = processSceneFile scn
            totalScenes += 1
            totalSkus += res[1]
            totalJobsAttempted += res[2]
            totalJobsSubmitted += res[3]
        )

        logLine "----------------------------------------"
        logLine ("Scenes processed: " + (totalScenes as string))
        logLine ("SKUs found: " + (totalSkus as string))
        logLine ("Jobs attempted: " + (totalJobsAttempted as string))
        logLine ("Jobs submitted: " + (totalJobsSubmitted as string))
        logLine "IGR Multi-scene Backburner submission finished."

        messageBox (
            "IGR render submission complete.\n\n" +
            "Scenes processed: " + (totalScenes as string) + "\n" +
            "SKUs found: " + (totalSkus as string) + "\n" +
            "Jobs attempted: " + (totalJobsAttempted as string) + "\n" +
            "Jobs submitted: " + (totalJobsSubmitted as string)
        ) title:"IGR Quartz Variant Renderer"
    )
)
