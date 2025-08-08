**Kubernetes OS Image.**

*Build RAW image:*

    mkosi build

*Build (force) RAW image:*

    mkosi -f build

*Convert RAW image to QCOW2:*

    qemu-img convert -f raw -O qcow2 -c image.vm.raw image.vm.qcow2

*Run RAW image using qemu:*

    mkosi qemu

*Set console size:*

    stty rows 40 cols 160

*NVIDIA related links*:

    https://docs.nvidia.com/dgx/dgx-os-7-user-guide/installing_on_ubuntu.html#installing-on-ubuntu
