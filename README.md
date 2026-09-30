# Wallpaper of the Day Widget

A fresh new daily wallpaper downloaded from a famous portal.

## Features

Download the daily image from Bing and set it as your desktop background.

The plugin checks for a new image every 3 hours (and optionally at a fixed daily time).
Network access is limited to `www.bing.com` (the `HPImageArchive` API and the image itself).

## Installation

1. Open DMS Settings → Plugins
2. Click "Scan for Plugins"
3. Browse for `Wallpaper of the Day` 3rd party plugin
4. Install and enable it

## Settings

No settings required.

## Requirements

- `curl`
- `inotify-tools`
- `libnotify` (`notify-send`, used for the optional desktop notification)
