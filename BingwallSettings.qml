import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "wallpaperBing"

    StyledText {
        width: parent.width
        text: "A wallpaper downloader from Bing"
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

    ToggleSetting {
        settingKey: "GnomeExtensionBingWallpaperCompatibility"
        label: "Enable compatibility with\nGnome Extension Bing Wallpaper"
        description: "Store images in the same location as the Gnome Extension Bing Wallpaper (usually ~/Pictures/BingWallpaper)"
        defaultValue: false
    }
    
    ToggleSetting {
        settingKey: "enableDailyRefresh"
        label: "Enable daily refresh at specific time"
        description: "Change the wallpaper only at a specific time each day (replaces the 3-hour check). If Bing has not published today's image yet, it retries every 30 minutes."
        defaultValue: false
    }

    StringSetting {
        settingKey: "dailyRefreshTime"
        label: "Daily refresh time (24h format)"
        description: "Time to refresh wallpaper daily (format: HH:MM, e.g., 09:00 for 9 AM). Only used if daily refresh is enabled above."
        defaultValue: "09:00"
    }
}
