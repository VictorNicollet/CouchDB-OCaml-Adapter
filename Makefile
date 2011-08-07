OPTS=-linkpkg -package json-wheel 
OCAMLC=ocamlfind ocamlc $(OPTS)
OCAMLDEP=ocamlfind ocamldep 
OCAMLBUILD=ocamlbuild -ocamlc '$(OCAMLC)' -ocamldep '$(OCAMLDEP)'

byte: 
	$(OCAMLBUILD) runServer.byte

native:
	$(OCAMLBUILD) runServer.native
