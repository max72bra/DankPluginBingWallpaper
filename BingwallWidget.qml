import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules
import qs.Modules.Plugins

PluginComponent {
    id: root
    
    property int bingDownloadInterval: 3 * 60 * 60 * 1000
    
    property string systemLocale: Qt.locale().name
    
    property string cachePath: Paths.cache + "/bingwall/"
    property string currentMetadatapath: root.cachePath + "metadata.json"
    property string fullImageUrl: ""
    
    property string currentImageSavePath: ""
    property string currentTitle: ""
    property string currentDescription: ""
    
    property bool isStarting: false
    property bool isLoading: false
    property bool isForcing: false
    property bool isDownloading: false

    Component.onCompleted: {
        root.isStarting = true
        bingwallTimer.start()
        checkForEnvironmentAndStart()
    }
    
    Component.onDestruction: {}

    Timer {
        id: bingwallTimer
        interval: root.bingDownloadInterval
        running: false
        repeat: true
        onTriggered: {
            wallpaperCheck()
        }
    }
    
    Connections {
        target: SessionData

        function onWallpaperCyclingEnabledChanged() {
            updateTimerState()
        }

        function onWallpaperCyclingModeChanged() {
            updateTimerState()
        }
        
        function onPerMonitorWallpaperChanged() {
            updateTimerState()
        }

        function onMonitorCyclingSettingsChanged() {
            updateTimerState()
        }
        
        function onPerModeWallpaperChanged() {
            updateTimerState()
        }
    }
    
    function checkForEnvironmentAndStart() {
        pathExists(root.cachePath, function(exists) {
            if (!exists) {
                Paths.mkdir(root.cachePath)
            }
            pathExists(root.currentMetadatapath, function(exists) {
                if (!exists) {
                    saveMetadata()
                }
                readMetadata(bingMetadataFile.text())
                wallpaperCheck()
            })
        })
    }
    
    function forceWallpaperCheck() {
        if (root.isDownloading) {
            return
        }
        root.isForcing = true
        wallpaperCheck()
    }

    function wallpaperCheck() {
        if (root.isDownloading) {
            return
        }
        const command = ["ping", "-c", "1", "1.1.1.1"]
        Proc.runCommand(null, command, 
            (output, exitCode) => {
                if (exitCode === 0) {
                    root.isDownloading = true
                    console.log("Wallpaper of the day: Checking for a new wallpaper...")
                    downloadWallpaper()
                }
            }
        , 0)
    }
    
    function downloadWallpaper() {
        const curlCmd = `curl -s 'https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=${root.systemLocale}'`
        const command = ["sh", "-c", curlCmd]
        Proc.runCommand(null, command, (output, exitCode) => {
            if (exitCode === 0) {
                try {
                    const response = JSON.parse(output.trim())
                    const responseData = response.images[0]
                    
                    if (root.currentTitle !== responseData.title || SessionData.wallpaperPath === "" || root.isForcing) {
                        root.currentTitle = responseData.title
                        root.currentDescription = responseData.copyright
                        const lastImagePath = root.currentImageSavePath
    
                        const imageUrl = responseData.url.split('&')[0]
                        root.fullImageUrl = "https://www.bing.com" + imageUrl

                        const namePart = imageUrl.split('OHR.')[1];
                        const lastDot = namePart.lastIndexOf('.');
                        const fileName = namePart.substring(0, lastDot)
                        const extension = namePart.substring(lastDot + 1)
                        root.currentImageSavePath = Paths.strip(root.cachePath + `${fileName}.${extension}`)
                        
                        if (pluginData.deleteOld) {
                            pathExists(lastImagePath, function(exists) {
                                if (exists) {
                                    Quickshell.execDetached(["rm", "-f", lastImagePath])
                                }
                            })
                        }
                        
                        saveMetadata()
                        
                        const curlCmd = `curl -s -o '${root.currentImageSavePath}' '${root.fullImageUrl}'`
                        const command = ["sh", "-c", curlCmd]
                        Proc.runCommand(null, command, (output, exitCode) => {
                            if (exitCode === 0) {
                                if (!root.isForcing) {
                                    bingNotification()
                                } else {
                                    ToastService.showInfo(`Check finished`)
                                }
                                SessionData.setWallpaper(root.currentImageSavePath)
                            } else {
                                console.error("Wallpaper of the day: Failed to download image.")
                                ToastService.showError(`Wallpaper download failed`)
                            }
                            root.isForcing = false
                        }, 0)
                    } else {
                        console.log("Wallpaper of the day: No new wallpaper found")
                        if (root.isStarting === 0) {
                            SessionData.setWallpaper(root.currentImageSavePath)
                        }
                    }
                    root.isDownloading = false
                } catch (e) {
                    console.error("Error parsing Bing API response: ", e)
                } finally {
                    root.isStarting = false
                    console.log("Wallpaper of the day: Check finished")
                }
            } else {
                console.error("Wallpaper of the day: Failed to retrieve metadata.")
                ToastService.showError(`Wallpaper download failed`)
                root.isForcing = false
                root.isDownloading = false
                root.isStarting = false
            }
        }, 0)
    }
      
    function bingNotification() {
        if (pluginData.notifications) {
            var command = ["notify-send", "-a", "DMS", "-i", "preferences-wallpaper", root.currentTitle, root.currentDescription]
            Quickshell.execDetached(command)
        }
    }
    
    function updateTimerState() {
        if (SessionData.perMonitorWallpaper || SessionData.wallpaperCyclingEnabled || SessionData.perModeWallpaper) {
            bingwallTimer.stop()
            ToastService.showInfo(`Wallpaper of the Day: update timer stopped`)
        }
    }
   
    function readMetadata(content) {
        root.isLoading = true
        try {
            if (content && content.trim()) {
                var metadata = JSON.parse(content)
                
                root.currentImageSavePath = metadata.currentImageSavePath !== undefined ? metadata.currentImageSavePath : ""
                root.currentTitle = metadata.currentTitle !== undefined ? metadata.currentTitle : ""
                root.currentDescription = metadata.currentDescription !== undefined ? metadata.currentDescription : ""
            }
        } catch (e) {
            console.error("Wallpaper of the day: Error loading metadata: ", e)
        } finally {
            root.isLoading = false
        }
    }

    function saveMetadata() {
        if (root.isLoading) {
            return
        }
        bingMetadataFile.setText(JSON.stringify({
            "currentImageSavePath": root.currentImageSavePath,
            "currentTitle": root.currentTitle,
            "currentDescription": root.currentDescription
        }, null, 2))
    }
    
    function pathExists(path: url, callback) {
        var stripped = Paths.strip(path)
        var command = ["sh", "-c", `test -e '${stripped}'`]
        Proc.runCommand(null, command, (output, exitCode) => {
            if (callback) {
                callback(exitCode === 0)
            }
        }, 0)
    }
    
    FileView {
        id: bingMetadataFile

        path: root.currentMetadatapath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        onFileChanged: {
            // nothing
        }
        onLoadFailed: error => {
            console.error("Wallpaper of the day: Error with metadata file => ", error)
            bingwallTimer.stop()
        }
    }

    popoutWidth: 400
    popoutHeight: 400
    popoutContent: Component {
        id: popoutContent

        Column {
            id: contentColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            // anchors.margins: Theme.spacingM
            spacing: Theme.spacingM
            
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                    closePopout();
                    event.accepted = true;
                }
            }
            
            Item {
                width: parent.width
                height: 32

                StyledText {
                    text: I18n.tr("Wallpaper of the Day")
                    font.pixelSize: Theme.fontSizeLarge
                    color: Theme.surfaceText
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                    width: 32
                    height: 32
                    radius: 16
                    color: closeArea.containsMouse ? Theme.errorHover : "transparent"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter

                    DankIcon {
                        anchors.centerIn: parent
                        name: "close"
                        size: Theme.iconSize - 4
                        color: closeArea.containsMouse ? Theme.error : Theme.surfaceText
                    }

                    MouseArea {
                        id: closeArea

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPressed: closePopout()
                    }
                }
            }

            Rectangle {
                id: bingwallDetail

                width: parent.width
                height: 320
                implicitHeight: detailColumn.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, Theme.getContentBackgroundAlpha() * 0.6)
                border.color: Theme.outlineStrong
                border.width: 0
                clip: true

                Column {
                    id: detailColumn

                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Item {
                        width: parent.width
                        height: 30
                        
                        StyledText {
                            id: bingwallTitle
                            
                            text: root.currentTitle
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        
                        DankActionButton {
                            id: bingwallForceUpdateButton
                            
                            buttonSize: 28
                            iconName: "refresh"
                            iconSize: 18
                            z: 15
                            anchors.right: parent.right
                            iconColor: Theme.surfaceText
                            enabled: !root.isDownloading
                            opacity: enabled ? 1.0 : 0.5
                            onClicked: {
                                forceWallpaperCheck()
                            }

                            RotationAnimation {
                                target: bingwallForceUpdateButton
                                property: "rotation"
                                from: 0
                                to: 360
                                duration: 1000
                                running: root.isDownloading
                                loops: Animation.Infinite

                                onRunningChanged: {
                                    if (!running) {
                                        bingwallForceUpdateButton.rotation = 0
                                        
                                        bingwallTitle.text = root.currentTitle
                                        bingwallImage.source = "file://" + root.currentImageSavePath
                                        bingwallDescription.text = root.currentDescription
                                    }
                                }
                            }
                        }
                    }
                    
                    Row {
                        width: parent.width
                        spacing: Theme.spacingL

                        StyledRect {
                            width: parent.width
                            height: parent.width * 9 / 16
                            radius: Theme.cornerRadius
                            color: Theme.surfaceVariant
                            border.color: Theme.outline
                            border.width: 0

                            CachingImage {
                                id: bingwallImage
                                
                                anchors.fill: parent
                                anchors.margins: 1
                                source: "file://" + root.currentImageSavePath
                                fillMode: Image.PreserveAspectCrop
                                visible: true
                                maxCacheSize: 160
                                layer.enabled: true

                                layer.effect: MultiEffect {
                                    maskEnabled: true
                                    maskSource: wallpaperMask
                                    maskThresholdMin: 0.5
                                    maskSpreadAtMin: 1
                                }
                            }
                        }
                        
                        Rectangle {
                            id: wallpaperMask

                            anchors.fill: parent
                            anchors.margins: 1
                            radius: Theme.cornerRadius - 1
                            color: "black"
                            visible: false
                            layer.enabled: true
                        }
                    }
                    
                    Row {
                        width: parent.width
                        spacing: Theme.spacingL
                        
                        StyledText {
                            id: bingwallDescription
                            
                            width: parent.width
                            text: root.currentDescription
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                            clip: true
                        }
                    }
                }
            }
        }
    }

    horizontalBarPill: Component {
        Row {
            id: emojiRow
            spacing: Theme.spacingXS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "wallpaper"
                size: Theme.iconSize - 7
                color: Theme.surfaceText
            }
        }
    }

    verticalBarPill: Component {
        Column {
            id: emojiColumn
            spacing: Theme.spacingXS

            DankIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "wallpaper"
                size: Theme.iconSize - 7
                color: Theme.surfaceText
            }
        }
    }
}
