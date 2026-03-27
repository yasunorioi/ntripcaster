## Process this with automake to create Makefile.in

AUTOMAKE_OPTIONS = foreign

all:

## Install destination for config files (set by configure: $(prefix)/conf)
etcdir = $(NTRIPCASTER_ETCDIR_INST)

## .dist files are installed as-is (used as templates before first run)
## .example is installed alongside as a reference copy
nodist_etc_DATA = ntripcaster.conf.dist

## Distribute all source conf files
EXTRA_DIST = ntripcaster.conf.dist.in sourcetable.dat.dist \
             ntripcaster.conf.example NtripSourcetable.doc

## Install the annotated example config (never overwrites existing ntripcaster.conf)
install-data-local:
	$(MKDIR_P) $(DESTDIR)$(etcdir)
	$(INSTALL_DATA) $(srcdir)/ntripcaster.conf.example \
	    $(DESTDIR)$(etcdir)/ntripcaster.conf.example
	$(INSTALL_DATA) $(srcdir)/sourcetable.dat.dist \
	    $(DESTDIR)$(etcdir)/sourcetable.dat.dist
	@if test ! -f $(DESTDIR)$(etcdir)/ntripcaster.conf; then \
	    $(INSTALL_DATA) $(srcdir)/ntripcaster.conf.example \
	        $(DESTDIR)$(etcdir)/ntripcaster.conf; \
	    echo "Installed default ntripcaster.conf — edit before starting the server."; \
	else \
	    echo "ntripcaster.conf already exists, not overwriting."; \
	fi
	@if test ! -f $(DESTDIR)$(etcdir)/sourcetable.dat; then \
	    $(INSTALL_DATA) $(srcdir)/sourcetable.dat.dist \
	        $(DESTDIR)$(etcdir)/sourcetable.dat; \
	    echo "Installed default sourcetable.dat — edit to list your mountpoints."; \
	else \
	    echo "sourcetable.dat already exists, not overwriting."; \
	fi
