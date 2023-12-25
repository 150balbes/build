## Description

This folder contains the structure for building debian packages
as described in the documentation:
https://www.debian.org/doc/debian-policy/ch-source.html#source-packages
https://www.debian.org/doc/devel-manuals#maint-guide

```bash
:~$ tree packages/deb-build/
packages/deb-build/
├── htop
│   └── debian
│       ├── changelog
│       ├── control
│       ├── copyright
│       ├── docs
│       ├── install
│       ├── rules
│       ├── source
│       │   └── format
│       ├── upstream
│       │   └── metadata
│       └── watch
└── README.md
```

If the package name is not in this directory, but the source package exists
in the base distribution, then the source package can be downloaded to
the cache/sources/pkgname directory and built again.
You will be able to move it to this directory yourself.

initial state: the htop package has been added.

In the future, all packages that we will support will be added here.
