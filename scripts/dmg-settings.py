import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (130, 154), "Applications": (390, 154)}

background = defines["background"]
window_rect = ((160, 160), (520, 320))
icon_size = 128
text_size = 14
show_status_bar = False
show_pathbar = False
show_toolbar = False
show_sidebar = False
