.method final verifyBroadcastLocked(Landroid/content/Intent;)Landroid/content/Intent;
    .registers 7
    .param p1, "intent"    # Landroid/content/Intent;

    .prologue
    const/high16 v4, 0x40000000    # 2.0f

    .line 13716
    if-eqz p1, :cond_13

    invoke-virtual {p1}, Landroid/content/Intent;->hasFileDescriptors()Z

    move-result v2

    const/4 v3, 0x1

    if-ne v2, v3, :cond_13

    .line 13717
    new-instance v2, Ljava/lang/IllegalArgumentException;

    const-string v3, "File descriptors passed in Intent"

    invoke-direct {v2, v3}, Ljava/lang/IllegalArgumentException;-><init>(Ljava/lang/String;)V

    throw v2

    .line 13720
    :cond_13
    invoke-virtual {p1}, Landroid/content/Intent;->getFlags()I

    move-result v0

    .line 13722
    .local v0, "flags":I
    iget-boolean v2, p0, Lcom/android/server/am/ActivityManagerService;->mProcessesReady:Z

    if-nez v2, :cond_29

    .line 13725
    const/high16 v2, 0x4000000

    and-int/2addr v2, v0

    if-eqz v2, :cond_36

    .line 13726
    new-instance v1, Landroid/content/Intent;

    invoke-direct {v1, p1}, Landroid/content/Intent;-><init>(Landroid/content/Intent;)V

    .line 13727
    .end local p1    # "intent":Landroid/content/Intent;
    .local v1, "intent":Landroid/content/Intent;
    invoke-virtual {v1, v4}, Landroid/content/Intent;->addFlags(I)Landroid/content/Intent;

    move-object p1, v1

    .line 13735
    .end local v1    # "intent":Landroid/content/Intent;
    .restart local p1    # "intent":Landroid/content/Intent;
    :cond_29
    const/high16 v2, 0x2000000

    and-int/2addr v2, v0

    if-eqz v2, :cond_59

    .line 13736
    new-instance v2, Ljava/lang/IllegalArgumentException;

    const-string v3, "Can\'t use FLAG_RECEIVER_BOOT_UPGRADE here"

    invoke-direct {v2, v3}, Ljava/lang/IllegalArgumentException;-><init>(Ljava/lang/String;)V

    throw v2

    .line 13728
    :cond_36
    and-int v2, v0, v4

    if-nez v2, :cond_29

    .line 13729
    const-string v2, "ActivityManager"

    new-instance v3, Ljava/lang/StringBuilder;

    invoke-direct {v3}, Ljava/lang/StringBuilder;-><init>()V

    const-string v4, "Attempt to launch receivers of broadcast intent "

    invoke-virtual {v3, v4}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v3

    invoke-virtual {v3, p1}, Ljava/lang/StringBuilder;->append(Ljava/lang/Object;)Ljava/lang/StringBuilder;

    move-result-object v3

    const-string v4, " before boot completion"

    invoke-virtual {v3, v4}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v3

    invoke-virtual {v3}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v3

    invoke-static {v2, v3}, Landroid/util/Slog;->e(Ljava/lang/String;Ljava/lang/String;)I

    .line 13731
    goto :goto_59

    .line 13740
    :cond_59
    :goto_59
    return-object p1
.end method
