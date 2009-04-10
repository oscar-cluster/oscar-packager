DESTDIR=

TOPDIR=..
#include $(TOPDIR)/Config.mk

FILES := core_stable_6.0.cfg core_unstable.cfg included_stable_6.0.cfg \
	included_unstable.cfg core_opkgs_6.0.2.cfg core_opkgs_unstable.cfg \
	core_stable_6.0.2.cfg core_stable_6.0.1.cfg
SUBDIRS :=

all:
	for dir in ${SUBDIRS} ; do ( cd $$dir ; ${MAKE} all ) ; done

install:
	install -d -m 0755 $(DESTDIR)/etc/oscar/oscar-packager
	install    -m 0755 $(FILES) $(DESTDIR)/etc/oscar/oscar-packager
	for dir in ${SUBDIRS} ; do ( cd $$dir ; ${MAKE} install ) ; done

uninstall:
	cd $(DESTDIR)/etc/oscar/oscar-packager; rm -f $(SCRIPTS)
	for dir in ${SUBDIRS} ; do ( cd $$dir ; ${MAKE} uninstall ) ; done

clean:
	rm -f *~
