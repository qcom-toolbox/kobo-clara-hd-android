# PhoneStatusBar.makeStatusBarView(), nav bar decision (patched excerpt)
    :try_start_bf
    iget-object v0, p0, Lcom/android/systemui/statusbar/phone/PhoneStatusBar;->mWindowManagerService:Landroid/view/IWindowManager;

    invoke-interface {v0}, Landroid/view/IWindowManager;->hasNavigationBar()Z

    # Tolino: shown only if no HOME/BACK key exists; restored to stock AOSP
    move-result v0

    .line 447
    :goto_d3
    if-eqz v0, :cond_f7

