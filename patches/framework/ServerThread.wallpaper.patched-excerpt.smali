# services.jar - ServerThread.run(): re-add WallpaperManagerService, which the
# vendor build removed (its local slot and the systemRunning() call in the
# systemReady callback are still there). Inserted immediately before the
# WindowManagerService.detectSafeMode() call.
    # Wallpaper service: the vendor build dropped its creation (the local
    # slot and the systemReady callback that calls systemRunning() are both
    # still here), so WallpaperManagerService never registered and every
    # wallpaper call failed with "WallpaperService not running". Recreate it,
    # guarded like the stock code so a failure cannot take system_server down.
    :try_start_wp
    new-instance v0, Lcom/android/server/WallpaperManagerService;

    invoke-direct {v0, v5}, Lcom/android/server/WallpaperManagerService;-><init>(Landroid/content/Context;)V

    move-object/from16 v145, v0

    const-string v7, "wallpaper"

    invoke-static {v7, v0}, Landroid/os/ServiceManager;->addService(Ljava/lang/String;Landroid/os/IBinder;)V
    :try_end_wp
    .catch Ljava/lang/Throwable; {:try_start_wp .. :try_end_wp} :catch_wp

    goto :goto_wp_done

    :catch_wp
    move-exception v7

    const/16 v145, 0x0

    :goto_wp_done
    