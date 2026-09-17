#!/system/bin/sh
# Delays the binder_probe test until well into boot (matching roughly when
# the real app process actually gets forked and hangs, tick ~30-40+ in
# earlier captures) so it runs under genuine concurrent system load --
# every earlier native reproduction ran within seconds of boot, with an
# essentially idle servicemanager, and always succeeded quickly. This is
# the one variable (real contention) not yet tested.
sleep 90
/binder_probe postfork 10003
