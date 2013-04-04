DESTDIR=
VERSION=$(shell cat VERSION)
NAME=oscar-packager
PKG=$(NAME)-$(VERSION)

include ./Config.mk

SUBDIRS := bin doc etc lib

all:
	for dir in $(SUBDIRS) ; do ( cd $$dir ; $(MAKE) all ) ; done

install:
	for dir in $(SUBDIRS) ; do ( cd $$dir ; $(MAKE) install ) ; done

uninstall:
	for dir in $(SUBDIRS) ; do ( cd $$dir ; $(MAKE) uninstall ) ; done

clean:
	@rm -f *~
	@rm -f build-stamp configure-stamp debian/files
	@rm -rf debian/oscar-packager*
	@rm -f $(PKG).tar.gz
	for dir in $(SUBDIRS) ; do ( cd $$dir ; $(MAKE) clean ) ; done

dist: clean
	@rm -rf /tmp/$(PKG)
	@mkdir -p /tmp/$(PKG)
	@cp -rf * /tmp/$(PKG)
	@cd /tmp/$(PKG); rm -rf `find . -name ".svn"`
	@sed -e 's/__VERSION__/$(VERSION)/g' $(NAME).spec.in > $(NAME).spec
	@cd /tmp; tar czf $(PKG).tar.gz $(PKG)
	@cp -f /tmp/$(PKG).tar.gz .
	@rm -rf /tmp/$(PKG)/
	@rm -f /tmp/$(PKG).tar.gz

rpm: dist
	@cp $(PKG).tar.gz `rpm --eval '%_sourcedir'`
	rpmbuild -bb ./$(NAME).spec

deb:
	dpkg-buildpackage -rfakeroot
