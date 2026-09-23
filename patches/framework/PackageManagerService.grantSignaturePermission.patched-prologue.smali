# services.jar - PackageManagerService.grantSignaturePermission(): inserted
# right after the method's .prologue.
.method private grantSignaturePermission(Ljava/lang/String;Landroid/content/pm/PackageParser$Package;Lcom/android/server/pm/BasePermission;Ljava/util/HashSet;)Z
    # Grant signature permissions to privileged (/system/priv-app) apps.
    # The stock AOSP SystemUI/Keyguard used here are not signed with this
    # vendor's platform key, so they would otherwise be refused
    # STATUS_BAR_SERVICE, MANAGE_APP_TOKENS, etc.
    invoke-static {p2}, Lcom/android/server/pm/PackageManagerService;->isPrivilegedApp(Landroid/content/pm/PackageParser$Package;)Z

    move-result v4

    if-eqz v4, :cond_not_privileged

    return v4

    :cond_not_privileged
