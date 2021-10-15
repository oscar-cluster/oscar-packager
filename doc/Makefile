DOCBASE = oscar-packager_manual

TOPDIR=..
include $(TOPDIR)/Config.mk

pdf: $(DOCBASE).sgml
	docbook2pdf -u $(DOCBASE).sgml
	#dblatex  -o $(DOCBASE).pdf $(DOCBASE).sgml

html: $(DOCBASE).sgml
	docbook2html -u $(DOCBASE).sgml
	#openjade -V nochunks -t sgml -d /usr/share/sgml/docbook/stylesheet/dsssl/modular/html/docbook.dsl $(DOCBASE).sgml > $(DOCBASE).html
	#sgmltools -b onehtml $(DOCBASE).sgml

all: pdf html

install-doc: pdf html
	mkdir -p $(DESTDIR)$(DOCDIR)/oscar-packager/
	cp $(DOCBASE).pdf $(DOCBASE).html $(DESTDIR)$(DOCDIR)/oscar-packager/

clean:
	rm -f $(DOCBASE).pdf $(DOCBASE).html 
	rm -f *~
