## Continuation:
### This branch will be developed further and will receive some updates and improvements only in this repository.
### If you use this branch, then please open bug reports only in this repository and please do not discuss it on the Armbian forum.



## Table of contents

- [What this project does?](#what-this-project-does)
- [Getting started](#getting-started)
- [Project structure](#project-structure)
- [Contribution](#contribution)
- [License](#license)

## What this project does?

- Builds custom kernel, image or a distribution optimized for low resource HW such as single board computers,
- Include filesystem generation, low-level control software, kernel image and bootloader compilation,
- Provides a consistent user experience by keeping system standards across different platforms.

## Getting started

### Basic requirements

- x86_64 or aarch64 machine with at least 2GB of memory and ~45GB of disk space for a virtual machine, container or bare metal installation
- Ubuntu Jammy 22.04.x amd64 or aarch64 for native building or any [Docker](https://docs.armbian.com/Developer-Guide_Building-with-Docker/) capable amd64 / aarch64 Linux for containerised
- Superuser rights (configured sudo or root access).

### Simply start with the build script

```bash
apt-get -y install git
git clone --depth=1 --branch=pbs-master https://github.com/The-going/armbian-build
cd build
./compile.sh
```

- Interactive graphical interface.
- The workspace will be prepared by installing the necessary dependencies and sources.
- It guides the entire process until a kernel package or ready-to-use image of the SD card is created.

### Build parameter examples

Show work in progress areas in interactive mode:

```bash
./compile.sh EXPERT="yes"
```

Run build framework inside Docker container:

```bash
./compile.sh docker
```

Build minimal CLI Armbian Focal image for Orangepi Zero. Use modern kernel and write image to the SD card:

```bash
./compile.sh \
BOARD=orangepizero \
BRANCH=current \
RELEASE=focal \
BUILD_MINIMAL=yes \
BUILD_DESKTOP=no \
BUILD_ONLY=default \
KERNEL_CONFIGURE=no \
CARD_DEVICE="/dev/sdX"
```
Build or rebuild the system source package in an isolated chroot environment
Exampe for `htop`:

```bash
mkdir -p userpatches/packages/deb-build/htop
./compile.sh BUILD_ONLY="chroot,htop"
```
There is a command line option for debugging:

```bash
./compile.sh BUILD_ONLY="chroot,htop" CMDLINE="yes"
...
cd /root
./build.sh
...
```

## Project structure

```text
├── cache                                Work / cache directory
│   ├── rootfs                           Compressed userspace packages cache
│   ├── sources                          Kernel, u-boot and various drivers sources.
│   ├── toolchains                       External cross compilers from Linaro™ or ARM™
├── config                               Packages repository configurations
│   ├── targets.conf                     Board build target configuration
│   ├── boards                           Board configurations
│   ├── bootenv                          Initial boot loaders environments per family
│   ├── bootscripts                      Initial Boot loaders scripts per family
│   ├── cli                              CLI packages configurations per distribution
│   ├── desktop                          Desktop packages configurations per distribution
│   ├── distributions                    Distributions settings
│   ├── kernel                           Kernel build configurations per family
│   ├── sources                          Kernel and u-boot sources locations and scripts
│   ├── templates                        User configuration templates which populate userpatches
│   └── torrents                         External compiler and rootfs cache torrents
├── extensions                           extend build system with specific functionality
├── lib                                  Main build framework libraries
├── output                               Build artifact
│   └── deb                              Deb packages
│   └── images                           Bootable images - RAW or compressed
│   └── debug                            Patch and build logs
│   └── config                           Kernel configuration export location
│   └── patch                            Created patches location
├── packages                             Support scripts, binary blobs, packages
│   ├── blobs                            Wallpapers, various configs, closed source bootloaders
│   ├── bsp-cli                          Automatically added to armbian-bsp-cli package 
│   ├── bsp-desktop                      Automatically added to armbian-bsp-desktopo package
│   ├── bsp                              Scripts and configs overlay for rootfs
│   └── deb-build                        Source packages in expanded form or rules
├── patch                                Collection of patches
│   ├── atf                              ARM trusted firmware
│   ├── kernel                           Linux kernel patches
|   |   └── family-branch                Per kernel family and branch
│   ├── misc                             Linux kernel packaging patches
│   └── u-boot                           Universal boot loader patches
|       ├── u-boot-board                 For specific board
|       └── u-boot-family                For entire kernel family
├── tools                                Tools for dealing with kernel patches and configs
└── userpatches                          User: configuration patching area
    ├── lib.config                       User: framework common config/override file
    ├── config-default.conf              User: default user config file
    ├── customize-image.sh               User: script will execute just before closing the image
    ├── packages
    |   └── deb-build                    User: Source packages in expanded form or archive or rules
    ├── atf                              User: ARM trusted firmware
    ├── kernel                           User: Linux kernel per kernel family
    ├── misc                             User: various
    └── u-boot                           User: universal boot loader patches
```

## Contribution

### You are an ordinary user who wants to assemble an image for his board.

But you get an error when assembling or the image is not working properly.
Please open a question/[issues](https://github.com/The-going/armbian-build/issues).

### You are a software developer.

And you need additional functionality in the image assembly system for a small board.

Create a discussion/[issues](https://github.com/The-going/armbian-build/issues) and/or add your changes and make a pull request.

## License

This software is published under the GPL-2.0 License license.
