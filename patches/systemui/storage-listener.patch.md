# Stock SystemUI 4.4.2 against the Tolino framework

`StorageNotification$StorageNotificationEventListener` and `UsbStorageActivity$2`:

```smali
.super Landroid/os/storage/StorageEventListener;

# Tolino framework: StorageManager.(un)registerListener take this interface
.implements Landroid/os/storage/IStorageEventListener;
```

Call sites in `StorageNotification` and `UsbStorageActivity`:

```smali
-Landroid/os/storage/StorageManager;->registerListener(Landroid/os/storage/StorageEventListener;)V
+Landroid/os/storage/StorageManager;->registerListener(Landroid/os/storage/IStorageEventListener;)V
-Landroid/os/storage/StorageManager;->unregisterListener(Landroid/os/storage/StorageEventListener;)V
+Landroid/os/storage/StorageManager;->unregisterListener(Landroid/os/storage/IStorageEventListener;)V
```
