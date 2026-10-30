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
    property int dailyRetryInterval:   30 * 60 * 1000
    property int offlineRetryInterval: 5 * 60 * 1000

    property string systemLocale: Qt.locale().name.replace(/_/g, "-")

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

    // Local date (yyyyMMdd) on which the scheduled daily refresh last completed.
    // Persisted so a restart after the scheduled time does not refresh again.
    property string lastDailyRunDate: ""
    // Wall-clock ms before which the scheduled refresh must not retry
    // (Bing has not published today's image yet, or we were offline).
    property real dailyRetryAt: 0

    property bool isStarted: false
    property bool isLoading: false
    property bool isForcing: false
    property bool isScheduledRun: false
    property bool isDownloading: false

    readonly property bool dailyMode: !!pluginData.enableDailyRefresh
    readonly property bool externalWallpaperControl: SessionData.perMonitorWallpaper
                                                     || SessionData.wallpaperCyclingEnabled
                                                     || SessionData.perModeWallpaper

    onIsDownloadingChanged: saveStatus()

    Component.onCompleted: startDelayTimer.start()

    Timer {
        id: startDelayTimer
        interval: 1000
        running: false
        repeat: false
        onTriggered: checkForEnvironmentAndStart()
    }

    // Interval mode: poll Bing and apply a wallpaper only when a new image appears.
    Timer {
        id: bingwallTimer
        interval: root.bingDownloadInterval
        running: root.isStarted && !root.dailyMode && !root.externalWallpaperControl
        repeat: true
        onTriggered: wallpaperCheck()
    }

    // Daily mode: compare against the wall clock every minute instead of arming
    // one long timer, which stops counting while the machine is suspended.
    Timer {
        id: dailyScheduleTicker
        interval: 60 * 1000
        running: root.isStarted && root.dailyMode && !root.externalWallpaperControl
        repeat: true
        triggeredOnStart: true
        onTriggered: dailyTick()
    }

    onExternalWallpaperControlChanged: {
        if (!root.isStarted) return
        ToastService.showInfo(root.externalWallpaperControl
                              ? "Wallpaper of the Day: update timer stopped"
                              : "Wallpaper of the Day: update timer started")
    }

    property var lastDailyRefreshTime: pluginData.dailyRefreshTime

    onDailyModeChanged:            root.dailyRetryAt = 0
    onLastDailyRefreshTimeChanged: root.dailyRetryAt = 0

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
        Proc.runCommand(null, ["which", "inotifywait"], (output, exitCode) => {
            if (exitCode !== 0) {
                ToastService.showError("Wallpaper of the Day: inotifywait not found - install inotify-tools")
                console.error("Wallpaper of the day: inotifywait not found, install inotify-tools")
                return
            }
            pathExists(root.cachePath, function(exists) {
                if (!exists) {
                    Paths.mkdir(root.cachePath)
                }
                const bingwallCacheDir = Paths.cache + "/bingwall/"
                pathExists(bingwallCacheDir, function(cacheExists) {
                    if (!cacheExists) Paths.mkdir(bingwallCacheDir)
                    forceTriggerWatcher.running = true
                    pathExists(root.currentMetadataPath, function(metaExists) {
                        if (!metaExists) {
                            saveMetadata()
                        }
                        readMetadata(bingMetadataFile.text())
                        // Daily mode catches up through dailyScheduleTicker's first tick.
                        if (!root.dailyMode && !root.externalWallpaperControl) wallpaperCheck()
                        root.isStarted = true
                    })
                })
            })
        }, 0)
    }

    function localDateString(date) {
        const pad = n => (n < 10 ? "0" : "") + n
        return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}`
    }

    function parseDailyRefreshTime() {
        const timeString = pluginData.dailyRefreshTime || "09:00"
        const timeParts = timeString.split(":")

        if (timeParts.length !== 2) {
            console.error("Wallpaper of the day: Invalid time format:", timeString)
            return null
        }

        const hour   = parseInt(timeParts[0])
        const minute = parseInt(timeParts[1])

        if (isNaN(hour) || isNaN(minute) ||
            hour < 0 || hour > 23 ||
            minute < 0 || minute > 59) {
            console.error("Wallpaper of the day: Invalid time values:", timeString)
            return null
        }
        return { hour, minute }
    }

    function dailyTick() {
        if (!root.dailyMode || root.isDownloading) return

        const time = parseDailyRefreshTime()
        if (!time) return

        const now = new Date()
        if (root.lastDailyRunDate === localDateString(now)) return

        const target = new Date(now)
        target.setHours(time.hour, time.minute, 0, 0)
        if (now < target || now.getTime() < root.dailyRetryAt) return

        console.log("Wallpaper of the day: Daily refresh triggered at scheduled time")
        root.isScheduledRun = true
        wallpaperCheck()
    }

    // Bing's startdate is the market's date, which can lag the local date (it-IT: 2300 UTC
    // of the previous day). fullstartdate is UTC yyyyMMddHHmm, so convert it to local.
    function bingLocalDate(responseData) {
        const full = responseData.fullstartdate
        if (!full || full.length !== 12) return responseData.startdate
        const p = (start, len) => parseInt(full.substr(start, len))
        return localDateString(new Date(Date.UTC(p(0, 4), p(4, 2) - 1, p(6, 2), p(8, 2), p(10, 2))))
    }

    // Called after every successful Bing lookup. Today's run counts as done once
    // Bing serves today's image, whether or not it had to be downloaded.
    function finishDailyRun(imageDate) {
        const today = localDateString(new Date())
        if (imageDate >= today) {
            if (root.lastDailyRunDate !== today) {
                root.lastDailyRunDate = today
                saveMetadata()
            }
        } else if (root.isScheduledRun) {
            console.log("Wallpaper of the day: Today's image is not published yet, retrying later")
            root.dailyRetryAt = Date.now() + root.dailyRetryInterval
        }
    }

    function finishCheck(retryLater) {
        if (retryLater && root.isScheduledRun) root.dailyRetryAt = Date.now() + root.offlineRetryInterval
        root.isForcing = false
        root.isScheduledRun = false
        root.isDownloading = false
    }

    function wallpaperCheck() {
        if (root.isDownloading) return

        root.isDownloading = true
        console.log("Wallpaper of the day: Checking for a new wallpaper...")
        downloadWallpaper()
    }

    function downloadWallpaper() {
        const bingApiUrl = `https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=${root.systemLocale}`
        Proc.runCommand(null, ["curl", "-s", bingApiUrl], (output, exitCode) => {
            if (exitCode === 6 || exitCode === 7 || exitCode === 28) {
                // couldn't resolve host / connect / timed out: most likely offline, retry on next check
                console.error("Wallpaper of the day: Bing unreachable, no internet? (curl exit code " + exitCode + ")")
                if (root.isForcing) ToastService.showError("Wallpaper of the Day: Bing unreachable")
                finishCheck(true)
                return
            }
            if (exitCode !== 0) {
                console.error("Wallpaper of the day: Failed to retrieve metadata. (curl exit code " + exitCode + ")")
                ToastService.showError("Wallpaper download failed")
                finishCheck(true)
                return
            }
            try {
                const response     = JSON.parse(output.trim())
                const responseData = response.images[0]

                const imageUrl = responseData.url.split('&')[0].replace("1920x1080", "UHD")
                const namePart = imageUrl.split('OHR.')[1]
                if (!namePart) {
                    console.error("Wallpaper of the day: Unexpected image URL format:", imageUrl)
                    finishCheck(true)
                    return
                }
                const lastDot   = namePart.lastIndexOf('.')
                const fileName  = namePart.substring(0, lastDot)
                const extension = namePart.substring(lastDot + 1)

                const datePrefix = pluginData.GnomeExtensionBingWallpaperCompatibility
                                   ? responseData.startdate + "-" : ""
                const imageSavePath = Paths.strip(root.cachePath + `${datePrefix}${fileName}.${extension}`)
                const temporaryPath = imageSavePath + ".part"

                // Identify images by file name: Bing's title is no longer unique per day.
                if (imageSavePath === root.currentImageSavePath && SessionData.wallpaperPath !== "" && !root.isForcing) {
                    // Nothing new: leave whatever wallpaper the user has chosen alone.
                    console.log("Wallpaper of the day: No new wallpaper found")
                    finishDailyRun(bingLocalDate(responseData))
                    finishCheck(false)
                    return
                }

                const lastImagePath = root.currentImageSavePath
                root.fullImageUrl = "https://www.bing.com" + imageUrl

                const failDownload = message => {
                    console.error("Wallpaper of the day:", message)
                    ToastService.showError("Wallpaper download failed")
                    Proc.runCommand(null, ["rm", "-f", temporaryPath], () => finishCheck(true), 0)
                }

                Proc.runCommand(null, ["curl", "-f", "-sS", "-L", "-o", temporaryPath, root.fullImageUrl], (output, exitCode) => {
                    if (exitCode !== 0) {
                        failDownload("Failed to download image (curl exit code " + exitCode + ")")
                        return
                    }
                    installDownloadedImage(temporaryPath, imageSavePath, error => {
                        if (error) {
                            failDownload(error)
                            return
                        }
                        // async callback: outer try/catch doesn't cover it, so always release the lock
                        try {
                            root.currentTitle = responseData.title
                            root.currentDescription = responseData.copyright
                            root.currentImageSavePath = imageSavePath
                            finishDailyRun(bingLocalDate(responseData))
                            saveMetadata()
                            SessionData.setWallpaper(imageSavePath)

                            if (pluginData.deleteOld && lastImagePath && lastImagePath !== imageSavePath) {
                                Quickshell.execDetached(["rm", "-f", lastImagePath])
                            }
                            if (!root.isForcing) {
                                bingNotification()
                            } else {
                                ToastService.showInfo("Wallpaper check finished")
                            }
                        } catch (e) {
                            console.error("Wallpaper of the day: Error applying wallpaper: ", e)
                        } finally {
                            finishCheck(false)
                        }
                    })
                }, 0)
            } catch (e) {
                console.error("Wallpaper of the day: Error parsing Bing API response: ", e)
                finishCheck(true)
            }
        }, 0)
    }

    function bingNotification() {
        if (pluginData.notifications) {
            Quickshell.execDetached(["notify-send", "-a", "DMS", "-i", "preferences-wallpaper",
                                     root.currentTitle, root.currentDescription])
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
                root.lastDailyRunDate     = metadata.lastDailyRunDate     ?? ""
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
            currentDescription:   root.currentDescription,
            lastDailyRunDate:     root.lastDailyRunDate
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

    function installDownloadedImage(temporaryPath, imageSavePath, callback) {
        // JPEG start/end markers (FFD8/FFD9).
        Proc.runCommand(null, ["sh", "-c", '(head -c 2 "$1"; tail -c 2 "$1") | od -An -tx1', "sh", temporaryPath], (output, exitCode) => {
            if (exitCode !== 0 || output.replace(/\s/g, "") !== "ffd8ffd9") {
                callback("JPEG marker check failed")
                return
            }
            Proc.runCommand(null, ["mv", "-f", temporaryPath, imageSavePath], (output, exitCode) => {
                callback(exitCode === 0 ? "" : "Failed to replace wallpaper (mv exit code " + exitCode + ")")
            }, 0)
        }, 0)
    }
}
