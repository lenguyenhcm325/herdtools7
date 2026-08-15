.DEFAULT_GOAL = all

OS := $(shell uname)
PREFIX=$$HOME
D=dune

#Limit parallelism of some expensive operations
ifeq ($(OS),Darwin)
	J=$(shell sysctl -n hw.logicalcpu)
else
	J=$(shell nproc)
endif

REGRESSION_TEST_MODE = test
# REGRESSION_TEST_MODE = promote
# REGRESSION_TEST_MODE = show

DUNE_PROFILE = release

DIY                           = _build/install/default/bin/diy7
DIYCROSS                      = _build/install/default/bin/diycross7
DIYMICROENUM                  = _build/install/default/bin/diymicroenum7
HERD                          = _build/install/default/bin/herd7
LITMUS                        = _build/install/default/bin/litmus7
LITMUS_LIB_DIR                = $(PWD)/litmus/libdir
DIY_REGRESSION_TEST           = _build/default/internal/diy_regression_test.exe
HERD_REGRESSION_TEST          = _build/default/internal/herd_regression_test.exe
HERD_DIYCROSS_REGRESSION_TEST = _build/default/internal/herd_diycross_regression_test.exe
HERD_CATALOGUE_REGRESSION_TEST = _build/default/internal/herd_catalogue_regression_test.exe
HERD_ASSUMPTIONS_TEST		  = _build/default/internal/herd_assumptions_test.exe
ASLREF                        = _build/default/asllib/aslref.exe
CHECK_OBS                     = _build/default/internal/check_obs.exe

all: build

CATA_HERD_TEST_MODE := $(if $(ALL_TESTS), ,-fast)
HERD_CATALOGUE_REGRESSION_TEST += $(CATA_HERD_TEST_MODE)

.PHONY: Version.ml
Version.ml:
	sh ./version-gen.sh $(PREFIX)

just-build: Version.ml
	dune build -j $(J) --profile $(DUNE_PROFILE)

build-release: Version.ml
	dune build -j $(J) -p herdtools7 @install

build: check-deps | just-build

install-herdtools:
	sh ./dune-install.sh $(PREFIX)

build-aslref:
	dune build -p aslref --profile $(DUNE_PROFILE)

install-aslref:
	# There are no lib files for aslref so we don't need dune-install.sh
	dune install aslref --prefix $(PREFIX)

install: install-herdtools

uninstall:
	sh ./dune-uninstall.sh $(PREFIX)

uninstall-aslref:
	dune uninstall aslref --prefix $(PREFIX)

clean: dune-clean clean-asl-pseudocode clean-asldoc
	rm -f Version.ml

dune-clean:
	dune clean

versions: Version.ml
	@ dune build -j $(J) --workspace dune-workspace.versions


# Dependencies.

.PHONY: check-deps
check-deps::
	$(if $(shell which ocaml),,$(error "Could not find ocaml in PATH"))
	$(if $(shell which menhir),,$(error "Could not find menhir in PATH; it can be installed with `opam install menhir`."))

check-deps::
	$(if $(shell which dune),,$(error "Could not find dune in PATH; it can be installed with `opam install dune`."))

# Tests.
TIMEOUT=16.0

test-all:: test
test:: | build

test:: dune-test
	@ echo "OCaml unit tests: OK"

dune-test:
	@ echo
	dune runtest --profile=$(DUNE_PROFILE)

test-all:: test.aarch64assumptions
test-local:: test.aarch64assumptions
test.aarch64assumptions:
	@ echo
	$(HERD_ASSUMPTIONS_TEST) \
		-herd-path $(HERD) \
		-libdir-path ./herd/libdir \
		-dirs-and-confs-path ./dirs-and-confs.txt \
		-assumptions-path ./tools/libdir/aarch64assumptions.cat
	@ echo "cat2table AArch64 assumptions: OK"

test.herd.inst.ASL-pseudo-arch: NOHASH=-nohash
test.herd.inst.ASL: NOHASH=-nohash

test.herd.inst.%:
	@ echo
	$(HERD_REGRESSION_TEST) \
		-j $(J) \
		$(NOHASH) \
		-herd-path $(HERD) \
		-libdir-path ./herd/libdir \
		-litmus-dir ./herd/tests/instructions/$* \
		-conf ./herd/tests/instructions/$*/ci.cfg \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 $* instructions tests: OK"

.PHONY: test.herd.inst
test.herd.inst:: test.herd.inst.AArch64
test.herd.inst:: test.herd.inst.AArch64.mixed
test.herd.inst:: test.herd.inst.AArch64.PAC
test.herd.inst:: test.herd.inst.AArch64.kvm
test.herd.inst:: test.herd.inst.AArch64.self
test.herd.inst:: test.herd.inst.AArch64.MTE
test.herd.inst:: test.herd.inst.AArch64.vmsa+mte
test.herd.inst:: test.herd.inst.AArch64.vmsa+ifetch
test.herd.inst:: test.herd.inst.AArch64.neon
test.herd.inst:: test.herd.inst.AArch64.sve
test.herd.inst:: test.herd.inst.AArch64.sme
test.herd.inst:: test.herd.inst.AArch64.gcs

test.herd.inst:: test.herd.inst.AArch32
test.herd.inst:: test.herd.inst.ARM
test.herd.inst:: test.herd.inst.PPC
test.herd.inst:: test.herd.inst.MIPS
test.herd.inst:: test.herd.inst.X86_64
test.herd.inst:: test.herd.inst.RISCV
test.herd.inst:: test.herd.inst.C

test.herd.inst:: test.herd.inst.ASL
test.herd.inst:: test.herd.inst.ASL-pseudo-arch

test:: test.herd.inst
test-local:: test.herd.inst

test.herd-asl.inst.%: asl-pseudocode
	@ echo
	$(HERD_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-libdir-path ./herd/libdir \
		-litmus-dir ./herd/tests/instructions/$* \
		-conf ./herd/tests/instructions/$*/asl.cfg \
		-checkstates \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 $* instructions tests (ASL): OK"

test:: test.herd-asl.inst.AArch64
test:: test.herd-asl.inst.AArch64.sve
test:: test.herd-asl.inst.AArch64.kvm

test-local:: test.herd-asl.inst.AArch64.sve

test-all-asl:: test.herd-asl.inst.AArch64
test-all-asl:: test.herd-asl.inst.AArch64.sve
test-all-asl:: test.herd-asl.inst.AArch64.kvm

test-all-vmsa:: test.herd-asl.inst.AArch64.kvm

test-all-asl:: test.aarch64.asl.with.vmsa
test.aarch64.asl.with.vmsa: asl-pseudocode
	@ echo
	$(HERD_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-libdir-path ./herd/libdir \
		-litmus-dir ./herd/tests/instructions/AArch64 \
		-conf ./herd/tests/instructions/AArch64/asl-with-vmsa.cfg \
		-checkstates \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64 instructions tests (ASL with VMSA): OK"

test:: test-aarch64-asl
test-all-asl:: test-aarch64-asl
test-aarch64-asl: asl-pseudocode
	@echo
	$(HERD_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-libdir-path ./herd/libdir \
		-litmus-dir ./herd/tests/instructions/AArch64.ASL \
		-conf ./herd/tests/instructions/AArch64.ASL/asl.cfg \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64+ASL instructions tests: OK"

test-all-asl:: test-aarch64-asl-with-vmsa
test-aarch64-asl-with-vmsa: asl-pseudocode
	@echo
	$(HERD_REGRESSION_TEST) \
		-j $(J) -checkstates  \
		-herd-path $(HERD) \
		-libdir-path ./herd/libdir \
		-litmus-dir ./herd/tests/instructions/AArch64.ASL \
		-conf ./herd/tests/instructions/AArch64.ASL/asl-with-vmsa.cfg \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64+ASL (with VMSA) instructions tests: OK"

test:: test-aarch64-noasl
test-local:: test-aarch64-noasl
test-aarch64-noasl:
	@echo
	$(HERD_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-libdir-path ./herd/libdir \
		-litmus-dir ./herd/tests/instructions/AArch64.ASL \
		-conf ./herd/tests/instructions/AArch64.ASL/noasl.cfg \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64+NOASL instructions tests: OK"

test:: test-aarch64-noasl-mixed
test-local:: test-aarch64-noasl-mixed
test-aarch64-noasl-mixed:
	@echo
	$(HERD_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-libdir-path ./herd/libdir \
		-litmus-dir ./herd/tests/instructions/AArch64.ASL \
		-conf ./herd/tests/instructions/AArch64.ASL/noasl-mixed.cfg \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64+NOASL+MIXED instructions tests: OK"

test-bnfc:
	@ echo
	dune runtest asllib/menhir2bnfc
	@ echo "BNFC tests: OK"

### CATALOGUE testing, catalogue must be here
CATATEST := $(shell if test -d catalogue; then echo cata-test; fi)
CATATESTALL := $(shell if test -d catalogue; then echo cata-test-all; fi)

test:: $(CATATEST)
test-local:: $(CATATEST)

test-all:: cata-test cata-test-asl $(CATATESTALL)
test-all-asl:: cata-test-asl

test.herd.cata.%:
	@ echo
	$(HERD_CATALOGUE_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-herd-timeout $(TIMEOUT) \
		-libdir-path ./herd/libdir \
		-kinds-path catalogue/$*/tests/kinds.txt \
		-shelf-path catalogue/$*/ci-shelf.py \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 catalogue $* tests: OK"

cata-test:: test.herd.cata.aarch64
cata-test:: test.herd.cata.aarch64-mixed
cata-test:: test.herd.cata.aarch64-pick
cata-test:: test.herd.cata.aarch64-faults
cata-test:: test.herd.cata.aarch64-MTE
cata-test:: test.herd.cata.aarch64-PAC
cata-test:: test.herd.cata.aarch64-ifetch
cata-test:: test.herd.cata.aarch64-cas
cata-test-all:: test.herd.cata.aarch64-VMSA
cata-test:: test.herd.cata.aarch64-ETS2
cata-test:: test.herd.cata.aarch64-ETS3

cata-test:: test.herd.cata.bpf
cata-test:: test.herd.cata.x86_64

test.herd-mixed.cata.%:
	@ echo
	$(HERD_CATALOGUE_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-herd-timeout $(TIMEOUT) \
		-libdir-path ./herd/libdir \
		-kinds-path catalogue/$*/tests/kinds.txt \
		-shelf-path catalogue/$*/ci-shelf.py \
		-variant mixed \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 catalogue $* (mixed mode) tests: OK"

cata-test:: test.herd-mixed.cata.aarch64
cata-test:: test.herd-mixed.cata.aarch64-pick

test.herd-asl.cata.%: asl-pseudocode
	@ echo
	$(HERD_CATALOGUE_REGRESSION_TEST) \
		$(EXTRA_OPTS) \
		-j $(J) \
		-variant asl \
		-variant strict \
		-herd-path $(HERD) \
		-herd-timeout $(TIMEOUT) \
		-libdir-path ./herd/libdir \
		-kinds-path catalogue/$*/tests/kinds.txt \
		-shelf-path catalogue/$*/ci-shelf.py \
		-conf-path catalogue/$*/cfgs/asl.cfg \
		$(REGRESSION_TEST_MODE)
		@ echo "herd7 catalogue $* tests (ASL): OK"

cata-test-asl:: test.herd-asl.cata.aarch64
cata-test-asl:: test.herd-asl.cata.aarch64-cas
cata-test-asl:: test.herd-asl.cata.aarch64-pick
cata-test-asl:: test.herd-asl.cata.aarch64-faults
#Too long to include in `make test-all`. Add -verbose option to reassure us that something is running
test.herd-asl.cata.aarch64-VMSA:: EXTRA_OPTS=-verbose
test-all-asl:: test.herd-asl.cata.aarch64-VMSA

### Diy tests, includes
### - A `diyone7` generated syntax check
### - A `diy7` with `cycleonly` instance checks the cycle generations
### - Several `diycross7` + `herd7` instances, check if the generated litmus tests
###   are equivalent based on `herd7` result.
diy-test:: | build
diy-test:: diyone-basic-test
diyone-basic-test:
	@ echo
	dune test gen/tests
	@ echo "diy* basic test: OK"

diy-test:: diy-baseline-cycleonly
diy-baseline-cycleonly::
	@ echo
	$(DIY_REGRESSION_TEST) \
		-diy-path $(DIY) \
		-conf ./gen/libdir/forbidden.conf \
		-expected ./gen/tests/baseline-size-4.cycle.expected \
		-diy-arg "-size" \
		-diy-arg "4" \
		$(REGRESSION_TEST_MODE)
	@ echo "diy7 baseline configuration test: OK"

diy-test:: diy-ifetch-cycleonly
diy-ifetch-cycleonly::
	@ echo
	$(DIY_REGRESSION_TEST) \
		-diy-path $(DIY) \
		-conf ./gen/libdir/forbidden_ifetch.conf \
		-expected ./gen/tests/ifetch.cycle.expected \
		$(REGRESSION_TEST_MODE)
	@ echo "diy7 ifetch configuration test: OK"

LDS:="Amo.Cas,Amo.LdAdd,Amo.LdClr,Amo.LdEor,Amo.LdSet"
LDSPLUS:="LxSx",$(LDS)

diy-test:: diy-test-aarch64
diy-test-aarch64:
	@ echo
	$(HERD_DIYCROSS_REGRESSION_TEST) \
		-herd-path $(HERD) \
		-diycross-path $(DIYCROSS) \
		-libdir-path ./herd/libdir \
		-expected-dir ./gen/tests/AArch64 \
		-diycross-arg -arch \
		-diycross-arg AArch64 \
		-diycross-arg 'A,L,P' \
		-diycross-arg 'Pod**,Fenced**,DSB.SYd**,ISBd**,[Amo.Cas,Pod**],[Amo.Swp,Pod**],[Amo.StAdd,Pod**],[LxSx,Pod**]' \
		-diycross-arg 'Rfe,Fre,Coe' \
		-diycross-arg 'DpAddrdR,DpAddrdW,DpDatadW,CtrldR,CtrldW,DpAddrCseldR,DpAddrCseldW,DpDataCseldW,DpCtrlCseldR,DpCtrlCseldW,[DpCtrldR,ISB],[DpCtrldW,ISB]' \
		-diycross-arg 'Rfe,Fre,Coe,Hat' \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64 diycross7 tests: OK"

diy-test:: diy-test-mixed
diy-test-mixed::
	@ echo
	$(HERD_DIYCROSS_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-diycross-path $(DIYCROSS) \
		-libdir-path ./herd/libdir \
		-expected-dir ./gen/tests/AArch64.mixed \
		-conf ./gen/tests/AArch64.mixed/mixed.cfg \
		-diycross-arg -ua \
		-diycross-arg 0 \
		-diycross-arg -obs \
		-diycross-arg oo \
		-diycross-arg -arch \
		-diycross-arg AArch64 \
		-diycross-arg -variant \
		-diycross-arg mixed \
		-diycross-arg -hexa \
		-diycross-arg Hat \
		-diycross-arg h0 \
		-diycross-arg $(LDSPLUS) \
		-diycross-arg h0 \
		-diycross-arg Rfi \
		-diycross-arg w0 \
		-diycross-arg Amo.StAdd \
		-diycross-arg w0 \
		-diycross-arg Rfi \
		-diycross-arg h2 \
		-diycross-arg $(LDS) \
		-diycross-arg h2 \
		-diycross-arg PodWR \
		-diycross-arg Hat \
		-diycross-arg w0 \
		-diycross-arg Amo.LdSet \
		-diycross-arg w0 \
		-diycross-arg PodWR \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64.mixed diycross7 tests: OK"

diy-test-mixed::
	@ echo
	$(HERD_DIYCROSS_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-diycross-path $(DIYCROSS) \
		-libdir-path ./herd/libdir \
		-expected-dir ./gen/tests/AArch64.mixed.strict \
		-conf ./gen/tests/AArch64.mixed.strict/mixed.cfg \
		-diycross-arg -arch \
		-diycross-arg AArch64 \
		-diycross-arg -ua \
		-diycross-arg 0 \
		-diycross-arg -variant \
		-diycross-arg mixed,MixedStrictOverlap \
		-diycross-arg -hexa \
		-diycross-arg h0,h2,w0 \
		-diycross-arg Amo.CasAP,LxSxAP \
		-diycross-arg h0,h2,w0  \
		-diycross-arg PodWR \
		-diycross-arg w0,h0 \
		-diycross-arg Fre \
		-diycross-arg w0,h2 \
		-diycross-arg FencedWW \
		-diycross-arg w0,h0,h2 \
		-diycross-arg Rfe \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64.mixed.strict diycross7 tests: OK"

diy-test-mixed:: v32 v64

v32:
	@ echo
	$(HERD_DIYCROSS_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-diycross-path $(DIYCROSS) \
		-libdir-path ./herd/libdir \
		-expected-dir ./gen/tests/AArch64.mixed.v32 \
		-conf ./gen/tests/AArch64.mixed.strict/mixed.cfg \
		-diycross-arg -arch \
		-diycross-arg AArch64 \
		-diycross-arg -variant \
		-diycross-arg mixed \
		-diycross-arg -hexa \
		-diycross-arg PodWW \
		-diycross-arg RfeLA \
		-diycross-arg h0,h2,w0 \
		-diycross-arg DpDatadW,DpAddrdR,DpAddrdW \
		-diycross-arg A,P,L \
		-diycross-arg h0,h2,w0 \
		-diycross-arg Coe,Fre \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64.mixed.v32 diycross7 tests: OK"

v64:
	@ echo
	$(HERD_DIYCROSS_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-diycross-path $(DIYCROSS) \
		-libdir-path ./herd/libdir \
		-expected-dir ./gen/tests/AArch64.mixed.v64 \
		-conf ./gen/tests/AArch64.mixed.strict/mixed.cfg \
		-diycross-arg -arch \
		-diycross-arg AArch64 \
		-diycross-arg -variant \
		-diycross-arg mixed \
		-diycross-arg -hexa \
		-diycross-arg -type \
		-diycross-arg uint64_t \
		-diycross-arg PodWW \
		-diycross-arg RfeLA \
		-diycross-arg w0,w4,q0 \
		-diycross-arg DpDatadW,DpAddrdR,DpAddrdW \
		-diycross-arg A,P,L \
		-diycross-arg w0,w4,q0 \
		-diycross-arg Coe,Fre \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64.mixed.v64 diycross7 tests: OK"

diy-test:: diy-store-test
diy-store-test:
	@ echo
	$(HERD_DIYCROSS_REGRESSION_TEST) \
		-herd-path $(HERD) \
		-diycross-path $(DIYCROSS) \
		-libdir-path ./herd/libdir \
		-expected-dir ./gen/tests/AArch64.store \
		-diycross-arg -obs \
		-diycross-arg four \
		-diycross-arg -arch \
		-diycross-arg AArch64 \
		-diycross-arg 'Fenced**' \
		-diycross-arg 'Rfe,Fre,Coe' \
		-diycross-arg 'DpAddrdR,DpDatadW' \
		-diycross-arg 'Pos**' \
		-diycross-arg 'Store' \
		-diycross-arg 'Rfe,Fre,Coe' \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64 diycross7.store tests: OK"

diy-test:: diy-test-mte
diy-test-mte::
	@ echo
	$(HERD_DIYCROSS_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-diycross-path $(DIYCROSS) \
		-libdir-path ./herd/libdir \
		-expected-dir ./gen/tests/AArch64.MTE \
		-conf ./gen/tests/AArch64.MTE/MTE.cfg \
		-diycross-arg -arch \
		-diycross-arg AArch64 \
		-diycross-arg -variant \
		-diycross-arg memtag \
		-diycross-arg -variant \
		-diycross-arg async \
		-diycross-arg DMB.SYd*W \
		-diycross-arg T,P \
		-diycross-arg Rfe \
		-diycross-arg A \
		-diycross-arg Amo.LdAdd \
		-diycross-arg L \
		-diycross-arg PodW* \
		-diycross-arg T,P \
		-diycross-arg Coe,Rfe,Fre \
		-diycross-arg T,P \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64.MTE diycross7 tests: OK"

diy-test::  diy-test-C
diy-test-C:
	@ echo
	$(HERD_DIYCROSS_REGRESSION_TEST) \
		-j $(J) \
		-herd-path $(HERD) \
		-diycross-path $(DIYCROSS) \
		-libdir-path ./herd/libdir \
		-expected-dir ./gen/tests/C \
		-conf ./gen/tests/C/C.cfg \
		-diycross-arg -arch \
                -diycross-arg C \
		-diycross-arg [Rlx,Coe,Rlx],[Rlx,Rfe,Rlx],[Rlx,Fre,Rlx],[Rlx,Hat,Rlx] \
                -diycross-arg PosRW,Fetch.Add,Exch \
                -diycross-arg Rlx \
                -diycross-arg PodW* \
		-diycross-arg [Rlx,Coe,Rlx],[Rlx,Rfe,Rlx],[Rlx,Fre,Rlx] \
                -diycross-arg Pod**,[Fetch.Add,Rlx,PodW*] \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 C diycross7 tests: OK"

### Diymicro test
diymicro-test:: | build

diymicro-test:: diymicro-test-aarch64
diymicro-test-aarch64:
	$(eval DIYMICRO_EDGES = $(shell $(DIYMICROENUM) -list-iico | sed -n 's/^iico\[\([^ ]*\).*/iico[\1]/p'))
	$(eval DIYMICRO_EDGES_ARG := $(foreach arg,$(DIYMICRO_EDGES),-diycross-arg $(arg)))
	@ echo
	$(HERD_DIYCROSS_REGRESSION_TEST) \
		-herd-path $(HERD) \
		-diycross-path $(DIYMICROENUM) \
		-libdir-path ./herd/libdir \
		-expected-dir ./gen/tests/diymicro/AArch64 \
		$(DIYMICRO_EDGES_ARG) \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64 diymicro7 tests: OK"

diymicro-test:: diymicro-test-aarch64-asl
diymicro-test-aarch64-asl: asl-pseudocode
	$(eval DIYMICRO_EDGES = $(shell $(DIYMICROENUM) -list-iico | sed -n 's/^iico\[\([^ ]*\).*/iico[\1]/p'))
	$(eval DIYMICRO_EDGES_ARG := $(foreach arg,$(DIYMICRO_EDGES),-diycross-arg $(arg)))
	@ echo
	$(HERD_DIYCROSS_REGRESSION_TEST) \
		-herd-path $(HERD) \
		-diycross-path $(DIYMICROENUM) \
		-libdir-path ./herd/libdir \
		-expected-dir ./gen/tests/diymicro/AArch64 \
		-conf ./gen/tests/diymicro/AArch64/asl.cfg \
		-j $(J) \
		$(DIYMICRO_EDGES_ARG) \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 AArch64 diymicro7 (ASL) tests: OK"

.PHONY: asl-pseudocode
asl-pseudocode:
	@ $(MAKE) -C herd/libdir/asl-pseudocode build

.PHONY: clean-asl-pseudocode
clean-asl-pseudocode:
	@ $(MAKE) -C herd/libdir/asl-pseudocode clean

.PHONY: asldoc
asldoc: build-aslref
	@ $(MAKE) $(MFLAGS) -C asllib/doc all ASLREF=$(CURDIR)/$(ASLREF)

.PHONY: clean-asldoc
clean-asldoc:
	@ $(MAKE) $(MFLAGS) -C asllib/doc clean

.PHONY: type-check-asl
type-check-asl: build-aslref
	@ echo
	@ $(MAKE) $(MFLAGS) -C herd/libdir/asl-pseudocode type-check ASLREF=$(CURDIR)/$(ASLREF)
	@ echo "ASLRef type-checking of published Arm ASL code: OK"

.PHONY: dune-no-missing-file-in-runt
test:: dune-no-missing-file-in-runt
dune-no-missing-file-in-runt:
	@ echo
	asllib/tests/check-no-missing-file-in-run.sh ./
	@ echo "no missing file in run.t"

RUN_TESTS?=false
$(V).SILENT:
$(V)SILENTOPT=-s

### HetLitmus test targets.  Each gate's contract lives in the script it runs;
### the headers below carry only what a target proves and how to regenerate what
### it pins.  Roster and lane split: hetlitmus/docs/TEST-PLAN.md sec.6.
### Deliberately NOT wired into upstream `test::`, so the main suite stays fast
### and CUDA-free; sec.10 holds that decision open.  Upstream idiom: `| build`
### order-only prereq + `@ echo OK`.  The verify scripts export their own PATH
### (`_build/install/default/bin`, plus `/usr/local/cuda/bin` on the toolchain
### lane), so leaf targets just invoke them.

### Building blocks (run solo while iterating).
hetlitmus-cram: | build
	@ echo
	dune runtest hetlitmus/tests/cram
	@ echo "HetLitmus Layer-1 cram: OK"

### The committed corpora and the pinned gpu-only samples are still what the
### generators and the emitter produce (hetlitmus/verify/corpus-gate.sh).
### Regenerate both corpora with `make hetlitmus-promote`.
hetlitmus-corpus: | build
	@ echo
	bash hetlitmus/verify/corpus-gate.sh
	bash hetlitmus/verify/corpus-gate.sh --bite
	@ echo "HetLitmus Layer-2 corpus golden: OK (and the gate bites)"

### Every emitted harness carries exactly the memory ops its .litmus annotates,
### with the right kind, order and scope, and no others
### (hetlitmus/verify/ptxcheck.py; hetlitmus/docs/faithfulness.md).
hetlitmus-faithful: | build
	@ echo
	bash hetlitmus/verify/tokens.sh all
	@ echo "HetLitmus Layer-3 PTX faithfulness (644): OK"

### A curated sample of emitted harnesses builds end to end through its own
### comp.sh -- host CPU object, cross-assembly, .cu and .hip
### (hetlitmus/verify/smoke.sh).  Needs nvcc, hipcc and clang.
hetlitmus-smoke: | build
	@ echo
	bash hetlitmus/verify/smoke.sh
	@ echo "HetLitmus Layer-3 compile-smoke: OK"

### The GPU scratchpad stress layer is present in the emitted PTX rather than
### folded away, which the faithfulness gate is blind to by design -- stress is
### scaffolding, not a model op (hetlitmus/verify/stresscheck.py).
hetlitmus-stress: | build
	@ echo
	bash hetlitmus/verify/tokens.sh stress
	@ echo "HetLitmus Layer-3 stress liveness: OK"

### The CPU-side and interconnect stress mechanisms -- invisible to both PTX
### gates -- survive -O2 on both host ISAs and do work at run time, live when on
### and zero when off (hetlitmus/verify/cpustresscheck.py).
hetlitmus-cpustress: | build
	@ echo
	bash hetlitmus/verify/tokens.sh cpustress
	@ echo "HetLitmus Layer-3 CPU+interconnect stress liveness: OK"

### Every test off the lattice floor names a mu(T) that exists and is strictly
### weaker on this lattice, and the map fails closed (verify/controlmap.py;
### docs/positive-control.md).  Regenerate: `--emit > tests/het/control-map.csv`.
hetlitmus-controlmap: | build
	@ echo
	python3 hetlitmus/verify/controlmap.py --check
	python3 hetlitmus/verify/controlmap.py --bite
	@ echo "HetLitmus control map: OK (and the gate bites)"

### The same gate on the x86 lattice, which loses the middle rung the AArch64
### one has, so the AMD map is a separate artifact and never a translation.
### Regenerate: `controlmap.py --lattice x86 --emit > tests/het/control-map-amd.csv`.
hetlitmus-amd-controlmap: | build
	@ echo
	python3 hetlitmus/verify/controlmap.py --lattice x86 --check
	python3 hetlitmus/verify/controlmap.py --lattice x86 --bite
	@ echo "HetLitmus AMD control map: OK (and the gate bites)"

### The isomorphism gate: no two corpus tests are the same experiment up to
### (proc permutation x location renaming), which is the duplicate class the
### generators' byte-comparison cannot see (hetlitmus/verify/dupcheck.py).
hetlitmus-dup: | build
	@ echo
	python3 hetlitmus/verify/dupcheck.py
	python3 hetlitmus/verify/dupcheck.py --bite
	@ echo "HetLitmus isomorphism/dedup gate: OK (and the gate bites)"

### The per-primitive ordering table behind the control-map lattice, decided by
### herd7's native AArch64 model and by hetlitmus/cats/nvidia-ptx.cat [Lustig19]
### rather than asserted (hetlitmus/verify/ordercheck.py).
hetlitmus-lattice: | build
	@ echo
	python3 hetlitmus/verify/ordercheck.py
	python3 hetlitmus/verify/ordercheck.py --bite
	@ echo "HetLitmus ordering-table lattice gate: OK (and the gate bites)"

### het_verdict() -- the rule deciding what an observation MEANS -- compiled from
### the real emitted header and driven with synthetic records, together with the
### machine words each pair's printout may name (hetlitmus/verify/verdictcheck.py).
hetlitmus-verdict: | build
	@ echo
	python3 hetlitmus/verify/verdictcheck.py
	python3 hetlitmus/verify/verdictcheck.py --bite
	@ echo "HetLitmus decision rule: OK (and the gate bites)"

### het_stats_compute() -- what a "Never" is worth -- compiled from the real
### emitted header and driven with synthetic record streams, through the stop
### rule and campaign.py's scheduler (hetlitmus/verify/statscheck.py).
hetlitmus-stats: | build
	@ echo
	python3 hetlitmus/verify/statscheck.py
	python3 hetlitmus/verify/statscheck.py --bite
	@ echo "HetLitmus statistics layer: OK (and the gate bites)"

### litmus7's inherited outs histogram: fed exactly once per observation, and
### never printing a number for a location column no run measures
### (hetlitmus/verify/histcheck.py).
hetlitmus-hist: | build
	@ echo
	python3 hetlitmus/verify/histcheck.py
	python3 hetlitmus/verify/histcheck.py --bite
	@ echo "HetLitmus histogram tally + display: OK (and the gate bites)"

### The autotuner search machinery (hetlitmus/tune.py): it finds a known optimum,
### crowns nobody on a constant objective, and breaks when any transfer fix is
### removed (hetlitmus/verify/tunecheck.py).  Pure Python, hence no `| build`.
hetlitmus-tuner:
	@ echo
	python3 hetlitmus/tune.py --self-test >/dev/null
	python3 hetlitmus/verify/tunecheck.py
	python3 hetlitmus/verify/tunecheck.py --bite
	@ echo "HetLitmus tuner search machinery: OK (and the gate bites)"

### The emitted CPU observer still reloads once per iteration at clang -O2 on
### both host ISAs -- it is the only recovery channel the store-only shapes have
### (hetlitmus/verify/obscheck.py).
hetlitmus-obs: | build
	@ echo
	python3 hetlitmus/verify/obscheck.py
	python3 hetlitmus/verify/obscheck.py --bite
	@ echo "HetLitmus observer-liveness gate: OK (and the gate bites)"

### The emitter/runtime skew tripwire: every field a render writes and every
### HET_* define it stamps still binds to litmus/het-runtime/*.h, which nothing
### but a compiler otherwise checks (hetlitmus/verify/recfields.py).
hetlitmus-recfields: | build
	@ echo
	python3 hetlitmus/verify/recfields.py
	python3 hetlitmus/verify/recfields.py --bite
	@ echo "HetLitmus emitter/runtime field + define binding: OK (and the gate bites)"

### The x86-64 CPU thread of a het harness is that test's own program, down to
### the object file, and a refusal is fail-closed (verify/x86bodycheck.py).  Its
### input corpus: tests/het/generate-x86.sh, which says why it is not committed.
hetlitmus-x86body: | build
	@ echo
	python3 hetlitmus/verify/x86bodycheck.py
	python3 hetlitmus/verify/x86bodycheck.py --bite
	@ echo "HetLitmus x86-64 tagged CPU body gate: OK (and the gate bites)"

### hetlitmus/tests/het-x86 is still, byte for byte, what its generators emit --
### it is the only committed route to the populated (x86_64, hip) pair
### (hetlitmus/verify/x86fixturecheck.py).  Re-cut it per its own README.md.
hetlitmus-x86fixture: | build
	@ echo
	python3 hetlitmus/verify/x86fixturecheck.py
	python3 hetlitmus/verify/x86fixturecheck.py --bite
	@ echo "HetLitmus het-x86 fixture sync gate: OK (and the gate bites)"

### Scratch output dir for the CPU-only shapes.  Never committed (.gitignore'd):
### they are generated on demand, so corpus-gate.sh's census and dupcheck.py --
### both of which scan hetlitmus/tests/het non-recursively -- stay meaningful.
### Absolute, because the generator and the recipe below both cd elsewhere.
HETCPUONLYOUT := $(CURDIR)/hetlitmus/tests/het/cpuonly-out

### The GPU dialect these harnesses are rendered for.  litmus7 emits ONE vendor
### per harness dir, and the machine lives on the pair: this corpus has an x86_64
### CPU column, so `hip' selects the pair that names the MI300A.  `cuda' is legal
### and reads the same map, but names no machine, so it is a machinery smoke.
HETCPUONLYTARGET ?= hip

### The negative control for the cpu_only stamp: a corpus test with a GPU proc,
### which the emitter must stamp 0.  Emitted into a temp dir, since the count of
### harness dirs in $(HETCPUONLYOUT) is pinned.  Both halves are knobs so the
### check can be shown to bite: point them at a CPU-only test and the grep fails.
HETCPUONLYNEGDIR ?= $(CURDIR)/hetlitmus/tests/het
HETCPUONLYNEG ?= MP-cg-sys-relaxed

### The CPU-only shapes as a campaign item: generate, emit, read every render for
### the `_rec.cpu_only = 1' stamp against a het control that must stamp 0, print
### the campaign command.  It does NOT run them: only the target box's would count.
hetlitmus-cpuonly: | build
	@ echo
	rm -rf $(HETCPUONLYOUT)
	hetlitmus/tests/het/generate-cpuonly.sh $(HETCPUONLYOUT)
	@ set -e ; cd $(HETCPUONLYOUT) ; for t in *.litmus ; do \
	    $(CURDIR)/_build/install/default/bin/litmus7 \
	      -gpu-target $(HETCPUONLYTARGET) \
	      -set-libdir $(CURDIR)/litmus/libdir \
	      -o . "$$t" 2>&1 | grep -E 'pair:|REFUSED' ; done
	@ set -e ; n=$$(ls -d $(HETCPUONLYOUT)/*/ 2>/dev/null | wc -l) ; \
	  test "$$n" -eq 6 || { echo "hetlitmus-cpuonly: emitted $$n harness dir(s), expected 6" ; exit 1 ; }
	@ set -e ; n=0 ; for d in $(HETCPUONLYOUT)/*/ ; do \
	    r=$$(ls $$d*.hip $$d*.cu 2>/dev/null | head -1) ; \
	    test -n "$$r" || { echo "hetlitmus-cpuonly: $$d carries no render" ; exit 1 ; } ; \
	    grep -q '_rec\.cpu_only = 1;' "$$r" || { \
	      echo "hetlitmus-cpuonly: $$r does not stamp _rec.cpu_only = 1 -- a CPU-only" ; \
	      echo "  cycle whose harness does not say so is reported as a compound-model row" ; \
	      exit 1 ; } ; \
	    n=$$((n+1)) ; done ; \
	  echo "hetlitmus-cpuonly: $$n/6 renders stamp _rec.cpu_only = 1"
	@ set -e ; t=$$(mktemp -d) ; \
	  $(CURDIR)/_build/install/default/bin/litmus7 -gpu-target cuda \
	    -set-libdir $(CURDIR)/litmus/libdir -o "$$t" \
	    $(HETCPUONLYNEGDIR)/$(HETCPUONLYNEG).litmus >"$$t/emit.log" 2>&1 \
	    || { cat "$$t/emit.log" ; rm -rf "$$t" ; exit 1 ; } ; \
	  r="$$t/$(HETCPUONLYNEG)/$(HETCPUONLYNEG).cu" ; \
	  grep -q '_rec\.cpu_only = 0;' "$$r" \
	    || { echo "hetlitmus-cpuonly: the het control $(HETCPUONLYNEG) does not stamp" ; \
	         echo "  _rec.cpu_only = 0 -- the flag is a constant, so the six 1s above" ; \
	         echo "  vouch for nothing" ; rm -rf "$$t" ; exit 1 ; } ; \
	  rm -rf "$$t" ; \
	  echo "hetlitmus-cpuonly: the het control $(HETCPUONLYNEG) stamps _rec.cpu_only = 0"
	@ echo
	@ echo "CPU-only harnesses in $(HETCPUONLYOUT), rendered for $(HETCPUONLYTARGET).  On the target box:"
	@ echo "    cd <test> && sh comp.sh $(HETCPUONLYTARGET)-link && ./<test>    # SB and R must FIRE"
	@ echo "    python3 hetlitmus/campaign.py --corpus $(HETCPUONLYOUT) --runner 'sh hetlitmus/spotcheck/run-one.sh {dir} {test}'"

### An AMD harness builds and links into an ELF carrying real gfx942 code, its
### allocator and placement refusals execute under a stub, and the CUDA lane does
### not regress (verify/hipbuildcheck.py).  Needs hipcc AND nvcc, but no device.
hetlitmus-hipbuild: | build
	@ echo
	python3 hetlitmus/verify/hipbuildcheck.py
	python3 hetlitmus/verify/hipbuildcheck.py --bite
	@ echo "HetLitmus AMD build/link gate: OK (and the gate bites)"

### What a het harness PRINTS on a device -- the only artefact a result is read
### off -- on both control-map arms, so the two sentences a reader must never see
### swapped are told apart (verify/runcheck.py --characterize-hw).  Needs a GPU.
hetlitmus-characterize-hw: | build
	@ echo
	python3 hetlitmus/verify/runcheck.py --characterize-hw
	python3 hetlitmus/verify/runcheck.py --characterize-hw --bite
	@ echo "HetLitmus harness-printout runtime gate: OK (and the gate bites)"

### The device-session wrapper (hetlitmus/hetlitmus-run.sh) end to end with its
### documented stand-ins for the compiler and the probe, so what it decides on an
### unwatched machine is decided here (verify/runcheck.py).  Host-adaptive.
hetlitmus-run-gate: | build
	@ echo
	python3 hetlitmus/verify/runcheck.py
	python3 hetlitmus/verify/runcheck.py --bite
	@ echo "HetLitmus device-session wrapper gate: OK (and the gate bites)"

### The same wrapper on the device with NO stand-in -- real probe, real nvcc,
### real harness -- so the chain completes and the results dir records only the
### machine its pair entitles it to name (verify/runcheck.py --hw).  Needs a GPU.
hetlitmus-run-hw: | build
	@ echo
	python3 hetlitmus/verify/runcheck.py --hw
	python3 hetlitmus/verify/runcheck.py --hw --bite
	@ echo "HetLitmus device-session wrapper runtime gate: OK (and the gate bites)"

### The discriminating power of the toolchain lane: ptxcheck detects a weakened
### scope or order, the stress scaffolding bites a dead layer, the co-run gate
### catches a missing control, and two invariance checks get their teeth here.
hetlitmus-selftest: | build
	@ echo
	bash hetlitmus/verify/tokens.sh selftest
	bash hetlitmus/verify/tokens.sh guard
	bash hetlitmus/verify/smoke.sh bite
	@ echo "HetLitmus static token check discriminating power (selftest + guard + smoke bite): OK"

### Umbrellas (what you press).  `::` accumulation, order-only `| build`.
hetlitmus-test:: | build
hetlitmus-test:: hetlitmus-cram
hetlitmus-test:: hetlitmus-corpus
hetlitmus-test:: hetlitmus-dup
hetlitmus-test:: hetlitmus-lattice
hetlitmus-test:: hetlitmus-amd-controlmap
hetlitmus-test:: hetlitmus-controlmap
hetlitmus-test:: hetlitmus-verdict
hetlitmus-test:: hetlitmus-recfields
hetlitmus-test:: hetlitmus-stats
hetlitmus-test:: hetlitmus-hist
hetlitmus-test:: hetlitmus-tuner
hetlitmus-test:: hetlitmus-x86body
hetlitmus-test:: hetlitmus-x86fixture
hetlitmus-test:: hetlitmus-cpuonly
hetlitmus-test:: hetlitmus-run-gate

### The second umbrella takes a target when it needs a toolchain or a device this
### box may not have, and NOT when it merely concerns GPU code: the targets that
### read emitted GPU renders belong to the CUDA-free lane.
hetlitmus-test-toolchain:: | build
hetlitmus-test-toolchain:: hetlitmus-faithful
hetlitmus-test-toolchain:: hetlitmus-stress
hetlitmus-test-toolchain:: hetlitmus-cpustress
hetlitmus-test-toolchain:: hetlitmus-obs
hetlitmus-test-toolchain:: hetlitmus-hipbuild
hetlitmus-test-toolchain:: hetlitmus-characterize-hw
hetlitmus-test-toolchain:: hetlitmus-run-hw
hetlitmus-test-toolchain:: hetlitmus-selftest
hetlitmus-test-toolchain:: hetlitmus-smoke

hetlitmus-test-nvcc: hetlitmus-test-toolchain

hetlitmus-test-all:: | build
hetlitmus-test-all:: hetlitmus-test
hetlitmus-test-all:: hetlitmus-test-toolchain

### Regenerate both corpora in place + promote cram goldens.  Does NOT commit.
hetlitmus-promote: | build
	@ echo
	PATH="$(PWD)/_build/install/default/bin:$$PATH" bash hetlitmus/tests/gpu-only/generate.sh
	PATH="$(PWD)/_build/install/default/bin:$$PATH" bash hetlitmus/tests/het/generate.sh
	# atomic: a failed --emit must not truncate the committed map
	python3 hetlitmus/verify/controlmap.py --lattice x86 --emit > hetlitmus/tests/het/.control-map-amd.csv.new \
	  && mv -f hetlitmus/tests/het/.control-map-amd.csv.new hetlitmus/tests/het/control-map-amd.csv
	dune test hetlitmus/tests/cram --auto-promote
	@ echo "hetlitmus-promote: corpora regenerated + cram goldens promoted (NOT committed)."
	@ echo "hetlitmus-promote: review 'git diff' then commit yourself."

.PHONY: hetlitmus-cram hetlitmus-corpus hetlitmus-faithful hetlitmus-smoke
.PHONY: hetlitmus-stress hetlitmus-cpustress hetlitmus-stats hetlitmus-tuner hetlitmus-obs
.PHONY: hetlitmus-hist hetlitmus-dup hetlitmus-lattice
.PHONY: hetlitmus-controlmap hetlitmus-verdict hetlitmus-selftest
.PHONY: hetlitmus-recfields
.PHONY: hetlitmus-x86body hetlitmus-hipbuild hetlitmus-cpuonly
.PHONY: hetlitmus-x86fixture hetlitmus-characterize-hw hetlitmus-run-gate hetlitmus-run-hw
.PHONY: hetlitmus-amd-controlmap
.PHONY: hetlitmus-test hetlitmus-test-toolchain hetlitmus-test-nvcc
.PHONY: hetlitmus-test-all hetlitmus-promote

include Makefile.x86_64
include Makefile.aarch64
