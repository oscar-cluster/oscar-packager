# -*- mode: Makefile; -*-

LIBDIR	?= $(shell perl -V:vendorarch | sed s/vendorarch=\'// | sed s/\'\;//)
# Ugly stuff the prepare LIBDIR for a usage with sed (extra "\" and so on).
SEDLIBDIR ?= $(shell perl -V:vendorarch | sed s/vendorarch=\'// | sed s/\'\;// | sed s/\'\;// | awk '{ gsub(/\//, "\\\\\/"); print}')
