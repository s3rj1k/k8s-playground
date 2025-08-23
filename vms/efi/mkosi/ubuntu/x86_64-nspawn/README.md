**Kubernetes OS Image.**

*Install mkosi:*

    pipx install git+https://github.com/systemd/mkosi.git
    export PATH="$HOME/.local/bin:$PATH"
    mkosi --version

*Build nspawn directory image:*

    mkosi --format=directory build

*Run nspawn directory image:*

    # https://wiki.archlinux.org/title/Systemd-nspawn
    # https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html

    systemd-nspawn --boot --directory=image --resolv-conf=off [--network-veth | --network-macvlan=eth0 | --network-ipvlan=eth0 | --network-interface=ens4]

*Set console size:*

    stty rows 40 cols 160
