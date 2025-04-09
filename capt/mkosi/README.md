**Debian K8s OS Image.**

*Build RAW image:*

    mkosi build

*Build (force) RAW image:*

    mkosi -f build

*Build (force, autologin) RAW image:*

    mkosi --force --autologin build

*Convert RAW image to QCOW2:*

    qemu-img convert -f raw -O qcow2 -c debian.vm.raw debian.vm.qcow2

*Convert RAW image to VDI:*

    VBoxManage convertfromraw debian.vm.raw --format vdi debian.vm.vdi

*Build (force) OCI directory layout image:*

    mkosi --force --format=oci build

*Run RAW image using qemu:*

    mkosi qemu

*Set console size:*

    stty rows 40 cols 1000
