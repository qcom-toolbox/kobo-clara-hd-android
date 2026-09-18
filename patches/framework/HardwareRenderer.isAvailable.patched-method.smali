# framework.jar — android.view.HardwareRenderer.isAvailable(), patched
.method public static isAvailable()Z
    .registers 1

    .prologue
    # Kobo: the only GLES 2.0 driver is SwiftShader (CPU). Keep app UIs on
    # the Skia software path instead of HWUI; apps that use GL directly
    # (GLSurfaceView etc.) are unaffected.
    const/4 v0, 0x0

    return v0
.end method
