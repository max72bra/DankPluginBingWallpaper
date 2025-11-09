import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "wallpaperBing"

    StyledText {
        width: parent.width
        text: "A Wallpaper Downloader From Bing"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "notifications"
        label: "Send me a notification"
        description: "Show desktop notifications whenever a new wallpaper is downloaded and applied"
        defaultValue: true
    }
    
    ToggleSetting {
        settingKey: "deleteOld"
        label: "Keep only the last wallpaper"
        description: "Deletes previous wallpapers, keeping only the latest one. If disabled, it may consume disk space over time."
        defaultValue: true
    }
}
