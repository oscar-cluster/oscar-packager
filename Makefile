DESTDIR=

include ./Config.mk

SUBDIRS := bin doc etc lib

all:
	for dir in ${SUBDIRS} ; do ( cd $$dir ; ${MAKE} all ) ; done

install:
	for dir in ${SUBDIRS} ; do ( cd $$dir ; ${MAKE} install ) ; done

uninstall:
	for dir in ${SUBDIRS} ; do ( cd $$dir ; ${MAKE} uninstall ) ; done

clean:
	@rm -f *~
	@rm -f build-stamp configure-stamp
	@rm -rf debian/oscar-packager
	@rm -f oscar-packager.tar.gz
	@rm -f oscar-packager.spec
	for dir in ${SUBDIRS} ; do ( cd $$dir ; ${MAKE} clean ) ; done

dist: clean
	@rm -rf /tmp/oscar-packager
	@mkdir -p /tmp/oscar-packager
	@cp -rf * /tmp/oscar-packager
	@cd /tmp/oscar-packager; rm -rf `find . -name ".svn"`
	@cd /tmp; tar czf oscar-packager.tar.gz oda
	@cp -f /tmp/oscar-packager.tar.gz .
	@rm -rf /tmp/oscar-packager/
	@rm -f /tmp/oscar-packager.tar.gz

rpm: dist
	sed -e "s/PERLLIBPATH/$(SEDLIBDIR)/" < oscar-packager.spec.in \
        > oscar-packager.spec
	rpmbuild -bb ./oscar-packager.spec

deb:
	dpkg-buildpackage -rfakeroot
