#!/system/bin/sh
# E-ink: the window and transition animations are pure ghosting, so pin
# both to 0. animator_duration_scale stays at 1 on purpose: SystemUI's
# navigation bar returns from the dimmed "lights out" state a game asks for
# through a property animator, and with the scale at 0 that transition
# never repainted -- the nav bar stayed a blank black strip with the
# buttons invisible until something else forced a redraw.
# Settings live in /data, so this re-applies them after a wipe; it is
# idempotent.
while [ "$(getprop sys.boot_completed)" != "1" ]; do
	sleep 2
done
settings put global window_animation_scale 0
settings put global transition_animation_scale 0
settings put global animator_duration_scale 1
