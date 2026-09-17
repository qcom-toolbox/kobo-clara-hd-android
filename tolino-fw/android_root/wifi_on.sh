#!/system/bin/sh
# The vendor's de.telekom.epub app is the only launcher in this build and
# its UI is slow/hard to use on this display, and the user wants a plain
# stock Android experience for connecting to wifi instead of navigating
# that app. There's no real Launcher.apk in this image to switch to as the
# actual home screen, but a genuine stock Settings.apk IS present -- so
# instead of relying on the Tolino UI at all, turn wifi on and jump
# straight to the real system wifi-settings screen (the same Activity a
# stock Android device would show), independent of whatever the epub app
# is doing underneath.
sleep 90
svc wifi enable > /wifi_on_output.txt 2>&1
sleep 5
am start -a android.settings.WIFI_SETTINGS >> /wifi_on_output.txt 2>&1
sync
