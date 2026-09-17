.method private isScreenOnInternal()Z
    .registers 3

    .prologue
    .line 2009
    iget-boolean v0, p0, Lcom/android/server/power/PowerManagerService;->mSystemReady:Z

    if-eqz v0, :cond_a

    iget-object v0, p0, Lcom/android/server/power/PowerManagerService;->mDisplayPowerRequest:Lcom/android/server/power/DisplayPowerRequest;

    iget v0, v0, Lcom/android/server/power/DisplayPowerRequest;->screenState:I

    if-eqz v0, :cond_c

    :cond_a
    const/4 v0, 0x1

    return v0

    :cond_c
    const/4 v0, 0x0

    return v0
.end method

.method private setScreenBrightnessOverrideFromWindowManagerInternal(I)V
    .registers 4
    .param p1, "brightness"    # I

    .prologue
    .line 2299
    return-void
.end method

.method private setUserActivityTimeoutOverrideFromWindowManagerInternal(J)V
    .registers 7
    .param p1, "timeoutMillis"    # J

    .prologue
    .line 2343
    return-void
.end method
