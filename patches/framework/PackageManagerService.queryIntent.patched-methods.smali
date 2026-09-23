# PackageManagerService.queryIntentServices / queryIntentContentProviders
#
# When the intent names a package ("query this package's services"), AOSP 4.4
# returns null if that package is not installed; later Android versions return
# an empty list. Every Play-billing and Play-services client does exactly that
# query, and on a device without Google apps it then dereferences the null:
#
#   java.lang.NullPointerException
#       at com.fingersoft.billing.util.IabHelper.startSetup(IabHelper.java:269)
#
# Returning an empty list is what those callers expect and what the later
# platform does, so apps take their "billing unavailable" path instead of
# crashing. Both methods are recorded here as patched; the only change in each
# is the :cond_84 branch below.
.method public queryIntentContentProviders(Landroid/content/Intent;Ljava/lang/String;II)Ljava/util/List;
    .registers 22
    .param p1, "intent"    # Landroid/content/Intent;
    .param p2, "resolvedType"    # Ljava/lang/String;
    .param p3, "flags"    # I
    .param p4, "userId"    # I
    .annotation system Ldalvik/annotation/Signature;
        value = {
            "(",
            "Landroid/content/Intent;",
            "Ljava/lang/String;",
            "II)",
            "Ljava/util/List",
            "<",
            "Landroid/content/pm/ResolveInfo;",
            ">;"
        }
    .end annotation

    .prologue
    .line 3153
    sget-object v4, Lcom/android/server/pm/PackageManagerService;->sUserManager:Lcom/android/server/pm/UserManagerService;

    move/from16 v0, p4

    invoke-virtual {v4, v0}, Lcom/android/server/pm/UserManagerService;->exists(I)Z

    move-result v4

    if-nez v4, :cond_f

    invoke-static {}, Ljava/util/Collections;->emptyList()Ljava/util/List;

    move-result-object v11

    .line 3183
    :cond_e
    :goto_e
    return-object v11

    .line 3154
    :cond_f
    invoke-virtual/range {p1 .. p1}, Landroid/content/Intent;->getComponent()Landroid/content/ComponentName;

    move-result-object v10

    .line 3155
    .local v10, "comp":Landroid/content/ComponentName;
    if-nez v10, :cond_23

    .line 3156
    invoke-virtual/range {p1 .. p1}, Landroid/content/Intent;->getSelector()Landroid/content/Intent;

    move-result-object v4

    if-eqz v4, :cond_23

    .line 3157
    invoke-virtual/range {p1 .. p1}, Landroid/content/Intent;->getSelector()Landroid/content/Intent;

    move-result-object p1

    .line 3158
    invoke-virtual/range {p1 .. p1}, Landroid/content/Intent;->getComponent()Landroid/content/ComponentName;

    move-result-object v10

    .line 3161
    :cond_23
    if-eqz v10, :cond_42

    .line 3162
    new-instance v11, Ljava/util/ArrayList;

    const/4 v4, 0x1

    invoke-direct {v11, v4}, Ljava/util/ArrayList;-><init>(I)V

    .line 3163
    .local v11, "list":Ljava/util/List;, "Ljava/util/List<Landroid/content/pm/ResolveInfo;>;"
    move-object/from16 v0, p0

    move/from16 v1, p3

    move/from16 v2, p4

    invoke-virtual {v0, v10, v1, v2}, Lcom/android/server/pm/PackageManagerService;->getProviderInfo(Landroid/content/ComponentName;II)Landroid/content/pm/ProviderInfo;

    move-result-object v12

    .line 3164
    .local v12, "pi":Landroid/content/pm/ProviderInfo;
    if-eqz v12, :cond_e

    .line 3165
    new-instance v15, Landroid/content/pm/ResolveInfo;

    invoke-direct {v15}, Landroid/content/pm/ResolveInfo;-><init>()V

    .line 3166
    .local v15, "ri":Landroid/content/pm/ResolveInfo;
    iput-object v12, v15, Landroid/content/pm/ResolveInfo;->providerInfo:Landroid/content/pm/ProviderInfo;

    .line 3167
    invoke-interface {v11, v15}, Ljava/util/List;->add(Ljava/lang/Object;)Z

    goto :goto_e

    .line 3173
    .end local v11    # "list":Ljava/util/List;, "Ljava/util/List<Landroid/content/pm/ResolveInfo;>;"
    .end local v12    # "pi":Landroid/content/pm/ProviderInfo;
    .end local v15    # "ri":Landroid/content/pm/ResolveInfo;
    :cond_42
    move-object/from16 v0, p0

    iget-object v0, v0, Lcom/android/server/pm/PackageManagerService;->mPackages:Ljava/util/HashMap;

    move-object/from16 v16, v0

    monitor-enter v16

    .line 3174
    :try_start_49
    invoke-virtual/range {p1 .. p1}, Landroid/content/Intent;->getPackage()Ljava/lang/String;

    move-result-object v14

    .line 3175
    .local v14, "pkgName":Ljava/lang/String;
    if-nez v14, :cond_64

    .line 3176
    move-object/from16 v0, p0

    iget-object v4, v0, Lcom/android/server/pm/PackageManagerService;->mProviders:Lcom/android/server/pm/PackageManagerService$ProviderIntentResolver;

    move-object/from16 v0, p1

    move-object/from16 v1, p2

    move/from16 v2, p3

    move/from16 v3, p4

    invoke-virtual {v4, v0, v1, v2, v3}, Lcom/android/server/pm/PackageManagerService$ProviderIntentResolver;->queryIntent(Landroid/content/Intent;Ljava/lang/String;II)Ljava/util/List;

    move-result-object v11

    monitor-exit v16

    goto :goto_e

    .line 3184
    .end local v14    # "pkgName":Ljava/lang/String;
    :catchall_61
    move-exception v4

    monitor-exit v16
    :try_end_63
    .catchall {:try_start_49 .. :try_end_63} :catchall_61

    throw v4

    .line 3178
    .restart local v14    # "pkgName":Ljava/lang/String;
    :cond_64
    :try_start_64
    move-object/from16 v0, p0

    iget-object v4, v0, Lcom/android/server/pm/PackageManagerService;->mPackages:Ljava/util/HashMap;

    invoke-virtual {v4, v14}, Ljava/util/HashMap;->get(Ljava/lang/Object;)Ljava/lang/Object;

    move-result-object v13

    check-cast v13, Landroid/content/pm/PackageParser$Package;

    .line 3179
    .local v13, "pkg":Landroid/content/pm/PackageParser$Package;
    if-eqz v13, :cond_84

    .line 3180
    move-object/from16 v0, p0

    iget-object v4, v0, Lcom/android/server/pm/PackageManagerService;->mProviders:Lcom/android/server/pm/PackageManagerService$ProviderIntentResolver;

    iget-object v8, v13, Landroid/content/pm/PackageParser$Package;->providers:Ljava/util/ArrayList;

    move-object/from16 v5, p1

    move-object/from16 v6, p2

    move/from16 v7, p3

    move/from16 v9, p4

    invoke-virtual/range {v4 .. v9}, Lcom/android/server/pm/PackageManagerService$ProviderIntentResolver;->queryIntentForPackage(Landroid/content/Intent;Ljava/lang/String;ILjava/util/ArrayList;I)Ljava/util/List;

    move-result-object v11

    monitor-exit v16

    goto :goto_e

    .line 3183
    :cond_84
    # AOSP 4.4 returns null here when the named package is not installed;
    # later versions return an empty list. An app that queries a specific
    # package -- anything touching Play billing or Play services -- then
    # dies with a NullPointerException on a device without that package
    # (Hill Climb Racing, IabHelper.startSetup).
    new-instance v11, Ljava/util/ArrayList;

    invoke-direct {v11}, Ljava/util/ArrayList;-><init>()V

    monitor-exit v16
    :try_end_86
    .catchall {:try_start_64 .. :try_end_86} :catchall_61

    goto :goto_e
.end method

.method public queryIntentServices(Landroid/content/Intent;Ljava/lang/String;II)Ljava/util/List;
    .registers 22
    .param p1, "intent"    # Landroid/content/Intent;
    .param p2, "resolvedType"    # Ljava/lang/String;
    .param p3, "flags"    # I
    .param p4, "userId"    # I
    .annotation system Ldalvik/annotation/Signature;
        value = {
            "(",
            "Landroid/content/Intent;",
            "Ljava/lang/String;",
            "II)",
            "Ljava/util/List",
            "<",
            "Landroid/content/pm/ResolveInfo;",
            ">;"
        }
    .end annotation

    .prologue
    .line 3116
    sget-object v4, Lcom/android/server/pm/PackageManagerService;->sUserManager:Lcom/android/server/pm/UserManagerService;

    move/from16 v0, p4

    invoke-virtual {v4, v0}, Lcom/android/server/pm/UserManagerService;->exists(I)Z

    move-result v4

    if-nez v4, :cond_f

    invoke-static {}, Ljava/util/Collections;->emptyList()Ljava/util/List;

    move-result-object v11

    .line 3146
    :cond_e
    :goto_e
    return-object v11

    .line 3117
    :cond_f
    invoke-virtual/range {p1 .. p1}, Landroid/content/Intent;->getComponent()Landroid/content/ComponentName;

    move-result-object v10

    .line 3118
    .local v10, "comp":Landroid/content/ComponentName;
    if-nez v10, :cond_23

    .line 3119
    invoke-virtual/range {p1 .. p1}, Landroid/content/Intent;->getSelector()Landroid/content/Intent;

    move-result-object v4

    if-eqz v4, :cond_23

    .line 3120
    invoke-virtual/range {p1 .. p1}, Landroid/content/Intent;->getSelector()Landroid/content/Intent;

    move-result-object p1

    .line 3121
    invoke-virtual/range {p1 .. p1}, Landroid/content/Intent;->getComponent()Landroid/content/ComponentName;

    move-result-object v10

    .line 3124
    :cond_23
    if-eqz v10, :cond_42

    .line 3125
    new-instance v11, Ljava/util/ArrayList;

    const/4 v4, 0x1

    invoke-direct {v11, v4}, Ljava/util/ArrayList;-><init>(I)V

    .line 3126
    .local v11, "list":Ljava/util/List;, "Ljava/util/List<Landroid/content/pm/ResolveInfo;>;"
    move-object/from16 v0, p0

    move/from16 v1, p3

    move/from16 v2, p4

    invoke-virtual {v0, v10, v1, v2}, Lcom/android/server/pm/PackageManagerService;->getServiceInfo(Landroid/content/ComponentName;II)Landroid/content/pm/ServiceInfo;

    move-result-object v15

    .line 3127
    .local v15, "si":Landroid/content/pm/ServiceInfo;
    if-eqz v15, :cond_e

    .line 3128
    new-instance v14, Landroid/content/pm/ResolveInfo;

    invoke-direct {v14}, Landroid/content/pm/ResolveInfo;-><init>()V

    .line 3129
    .local v14, "ri":Landroid/content/pm/ResolveInfo;
    iput-object v15, v14, Landroid/content/pm/ResolveInfo;->serviceInfo:Landroid/content/pm/ServiceInfo;

    .line 3130
    invoke-interface {v11, v14}, Ljava/util/List;->add(Ljava/lang/Object;)Z

    goto :goto_e

    .line 3136
    .end local v11    # "list":Ljava/util/List;, "Ljava/util/List<Landroid/content/pm/ResolveInfo;>;"
    .end local v14    # "ri":Landroid/content/pm/ResolveInfo;
    .end local v15    # "si":Landroid/content/pm/ServiceInfo;
    :cond_42
    move-object/from16 v0, p0

    iget-object v0, v0, Lcom/android/server/pm/PackageManagerService;->mPackages:Ljava/util/HashMap;

    move-object/from16 v16, v0

    monitor-enter v16

    .line 3137
    :try_start_49
    invoke-virtual/range {p1 .. p1}, Landroid/content/Intent;->getPackage()Ljava/lang/String;

    move-result-object v13

    .line 3138
    .local v13, "pkgName":Ljava/lang/String;
    if-nez v13, :cond_64

    .line 3139
    move-object/from16 v0, p0

    iget-object v4, v0, Lcom/android/server/pm/PackageManagerService;->mServices:Lcom/android/server/pm/PackageManagerService$ServiceIntentResolver;

    move-object/from16 v0, p1

    move-object/from16 v1, p2

    move/from16 v2, p3

    move/from16 v3, p4

    invoke-virtual {v4, v0, v1, v2, v3}, Lcom/android/server/pm/PackageManagerService$ServiceIntentResolver;->queryIntent(Landroid/content/Intent;Ljava/lang/String;II)Ljava/util/List;

    move-result-object v11

    monitor-exit v16

    goto :goto_e

    .line 3147
    .end local v13    # "pkgName":Ljava/lang/String;
    :catchall_61
    move-exception v4

    monitor-exit v16
    :try_end_63
    .catchall {:try_start_49 .. :try_end_63} :catchall_61

    throw v4

    .line 3141
    .restart local v13    # "pkgName":Ljava/lang/String;
    :cond_64
    :try_start_64
    move-object/from16 v0, p0

    iget-object v4, v0, Lcom/android/server/pm/PackageManagerService;->mPackages:Ljava/util/HashMap;

    invoke-virtual {v4, v13}, Ljava/util/HashMap;->get(Ljava/lang/Object;)Ljava/lang/Object;

    move-result-object v12

    check-cast v12, Landroid/content/pm/PackageParser$Package;

    .line 3142
    .local v12, "pkg":Landroid/content/pm/PackageParser$Package;
    if-eqz v12, :cond_84

    .line 3143
    move-object/from16 v0, p0

    iget-object v4, v0, Lcom/android/server/pm/PackageManagerService;->mServices:Lcom/android/server/pm/PackageManagerService$ServiceIntentResolver;

    iget-object v8, v12, Landroid/content/pm/PackageParser$Package;->services:Ljava/util/ArrayList;

    move-object/from16 v5, p1

    move-object/from16 v6, p2

    move/from16 v7, p3

    move/from16 v9, p4

    invoke-virtual/range {v4 .. v9}, Lcom/android/server/pm/PackageManagerService$ServiceIntentResolver;->queryIntentForPackage(Landroid/content/Intent;Ljava/lang/String;ILjava/util/ArrayList;I)Ljava/util/List;

    move-result-object v11

    monitor-exit v16

    goto :goto_e

    .line 3146
    :cond_84
    # AOSP 4.4 returns null here when the named package is not installed;
    # later versions return an empty list. An app that queries a specific
    # package -- anything touching Play billing or Play services -- then
    # dies with a NullPointerException on a device without that package
    # (Hill Climb Racing, IabHelper.startSetup).
    new-instance v11, Ljava/util/ArrayList;

    invoke-direct {v11}, Ljava/util/ArrayList;-><init>()V

    monitor-exit v16
    :try_end_86
    .catchall {:try_start_64 .. :try_end_86} :catchall_61

    goto :goto_e
.end method
