************************
* Standard NtripCaster *
************************

Introduction
~~~~~~~~~~~~

The Standard NtripCaster is a software written in C Programming
Language for disseminating GNSS real-time data streams via Internet.
For details of Ntrip (Networked Transport of RTCM via Internet
Protocol) see its documentation available from
http://igs.ifag.de/index_ntrip.htm. You should understand the Ntrip
data dissemination technique when considering an installation of
the software.

The Standard NtripCaster software has been developed within the
framework of the EUREF-IP project,
see http://www.epncb.oma.be/euref_IP. It is derived from the ICECAST
Internet Radio as written for Linux platforms under GNU General
Public License (GPL). Please note that whenever you make software
available that contains or is based on your copy of the Standard
NtripCaster, you must also make your source code available - at
least on request.

This fork (yasunorioi/ntripcaster) adds:
  - Modern autoconf/automake compatibility (autoreconf -fi)
  - Correct config path resolution via --prefix (was hardcoded ".")
  - musl libc compatibility (Alpine Linux / OpenWrt)
  - systemd service unit with security hardening
  - Annotated configuration example (ntripcaster.conf.example)


Build Requirements
~~~~~~~~~~~~~~~~~~
  gcc (or clang), make, autoconf >= 2.65, automake >= 1.11
  musl-dev (Alpine) or glibc-dev (Debian/Ubuntu/CentOS)

Optional: libwrap (TCP wrappers), libreadline


Build & Install
~~~~~~~~~~~~~~~

1. Regenerate build system (only needed when cloning from git):

     cd ntripcaster0.1.5
     autoreconf -fi

2. Configure:

     ./configure --prefix=/usr/local/ntripcaster

   Common options:
     --prefix=DIR           Install root (default: /usr/local/ntripcaster)
     --sysconfdir=DIR       Config directory (default: PREFIX/conf)
     --with-systemdunitdir=DIR  systemd unit dir (default: PREFIX/lib/systemd/system)

3. Build:

     make

4. Install (as root):

     sudo make install

   This installs:
     PREFIX/bin/ntripcaster         — server binary
     PREFIX/conf/ntripcaster.conf   — config file (created from example if absent)
     PREFIX/conf/sourcetable.dat    — mountpoint sourcetable (created if absent)
     PREFIX/conf/ntripcaster.conf.example  — annotated reference copy
     PREFIX/logs/                   — log directory (created empty)
     PREFIX/lib/systemd/system/ntripcaster.service  — systemd unit


Configuration
~~~~~~~~~~~~~

Edit the configuration file before starting the server:

     sudo nano /usr/local/ntripcaster/conf/ntripcaster.conf

Key settings to change from defaults:

  server_name   — fully-qualified hostname (e.g. caster.example.com)
  encoder_password — password for NtripServer (base station) connections
  port          — listening port (default: 2101, IANA-assigned for NTRIP)
  logdir        — log file directory

Edit the sourcetable file to list your mountpoints:

     sudo nano /usr/local/ntripcaster/conf/sourcetable.dat

See conf/NtripSourcetable.doc for the sourcetable format specification.
Include the global NtripInfoCaster entry in your sourcetable:

  CAS;rtcm-ntrip.org;2101;NtripInfoCaster;BKG;0;DEU;50.12;8.69;http://www.rtcm-ntrip.org/home


Running with systemd
~~~~~~~~~~~~~~~~~~~~

1. Create a dedicated unprivileged user:

     sudo useradd -r -s /sbin/nologin ntripcaster

2. Set ownership of install directories:

     sudo chown -R ntripcaster:ntripcaster /usr/local/ntripcaster/logs
     sudo chown -R ntripcaster:ntripcaster /usr/local/ntripcaster/conf

3. Install the systemd unit (already done by make install, or manually):

     sudo cp ntripcaster0.1.5/ntripcaster.service \
             /etc/systemd/system/ntripcaster.service

   For system-wide install path (/usr/local/ntripcaster), the unit installed
   by make install is at PREFIX/lib/systemd/system/ntripcaster.service.
   Copy it to /etc/systemd/system/ for systemd to recognise it:

     sudo cp /usr/local/ntripcaster/lib/systemd/system/ntripcaster.service \
             /etc/systemd/system/ntripcaster.service

4. Enable and start:

     sudo systemctl daemon-reload
     sudo systemctl enable ntripcaster
     sudo systemctl start ntripcaster

5. Check status and logs:

     systemctl status ntripcaster
     journalctl -u ntripcaster -f

   The server also writes to PREFIX/logs/ntripcaster.log.

6. Optional: environment overrides via /etc/ntripcaster/ntripcaster.env
   (EnvironmentFile in the unit file):

     sudo mkdir -p /etc/ntripcaster
     echo "# Add environment overrides here" | sudo tee /etc/ntripcaster/ntripcaster.env


Alpine Linux / musl build
~~~~~~~~~~~~~~~~~~~~~~~~~

This fork is compatible with Alpine Linux and other musl-based systems:

     apk add gcc make musl-dev autoconf automake
     cd ntripcaster0.1.5
     autoreconf -fi
     ./configure --prefix=/usr/local/ntripcaster
     make
     sudo make install


License
~~~~~~~
NtripCaster, a GNSS real-time data server
Copyright (C) 2004-2008 BKG (German Federal Agency for Cartography and Geodesy)

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA


Contact and webpage
~~~~~~~~~~~~~~~~~~~~
Original NtripCaster: http://igs.bkg.bund.de/index_ntrip.htm
This fork: https://github.com/yasunorioi/ntripcaster
