DOCBASE = oscar-packager_manual

pdf: $(DOCBASE).sgml
	dblatex  -o $(DOCBASE).pdf $(DOCBASE).sgml

html: $(DOCBASE).sgml
	sgmltools -b onehtml $(DOCBASE).sgml

all: pdf html

install:

clean:
	rm -f $(DOCBASE).pdf $(DOCBASE).html 
	rm -f *~
