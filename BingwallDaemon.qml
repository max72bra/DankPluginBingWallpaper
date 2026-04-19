import QtQuick
import QtCore
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root

    property int bingDownloadInterval: 3 * 60 * 60 * 1000

    property string systemLocale: Qt.locale().name

    property string cachePath: pluginData.GnomeExtensionBingWallpaperCompatibility
                               ? StandardPaths.writableLocation(StandardPaths.PicturesLocation) + "/BingWallpaper/"
                               : Paths.cache + "/bingwall/"
    property string currentMetadataPath:  Paths.cache + "/bingwall/metadata.json"
    property string statusPath:           Paths.cache + "/bingwall/status.json"
    property string forceTriggerPath:     Paths.cache + "/bingwall/force.trigger"
    property string fullImageUrl: ""

    property string currentImageSavePath: ""
    property string currentTitle: ""
    property string currentDescription: ""

    property bool isStarting: false
    property bool isLoading: false
    property bool isForcing: false
    property bool isDownloading: false

    onIsDownloadingChanged: saveStatus()

    Component.onCompleted: {
        root.isStarting = true
        startDelayTimer.start()
    }

    Timer {
        id: startDelayTimer
        interval: 1000
        running: false
        repeat: false
        onTriggered: checkForEnvironmentAndStart()
    }

    Timer {
        id: bingwallTimer
        interval: root.bingDownloadInterval
        running: false
        repeat: true
        onTriggered: wallpaperCheck()
    }

    Timer {
        id: dailyRefreshTimer
        running: false
        repeat: false
        onTriggered: {
            console.log("Wallpaper of the day: Daily refresh triggered at scheduled time")
            ToastService.showInfo("Daily wallpaper refresh triggered")
            wallpaperCheck()
            scheduleDailyRefresh()
        }
    }

    Connections {
        target: SessionData

        function onWallpaperCyclingEnabledChanged()  { updateTimerState() }
        function onWallpaperCyclingModeChanged()     { updateTimerState() }
        function onPerMonitorWallpaperChanged()      { updateTimerState() }
        function onMonitorCyclingSettingsChanged()   { updateTimerState() }
        function onPerModeWallpaperChanged()         { updateTimerState() }
    }

    property var lastEnableDailyRefresh: pluginData.enableDailyRefresh
    property var lastDailyRefreshTime: pluginData.dailyRefreshTime

    onLastEnableDailyRefreshChanged: updateDailyRefreshTimer()
    onLastDailyRefreshTimeChanged:   updateDailyRefreshTimer()

    // -------------------------------------------------------------------------
    // Force trigger: widget writes a timestamp here to request a force download
    // inotifywait watches the directory so it works even before the file exists
    // and catches both normal writes (close_write) and atomic writes (moved_to)
    // -------------------------------------------------------------------------
    Process {
        id: forceTriggerWatcher
        running: false
        command: ["inotifywait", "-q", "-m", "-e", "close_write,moved_to",
                  "--format", "%f",
                  Paths.strip(Paths.cache + "/bingwall/")]
        stdout: SplitParser {
            onRead: line => {
                if (line.trim() === "force.trigger" && !root.isDownloading) {
                    console.log("Wallpaper of the day: Force trigger received from widget")
                    root.isForcing = true
                    wallpaperCheck()
                }
            }
        }
    }

    FileView {
        id: bingMetadataFile
        path: root.currentMetadataPath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        onLoadFailed: error => {
            console.error("Wallpaper of the day: Error with metadata file => ", error)
            bingwallTimer.stop()
        }
    }

    FileView {
        id: statusFile
        path: root.statusPath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        onLoadFailed: error => {}
    }

    // -------------------------------------------------------------------------
    // Internal functions
    // -------------------------------------------------------------------------

    function checkForEnvironmentAndStart() {
        pathExists(root.cachePath, function(exists) {
            if (!exists) {
                Paths.mkdir(root.cachePath)
            }
            // bingwall/ always needed for metadata, status and force trigger
            const bingwallCacheDir = Paths.cache + "/bingwall/"
            pathExists(bingwallCacheDir, function(exists) {
                if (!exists) Paths.mkdir(bingwallCacheDir)
            })
            forceTriggerWatcher.running = true
            pathExists(root.currentMetadataPath, function(exists) {
                if (!exists) {
                    saveMetadata()
                }
                readMetadata(bingMetadataFile.text())
                wallpaperCheck()
                updateDailyRefreshTimer()
                bingwallTimer.start()
            })
        })
    }

    function updateDailyRefreshTimer() {
        if (pluginData.enableDailyRefresh) {
            scheduleDailyRefresh()
        } else {
            dailyRefreshTimer.stop()
        }
    }

    function scheduleDailyRefresh() {
        if (!pluginData.enableDailyRefresh) return

        const timeString = pluginData.dailyRefreshTime || "09:00"
        const timeParts = timeString.split(":")

        if (timeParts.length !== 2) {
            console.error("Wallpaper of the day: Invalid time format:", timeString)
            return
        }

        const targetHour   = parseInt(timeParts[0])
        const targetMinute = parseInt(timeParts[1])

        if (isNaN(targetHour) || isNaN(targetMinute) ||
            targetHour < 0 || targetHour > 23 ||
            targetMinute < 0 || targetMinute > 59) {
            console.error("Wallpaper of the day: Invalid time values:", timeString)
            return
        }

        const now    = new Date()
        const target = new Date()
        target.setHours(targetHour)
        target.setMinutes(targetMinute)
        target.setSeconds(0)
        target.setMilliseconds(0)

        if (target <= now) {
            target.setDate(target.getDate() + 1)
        }

        const msUntilTarget = target - now
        dailyRefreshTimer.interval = msUntilTarget
        dailyRefreshTimer.start()

        console.log("Wallpaper of the day: Daily refresh scheduled for", target.toLocaleString(),
                    "(in", Math.round(msUntilTarget / 1000 / 60), "minutes)")
    }

    function wallpaperCheck() {
        if (root.isDownloading) return

        const command = ["ping", "-c", "1", "1.1.1.1"]
        Proc.runCommand(null, command, (output, exitCode) => {
            if (exitCode === 0) {
                root.isDownloading = true
                console.log("Wallpaper of the day: Checking for a new wallpaper...")
                downloadWallpaper()
            } else {
                console.error("Wallpaper of the day: Ping failed, no internet?")
                root.isForcing = false
            }
        }, 0)
    }

    function downloadWallpaper() {
        const bingApiUrl = `https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=${root.systemLocale}`
        Proc.runCommand(null, ["curl", "-s", bingApiUrl], (output, exitCode) => {
            if (exitCode === 0) {
                try {
                    const response     = JSON.parse(output.trim())
                    const responseData = response.images[0]

                    if (root.currentTitle !== responseData.title || SessionData.wallpaperPath === "" || root.isForcing) {
                        root.currentTitle       = responseData.title
                        root.currentDescription = responseData.copyright
                        const lastImagePath     = root.currentImageSavePath

                        const imageUrl = responseData.url.split('&')[0].replace("1920x1080", "UHD")
                        root.fullImageUrl = "https://www.bing.com" + imageUrl

                        const namePart  = imageUrl.split('OHR.')[1]
                        if (!namePart) {
                            console.error("Wallpaper of the day: Unexpected image URL format:", imageUrl)
                            root.isForcing = false
                            root.isDownloading = false
                            return
                        }
                        const lastDot   = namePart.lastIndexOf('.')
                        const fileName  = namePart.substring(0, lastDot)
                        const extension = namePart.substring(lastDot + 1)

                        if (pluginData.GnomeExtensionBingWallpaperCompatibility) {
                            const datePrefix = responseData.startdate
                            root.currentImageSavePath = Paths.strip(root.cachePath + `${datePrefix}-${fileName}.${extension}`)
                        } else {
                            root.currentImageSavePath = Paths.strip(root.cachePath + `${fileName}.${extension}`)
                        }

                        if (pluginData.deleteOld) {
                            pathExists(lastImagePath, function(exists) {
                                if (exists) Quickshell.execDetached(["rm", "-f", lastImagePath])
                            })
                        }

                        saveMetadata()

                        Proc.runCommand(null, ["curl", "-s", "-o", root.currentImageSavePath, root.fullImageUrl], (output, exitCode) => {
                            if (exitCode === 0) {
                                if (!root.isForcing) {
                                    bingNotification()
                                } else {
                                    ToastService.showInfo("Wallpaper check finished")
                                }
                                SessionData.setWallpaper(root.currentImageSavePath)
                            } else {
                                console.error("Wallpaper of the day: Failed to download image.")
                                ToastService.showError("Wallpaper download failed")
                            }
                            root.isForcing = false
                            root.isDownloading = false
                        }, 0)

                    } else {
                        console.log("Wallpaper of the day: No new wallpaper found")
                        if (!root.isStarting) {
                            SessionData.setWallpaper(root.currentImageSavePath)
                        }
                        root.isForcing = false
                        root.isDownloading = false
                    }
                } catch (e) {
                    console.error("Wallpaper of the day: Error parsing Bing API response: ", e)
                    root.isForcing = false
                    root.isDownloading = false
                } finally {
                    root.isStarting = false
                }
            } else {
                console.error("Wallpaper of the day: Failed to retrieve metadata.")
                ToastService.showError("Wallpaper download failed")
                root.isForcing = false
                root.isDownloading = false
                root.isStarting = false
            }
        }, 0)
    }

    function bingNotification() {
        if (pluginData.notifications) {
            Quickshell.execDetached(["notify-send", "-a", "DMS", "-i", "preferences-wallpaper",
                                     root.currentTitle, root.currentDescription])
        }
    }

    function updateTimerState() {
        if (SessionData.perMonitorWallpaper || SessionData.wallpaperCyclingEnabled || SessionData.perModeWallpaper) {
            bingwallTimer.stop()
            ToastService.showInfo("Wallpaper of the Day: update timer stopped")
        } else {
            if (!bingwallTimer.running) bingwallTimer.start()
            ToastService.showInfo("Wallpaper of the Day: update timer started")
        }
    }

    function readMetadata(content) {
        root.isLoading = true
        try {
            if (content && content.trim()) {
                const metadata = JSON.parse(content)
                root.currentImageSavePath = metadata.currentImageSavePath ?? ""
                root.currentTitle         = metadata.currentTitle         ?? ""
                root.currentDescription   = metadata.currentDescription   ?? ""
            }
        } catch (e) {
            console.error("Wallpaper of the day: Error loading metadata: ", e)
        } finally {
            root.isLoading = false
        }
    }

    function saveMetadata() {
        if (root.isLoading) return
        bingMetadataFile.setText(JSON.stringify({
            currentImageSavePath: root.currentImageSavePath,
            currentTitle:         root.currentTitle,
            currentDescription:   root.currentDescription
        }, null, 2))
    }

    function saveStatus() {
        statusFile.setText(JSON.stringify({
            isDownloading: root.isDownloading
        }))
    }

    function pathExists(path: url, callback) {
        Proc.runCommand(null, ["test", "-e", Paths.strip(path)], (output, exitCode) => {
            if (callback) callback(exitCode === 0)
        }, 0)
    }
}
