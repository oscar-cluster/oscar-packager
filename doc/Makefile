DOCBASE = oscar-packager_manual

pdf: $(DOCBASE).sgml
	dblatex  -o $(DOCBASE).pdf $(DOCBASE).sgml

html: $(DOCBASE).sgml
	docbook2html -u $(DOCBASE).sgml
	#openjade -V nochunks -t sgml -d /usr/share/sgml/docbook/stylesheet/dsssl/modular/html/docbook.dsl $(DOCBASE).sgml > $(DOCBASE).html
	#sgmltools -b onehtml $(DOCBASE).sgml

all: pdf html

install:

clean:
	rm -f $(DOCBASE).pdf $(DOCBASE).html 
	rm -f *~
