## Process this with automake to create Makefile.in

AUTOMAKE_OPTIONS = foreign

SUBDIRS = src conf

## Files to distribute in 'make dist'
EXTRA_DIST = ntripcaster.service

install-data-local:
	$(MKDIR_P) $(DESTDIR)$(NTRIPCASTER_LOGDIR_INST)
	$(MKDIR_P) $(DESTDIR)$(SYSTEMD_UNIT_DIR)
	$(INSTALL_DATA) $(srcdir)/ntripcaster.service \
	    $(DESTDIR)$(SYSTEMD_UNIT_DIR)/ntripcaster.service
	@echo ""
	@echo "systemd unit installed to: $(DESTDIR)$(SYSTEMD_UNIT_DIR)/ntripcaster.service"
	@echo "To enable: systemctl daemon-reload && systemctl enable ntripcaster"
