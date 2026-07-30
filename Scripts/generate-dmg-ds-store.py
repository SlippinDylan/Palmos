#!/usr/bin/python3

import os
import sys

from ds_store import DSStore
from mac_alias import Alias


def fail(message: str) -> None:
    raise SystemExit(f"DMG metadata generation failed: {message}")


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: generate-dmg-ds-store.py <mounted-volume> <app-name>")

    mount_point = os.path.realpath(sys.argv[1])
    app_name = sys.argv[2]
    if os.path.basename(app_name) != app_name or not app_name.endswith(".app"):
        fail(f"invalid app bundle name: {app_name}")

    app_path = os.path.join(mount_point, app_name)
    applications_path = os.path.join(mount_point, "Applications")
    background_path = os.path.join(mount_point, ".background", "background.png")
    if not os.path.isdir(app_path):
        fail(f"app bundle not found: {app_path}")
    if not os.path.islink(applications_path):
        fail(f"Applications symlink not found: {applications_path}")
    if not os.path.isfile(background_path):
        fail(f"background image not found: {background_path}")

    window_settings = {
        "ShowStatusBar": False,
        "WindowBounds": "{{200, 200}, {600, 400}}",
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "ShowTabView": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
    }
    icon_view_settings = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "backgroundImageAlias": Alias.for_file(background_path).to_bytes(),
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": True,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": 16.0,
        "iconSize": 96.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }

    ds_store_path = os.path.join(mount_point, ".DS_Store")
    if os.path.lexists(ds_store_path):
        os.unlink(ds_store_path)

    with DSStore.open(ds_store_path, "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = window_settings
        store["."]["icvp"] = icon_view_settings
        store["."]["icvl"] = ("type", b"icnv")
        store[app_name]["Iloc"] = (160, 180)
        store["Applications"]["Iloc"] = (440, 180)

    if not os.path.isfile(ds_store_path) or os.path.getsize(ds_store_path) == 0:
        fail(f".DS_Store was not created: {ds_store_path}")


if __name__ == "__main__":
    main()
