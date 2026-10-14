# The raz compiler in SBCL. `make` builds ./raz; `make check` runs the
# conformance suite, conform/, of the repository above.

SBCL = sbcl --control-stack-size 256MB --dynamic-space-size 4GB

raz: build.lisp src/*.lisp
	$(SBCL) --script build.lisp

check: raz
	cd .. && sh conform/check.sh sbcl/raz

clean:
	rm -rf raz build

.PHONY: check clean
