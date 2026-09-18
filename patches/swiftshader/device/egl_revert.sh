#!/system/bin/sh
mkdir -p /system/lib/egl_swiftshader_disabled
mv /system/lib/egl/libEGL_swiftshader.so /system/lib/egl/libGLESv1_CM_swiftshader.so /system/lib/egl/libGLESv2_swiftshader.so /system/lib/egl_swiftshader_disabled/
mv /system/lib/egl_android_disabled/libGLES_android.so /system/lib/egl/
sync
ls -l /system/lib/egl
