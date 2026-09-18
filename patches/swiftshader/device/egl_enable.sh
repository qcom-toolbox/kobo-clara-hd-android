#!/system/bin/sh
mkdir -p /system/lib/egl_android_disabled
mv /system/lib/egl/libGLES_android.so /system/lib/egl_android_disabled/
for f in libEGL_swiftshader.so libGLESv1_CM_swiftshader.so libGLESv2_swiftshader.so; do
	cat /data/local/tmp/sf/$f > /system/lib/egl/$f
	chmod 644 /system/lib/egl/$f
	rm -f /system/lib/egl_swiftshader_disabled/$f
done
sync
ls -l /system/lib/egl /system/lib/egl_android_disabled
