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
    global BACKBURNER_MANAGER = "10.10.0.59"
    global BACKBURNER_PORT    = 3234
    global TEMP_SCENE_FOLDER  = @"R:\Aidan\IGR\_TempScenes"
    global DRY_RUN            = false
    global SUBMISSION_STABILIZE_MS = 250
    global JOB_PRIORITY       = 50
    global MAXCMD_EXE         = (getDir #maxroot) + "3dsmaxcmd.exe"

    global IGR_EMPTY_SCENESTATE = "empty"
    global IGR_SLICE_SCENESTATE = "Slice"
    global IGR_SLICE_CAMERA     = "Corona Camera 002"

    global FINISHES = #(
        #("WH", "White_Quartz"),
        #("BL", "Black_Quartz"),
        #("CN", "Concrete_Quartz_02"),
        #("BR", "Brown_Quartz_02"),
        #("GR", "Grey_Quartz_02"),
        #("BI", "Bisque_Quartz_02")
    )

    global SKU_TO_SIZE = #(
        #("Q-306",      "S"),
        #("Q-315",      "S"),
        #("QUWS-875",   "L"),
        #("QARWS-740",  "M"),
        #("QAWS-000",   "M"),
        #("QTWS-000",   "L")
    )

    global SIZE_TO_CAMERAS = #(
        #("S", #("Corona Camera 001", "Corona Camera 002", "Corona Camera 003", "Corona Camera 004")),
        #("M", #("Corona Camera 001", "Corona Camera 002", "Corona Camera 003", "Corona Camera 004")),
        #("L", #("Corona Camera 001", "Corona Camera 002", "Corona Camera 003", "Corona Camera 004"))
    )

    global VALID_SINK_PREFIXES = #( "QARWS", "QAWS", "QUWS", "QTWS", "QAR", "QA", "QU", "QT", "Q" )
    global IGR_LogFilePath = undefined

    /* =========================
       LOGGING + HELPERS
       ========================= */
    fn timeStamp = (localTime as string)

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
            local stamp = substituteString (substituteString (substituteString (timeStamp()) "/" "-") ":" "-") " " "_"
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
        local line = "[" + timeStamp() + "] " + msg
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

    fn getNodeByExactName n = getNodeByName n exact:true ignoreCase:false

    fn findSizeGroup sku =
    (
        for row in SKU_TO_SIZE where (toUpper row[1]) == (toUpper sku) do return row[2]
        undefined
    )

    fn getCamerasForSizeGroup g =
    (
        for row in SIZE_TO_CAMERAS where (toUpper row[1]) == (toUpper g) do return row[2]
        undefined
    )

    fn loadQuartzMaterialByName matName =
    (
        if not doesFileExist QUARTZ_MATLIB then return undefined
        local ml = undefined
        try (ml = loadTempMaterialLibrary QUARTZ_MATLIB) catch (ml = undefined)
        if ml == undefined then return undefined

        for i = 1 to ml.count do
        (
            local m = ml[i]
            if m != undefined and (toUpper m.name == toUpper matName) then return m
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

    fn sceneStateForCamera cameraName =
    (
        if (toUpper cameraName) == (toUpper IGR_SLICE_CAMERA) then IGR_SLICE_SCENESTATE else IGR_EMPTY_SCENESTATE
    )

    fn restoreSceneStateBestEffort stateName =
    (
        local ok = false
        if stateName == undefined or stateName == "" then return false

        try
        (
            sceneStateMgr.RestoreSceneState stateName
            ok = true
        ) catch()

        if not ok do
        (
            try
            (
                sceneStates.restore stateName
                ok = true
            ) catch()
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

    fn applyMaterialToSinkHierarchy skuNode matObj =
    (
        local nodes = collectHierarchy skuNode
        for n in nodes where (isValidNode n and isKindOf n GeometryClass) do try (n.material = matObj) catch()
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

        for row in SKU_TO_SIZE do
        (
            local sku = row[1]
            local skuNode = getNodeByExactName sku
            if skuNode == undefined do continue

            local sizeGroup = findSizeGroup sku
            local cameraNames = getCamerasForSizeGroup sizeGroup
            if cameraNames == undefined or cameraNames.count == 0 do continue
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

                try
                (
                    hideAllSinks()
                    showSinkHierarchy skuNode
                    applyMaterialToSinkHierarchy skuNode qMat
                    completeRedraw()
                ) catch()

                for i = 1 to cameraNames.count do
                (
                    local camName = cameraNames[i]
                    local camNode = getNodeByExactName camName
                    if camNode == undefined do
                    (
                        logLine ("WARN: Missing camera " + camName + " for " + sku)
                        continue
                    )

                    local stateName = sceneStateForCamera camName
                    restoreSceneStateBestEffort stateName
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
