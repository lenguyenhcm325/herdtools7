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

### HetLitmus test targets (Layer 1-3; see hetlitmus/docs/TEST-PLAN.md sec.6).
### Mirror the herdtools7 idiom (`| build` order-only prereq + `@ echo OK`).
### Deliberately NOT wired into upstream `test::`: the main suite stays fast and
### CUDA-free (folding in `hetlitmus-test` is a documented open decision, sec.10).
### The verify scripts self-export PATH (`_build/install/default/bin`, plus
### `/usr/local/cuda/bin` on the nvcc lane), so leaf targets just invoke them.

### Building blocks (run solo while iterating).
hetlitmus-cram: | build
	@ echo
	dune runtest hetlitmus/tests/cram
	@ echo "HetLitmus Layer-1 cram: OK"

hetlitmus-corpus: | build
	@ echo
	bash hetlitmus/verify/corpus-gate.sh
	@ echo "HetLitmus Layer-2 corpus golden: OK"

hetlitmus-faithful: | build
	@ echo
	bash hetlitmus/verify/l0_tokens.sh all
	@ echo "HetLitmus Layer-3 PTX faithfulness (548): OK"

hetlitmus-smoke: | build
	@ echo
	bash hetlitmus/verify/smoke.sh
	@ echo "HetLitmus Layer-3 compile-smoke: OK"

### hetlitmus-faithful proves the harness carries exactly the tested ops and is
### blind to the stress layer by design (scaffolding is not a model op) -- which
### is how a stress layer that compiled to ZERO instructions once passed it.
### This gate is the other half: the scaffolding must be in the PTX.
hetlitmus-stress: | build
	@ echo
	bash hetlitmus/verify/l0_tokens.sh stress
	@ echo "HetLitmus Layer-3 stress liveness: OK"

### hetlitmus-stress covers the GPU scratchpad layer.  The CPU-side and
### interconnect (C2C) levers are invisible to both ptxcheck and stresscheck: the
### M3 preload emits host cache hints (no order, no scope, not a model op), the
### enemies are host threads that never enter the PTX, and the noise streams a
### disjoint buffer.  This gate reads the COMPILED -O2 asm (both host ISAs) and
### runs the layer, requiring it to be live when on and zero when off.
hetlitmus-cpustress: | build
	@ echo
	bash hetlitmus/verify/l0_tokens.sh cpustress
	@ echo "HetLitmus Layer-3 CPU+interconnect stress liveness: OK"

### hetlitmus-controlmap: the positive control (hetlitmus/docs/positive-control.md).
### Every one of the 18 Disallowed tests must have a mutant mu(T) that EXISTS and is
### labelled Allowed, re-derived from the corpus sources + the oracle and never
### from the test's name (MP-gc-sys-acquire and two siblings do not exist at all).
### It fails closed: a missing mutant breaks the build rather than skipping the
### control, because a silently absent control does not weaken a null -- it makes
### it unfalsifiable.  CUDA-free.
### --bite is that fail-closed claim's evidence: four injections into a scratch
### copy of the corpus + oracle + map (mu's .litmus deleted, mu relabelled
### Disallowed, the Mu column rewritten from the test's NAME, mu swapped for
### another shape), each of which must redden --check by the NAME of the property
### it broke.  Until 2026-08-02 this was the one gate in the suite that had never
### been seen to fail.
hetlitmus-controlmap: | build
	@ echo
	python3 hetlitmus/verify/controlmap.py --check
	python3 hetlitmus/verify/controlmap.py --bite
	@ echo "HetLitmus B6 control map: OK (and the gate bites)"

### hetlitmus-amd-controlmap: the SAME gate on the AMD / MI300A map.  It is a
### separate artifact and a separate lattice, not a translation (memo 7.D11): on
### x86 the CPU strength lattice loses its middle rung, so a candidate that only
### moves within {ra,st,ld} is NOT a weakening there.  The oracle it is derived
### against is expected-amd.csv and its census is 19 Disallowed, not the NVIDIA
### lane's 18 (AMD: D26 2026-08-04 demoted 127 of 146; NVIDIA: NVOR 2026-08-06
### demoted 32 of 50 -- two unrelated strikes that happen to land one apart).
### Regenerate with:
###   python3 hetlitmus/verify/controlmap.py --lattice x86 --emit \
###     > hetlitmus/tests/het/control-map-amd.csv
hetlitmus-amd-controlmap: | build
	@ echo
	python3 hetlitmus/verify/controlmap.py --lattice x86 --check
	@ echo "HetLitmus AMD control map: OK"

### hetlitmus-oracle: the het oracle's GENERATOR vs its committed artifact.
### tests/het/expected-nvidia.csv is the 411-row table every het verdict is
### scored against, and no target and no gate ever re-ran the script that builds
### it: generator-vs-artifact drift was detectable only on the 128 two-sided rows
### ordercheck.py independently re-derives, leaving ~283 rows unpinned.  This
### regenerates it from the corpus into a TEMP dir (the committed file is never
### touched) and diffs.  build-nvidia-oracle.sh is pure bash -- measured 0.11 s
### -- so it belongs in the fast CUDA-free `hetlitmus-test' umbrella rather than
### `-test-all'; no `| build' for the same reason (it invokes no herdtools7 tool).
### Bite it by pointing HET_ORACLE at a corrupted scratch copy:
###   make hetlitmus-oracle HET_ORACLE=/tmp/one-row-flipped.csv
### HET_ORACLE / HET_AMD_ORACLE are also THE DEVIATION PATH for an ablation
### oracle: the pair table (litmus/hetOracle.ml) fixes which FILE NAME a pair
### stamps, so scoring a corpus against a variant oracle (expected-amd-x2a.csv,
### say) means pointing these at it here rather than editing the table.  The
### stamp then still names the pair's own file, which is correct: the deviation
### is the reviewer's, not the harness's.
HET_ORACLE ?= hetlitmus/tests/het/expected-nvidia.csv
hetlitmus-oracle:
	@ echo
	tmp=$$(mktemp -d); \
	( mkdir -p $$tmp/het \
	  && cp hetlitmus/tests/_grid_lib.sh $$tmp/ \
	  && cp hetlitmus/tests/het/build-nvidia-oracle.sh hetlitmus/tests/het/*.litmus $$tmp/het/ \
	  && bash $$tmp/het/build-nvidia-oracle.sh \
	  && diff -u $(HET_ORACLE) $$tmp/het/expected-nvidia.csv ); \
	rc=$$?; rm -rf $$tmp; exit $$rc
	@ echo "HetLitmus het oracle: OK ($(HET_ORACLE) matches its generator)"

### hetlitmus-nvroundtrip: the NVOR slot toggle's round trip + contingency list
### (the AMD G16 analog; NVOR, Nguyen 2026-08-06, env-research/NVOR-register.md).
### The adjudication DECLINED three registrations the Disallowed surface rested
### on -- the gc-direction meet (Q2, 19 rows), ARM-DMB-SY-is-a-PTX-fence.sc (Q3,
### 2) and the unidirectional-fence semantics (Q4, 11) -- so 32 rows are
### NO-ORACLE and the census is 319/18/74, not 319/50/42.  The demotion gates the
### SLOT, never the verdict: NVOR_ACCEPT_DECLINED=1 re-derives the pre-
### regeneration verdicts into a SEPARATE file (expected-nvidia-declined.csv --
### a counterfactual can never clobber the oracle), and this asserts the round
### trip touches EXACTLY those 32 rows, that each of them goes NO-ORACLE ->
### Disallowed out of a named UNKEYED class, and that nothing else moves.  It
### also re-prints the per-row contingency ("observing one of these outcomes on
### GH200 is DATA, not a refutation") and asserts the printed set is the pinned
### 32.  Both run INSIDE build-nvidia-oracle.sh on every generation, before the
### mv; this target is the same guards named and runnable on their own.
### Bite it by widening or narrowing the gate in a scratch copy -- the census
### pin, the demoted-set sha pin and the round trip each redden by name.
### Pure bash, ~0.5 s, no nvcc, no GPU.
hetlitmus-nvroundtrip:
	@ echo
	bash hetlitmus/tests/het/build-nvidia-oracle.sh --roundtrip
	bash hetlitmus/tests/het/build-nvidia-oracle.sh --declined-list
	@ echo "HetLitmus NVOR slot toggle: OK (round trip exact on the 32 demoted rows)"

### hetlitmus-amd-oracle: the SAME check for the AMD MI300A oracle.  Separate
### target because expected-amd.csv is a separate file with its own Model string
### -- there is no merge path and no per-row model dispatch (memo 9.2).  The AMD
### generator carries far more inside it than the NVIDIA one: the 34-row anchor
### gate G1 (which must pass 34/34 BEFORE the CSV is written), G15's !SWMR hook
### split, G13/G14's structural assertions and G0's program-synthesis check
### against all 411 .litmus files, so it takes ~14 s rather than 0.1 s.  Its 146
### Disallowed rows are 19 candidate FALSE REFUTATIONS of the compound memory
### model if any of them is wrong, which is why the regeneration is gated at all
### (D26 2026-08-04: 127 of the former 146 are now NO-ORACLE -- the strike is
### reversible via X2A_TRANSFERS=1, which gate G16 pins the verdict round trip).
### Bite it the same way:  make hetlitmus-amd-oracle HET_AMD_ORACLE=/tmp/bad.csv
HET_AMD_ORACLE ?= hetlitmus/tests/het/expected-amd.csv
hetlitmus-amd-oracle:
	@ echo
	tmp=$$(mktemp -d); \
	( mkdir -p $$tmp/het \
	  && cp hetlitmus/tests/_grid_lib.sh $$tmp/ \
	  && cp hetlitmus/tests/het/build-amd-oracle.sh hetlitmus/tests/het/*.litmus $$tmp/het/ \
	  && bash $$tmp/het/build-amd-oracle.sh \
	  && diff -u $(HET_AMD_ORACLE) $$tmp/het/expected-amd.csv ); \
	rc=$$?; rm -rf $$tmp; exit $$rc
	@ echo "HetLitmus AMD het oracle: OK ($(HET_AMD_ORACLE) matches its generator)"

### hetlitmus-amdorder: the machine-check behind expected-amd.csv, i.e. the
### gates of PORT2-R2-amd-oracle.md sect 9.4 that need an instrument the
### generator does not have.
###   Phase 1 G3   35 CPU-projection cells (11 shapes x {plain, MFENCE-per-proc})
###                under herd7 -cat x86tso.cat vs ord_x86, plus the header pin:
###                an X86_64 header is REFUSED by x86tso.cat and would otherwise
###                silently default to x86tso-mixed.cat
###   Phase 2 G4   the 12 GPU primitive cells with the INSTRUMENT NAMED PER CELL
###                (probe + kernel + recorded asm); amd-gcn3.cat is cited for
###                exactly two of them and both are DECIDED by running it
###   Phase 3 G5   the CSV read back: 411 rows, 258/146/7, the ten-class census
###                and the class -> verdict function ROW BY ROW -- asserted, not
###                printed.  (It also carried a provenance-grade census until
###                P2e removed the column, 2026-08-03.)
###   Phase 4 G6   x86-image collapse: 45 classes, 321 distinct programs, 0
###                inconsistent (the harness runs the identical x86 program)
###   Phase 5 G7   the T_x86 rendering under herd7: a NECESSARY condition on the
###           G8   17 K-CPU rows, and the one-directional guard `Sometimes =>
###                Allowed', with the strengthening property itself asserted
###   Phase 6 G12  S_CUT_MCA == 8 by memo 5.2's structural predicate re-derived
###           G13  here; 1092 external edges and 0 GPU->GPU; the unreachable
###           G14  primitives really absent
###   Phase 7 G15  the !SWMR hook split: narrow 48 / wide 65 / delta 17 == K-CPU
###   Phase 8 G10  the downstream census pins, as a fail-closed ledger
###   Phase 9 G11  the mu-map on the x86 strength lattice (memo 7.D11), derived
###                by controlmap.py --lattice x86: all 19 Disallowed rows carry a
###                Layer-A mutant and the no-mutant set is PINNED EMPTY (pre-D26:
###                130 of 146 with 16 that provably could not) so it can never
###                silently grow
### --bite corrupts the rule, the corpus, the instrument index, the CSV and the
### downstream pins and requires each injection to redden the phase it names, for
### the right reason, on CORRUPTION and on OMISSION both.  The injection COUNT is
### printed by the run itself -- an earlier version of this comment said 33 and
### the measured value was 35, which is exactly the kind of number nobody
### re-measures.  Budget roughly 15 s for the check and ~2 min for the bite.
hetlitmus-amdorder: | build
	@ echo
	python3 hetlitmus/verify/amdordercheck.py
	python3 hetlitmus/verify/amdordercheck.py --bite
	@ echo "HetLitmus AMD oracle machine-check: OK (and the gate bites)"

### hetlitmus-amdprov: citation PROVENANCE of expected-amd.csv (register D21's
### fault class, made mechanical).  The whitelist admitted [CMCM] at PAPER
### granularity; transferability is a property of SECTIONS, and sect 5-6 (the
### x86TSO+PTX instantiation) is EXCLUDED for the AMD oracle (Nguyen
### 2026-08-04).  amdprovcheck.py classifies every Source-string citation
### fragment into GEN (sect 3-4) / PTX (sect 5-6) / AMD (sect 7) / NONCMCM
### (per-tag disposition), fail-closed: an unknown fragment anywhere is an
### error, and a PTX-class fragment in a DISALLOWED row is the fault (a
### candidate false refutation; Allowed/NO-ORACLE are fail-safe directions).
### Until the regeneration lands, the known pre-regen fault set is PINNED
### byte-exactly (E2 = 138 rows, E3 = 8 rows, at-risk = 127) so the suite
### stays green while any drift -- growth OR silent shrink -- reddens the
### gate; the pin is then flipped to empty-findings.  No `| build' (invokes
### no herdtools7 tool); ~0.1 s + bite.
hetlitmus-amdprov:
	@ echo
	python3 hetlitmus/verify/amdprovcheck.py
	python3 hetlitmus/verify/amdprovcheck.py --bite
	@ echo "HetLitmus AMD oracle provenance: OK (and the gate bites)"

### hetlitmus-nvprov: citation PROVENANCE of expected-nvidia.csv -- the NVIDIA
### lane of the same fault (NVOR Phase A).  The AMD regeneration's handover
### pointed D21 at this oracle and it was dropped from that pass's scope, not
### resolved; post-D26 these 411 rows (319/50/42) are the project's LARGEST
### falsification surface and were built before the rigor apparatus existed.
### GH200 is ARMv9 Grace + Hopper/PTX, so it inherits the PTX half of CMCM
### sect 5-6 and NOT its x86TSO half -- a finer partition than the AMD lane's
### wholesale strike.  nvprovcheck.py classifies every Source-string fragment
### into GEN / PTX5 / X86C / CMCM-BARE / BAGCHI / ARM / PTX-L19 / PTX-ISA-8.6 /
### NONCMCM, fail-closed (an unknown fragment anywhere is an error), rejoining
### CSV fields 4+ because 38 Source strings carry a comma on purpose.  The
### PTX-L19 vs PTX-ISA-8.6 split is ROW-AWARE -- `fence.{acquire,release}'
### postdates Lustig'19, so a PTX cite on a `.rel-2s'/`.acq-2s' row is spec
### prose, not formalization -- which turns the version-drift exposure into a
### pinned 17-of-50 number instead of prose in a plan file.
### Phase A is REPORT-ONLY (P2e verdict-neutrality): no verdict moves before
### adjudication, so the measured faults are PINNED rather than fatal --
### E2 = 2 (CMCM Fig 2a on Disallowed) / E3 = 0 / E5 = 11 (bare [CMCM] on
### Disallowed) / E6 = 21 (Allowed keyed only to nvidia-ptx.cat), sha
### 57298d22a8c3a260 over the 34 offender rows.  Drift in EITHER direction
### reddens the gate, and PHASE D MUST FLIP THIS PIN to zeros in the same
### commit as the regeneration -- green here means "the fault is exactly this
### big", not "there is no fault".  No `| build' (invokes no herdtools7 tool);
### ~0.1 s + bite.
### *** RED SINCE THE NVOR REGENERATION (2026-08-06), BY DESIGN. *** Every number
### in this block and every pin in nvprovcheck.py -- the census (319/50/42), the
### fault pin, the 8.6-row sha, the FRAGMENTS table, the 38 comma rows --
### describes the PRE-regeneration CSV.  It is not re-pinned here on purpose:
### R2's B5 rule measured that flipping the fault pin to zeros over the CURRENT
### parser lets a re-introduced fault pass GATE GREEN in all four simulated
### scenarios, so the parser blind-spot fixes (B1: EVENT_NOTATION is fullmatched
### and `continue'd with NO error; B2/B3: fragments outside brackets; B4: E6 on
### KEYLESS Allowed; B6: E2/E5 on non-Disallowed rows) and the pin flip must land
### TOGETHER, in the companion NVOR Phase-D2 commit.  Until then this gate fails
### on fragment/pin drift and that failure is the handover.
hetlitmus-nvprov:
	@ echo
	python3 hetlitmus/verify/nvprovcheck.py
	python3 hetlitmus/verify/nvprovcheck.py --bite
	@ echo "HetLitmus NVIDIA oracle provenance: OK (and the gate bites)"

### hetlitmus-dup: the isomorphism gate.  generate.sh dedups only by
### byte-comparing a variant against ONE designated sibling, which cannot see a
### duplicate up to (proc permutation x location renaming).  The corpus carried 39
### such classes, all cg/gc mirror pairs of a rotation-invariant shape (SB/LB/2+2W)
### and some inside the Disallowed rows that carry the falsification claim
### (env-research/Q10-corpus-coverage.md sect 2.1); they were removed at the source
### on 2026-08-01, so the 411 files are 411 distinct experiments and the allowlist is
### empty.  The gate fails on any duplicate not in the list AND on any list entry
### that has stopped being one -- an allowlist that cannot rot.  --bite proves both
### halves fail, each for the right reason.
hetlitmus-dup: | build
	@ echo
	python3 hetlitmus/verify/dupcheck.py
	python3 hetlitmus/verify/dupcheck.py --bite
	@ echo "HetLitmus Q10 isomorphism/dedup gate: OK (and the gate bites)"

### hetlitmus-order: the ordering rule behind the two-sided oracle, machine-
### checked against both constituent solvers.  The `-2s' rows are the only ones
### that can be Disallowed -- the only ones that can refute the compound model --
### and they span a 4x4 grid of CPU{STLR/LDAPR,DMB.SY,DMB.ST,DMB.LD} x
### GPU{rel/acq atoms,fence.sc,fence.release,fence.acquire}.sys.  Which cells
### forbid is not "both sides have a fence", hand verdicts are how an oracle
### acquires a silent error, and an oracle error here is a FALSE REFUTATION of
### the model, so build-nvidia-oracle.sh carries a compositional rule and this
### gate proves it is the same function herd7 computes (hetlitmus/docs/
### het-oracle.md, "Two-sided order pairs"):
###   ARM     96 CPU-only AArch64 cells under herd7's native model
###   PTX     96 GPU-only LISA/Bell cells under nvidia-ptx.cat (Lustig'19)
###   ORACLE  all 128 two-sided 2-proc rows of expected-nvidia.csv -- an asserted
###           count, so neither can the bash oracle and the rule drift apart nor
###           can a half-blind phase pass
### --bite corrupts the rule six ways and requires each to redden the phase that
### names it.  ~3 s; no nvcc, no GPU.
hetlitmus-order: | build
	@ echo
	python3 hetlitmus/verify/ordercheck.py
	python3 hetlitmus/verify/ordercheck.py --bite
	@ echo "HetLitmus Q10 two-sided ordering rule: OK (and the gate bites)"

### hetlitmus-verdict: het_verdict() -- the rule that decides what an observation
### MEANS -- compiled from the real emitted header and fed synthetic records.
###   Phase 1 (rule)     all seven verdicts and all three oracle classes are
###                      reachable (a rule that always returns the same verdict is
###                      not a decision, and a three-way branch keyed off a
###                      constant field is the same bug); exhaustive_valid==0 can
###                      never yield a credible null; every liveness disqualifier
###                      bites; ORACLE_UNSET fails closed.
###   Phase 2 (printout) the refutation claims are reachable from ORACLE_DISALLOWED
###                      and from nothing else.  361 of the 411 het tests are not
###                      should-be-forbidden, and a refutation printed on one of
###                      them is a false refutation of the compound model.  The
###                      verdict enum changing is not the deliverable; the sentence
###                      is.
###   Phase 3 (corpus)   all 411 emitted harnesses carry the oracle class
###                      control-map.csv gives them (census 18 / 319 / 74, zero
###                      untagged).  A rule that branches on a class the emitter
###                      never sets is a rule nobody runs.
###   Phase 4 (machine)  which MACHINE the printout names.  The interconnect prose
###                      comes from defines the emitter stamps out of the oracle
###                      PAIR table, scraped here from real emissions: unstamped
###                      is the generic frame, each pair prints its own machine,
###                      and no frame prints another pair's.
### --bite: 11 injections (4 against the rule, 2 against its reporting paths, 2
### against the emitted corpus, 3 against the machine prose), each verified to
### have actually changed the code it corrupts.
hetlitmus-verdict: | build
	@ echo
	python3 hetlitmus/verify/verdictcheck.py
	python3 hetlitmus/verify/verdictcheck.py --bite
	@ echo "HetLitmus B6/B6c decision rule: OK (and the gate bites)"

### hetlitmus-stats: het_stats_compute() -- what a "Never" is WORTH -- compiled
### from the real emitted header and driven with synthetic record streams
### (statscheck.py).  A gate that exists but is not in the build is not a gate but
### a script, which is why this target lands with the script it runs.
###   estimator   mu_upper pinned to the closed form (3 -> 19 -> 199.5); budget symbol
###   aggregate   every statistic differentially checked vs an independent Python
###               re-derivation; every class/flag/tier reachable (anti-constant)
###   tau/N_eff   Geyer initial-positive-sequence recovers known AR(1)
###               autocorrelation times; N_eff clamped to [1, HET_NWIN]; the
###               tau-at-cap regime reproduces the run-level bound exactly
###   producer    the per-window sub-tallies live BOTH ways on the real emitted scan
###   corpus      all 411 carry the post-pass + a decode channel
###   scheduler   campaign.py stopping policy on a stub runner: Allowed rows stop
###               at first clean sighting, bound rows at p_goal or budget
### --bite: cmp-verified injections into the statistics.  (B7/B7b)
hetlitmus-stats: | build
	@ echo
	python3 hetlitmus/verify/statscheck.py
	python3 hetlitmus/verify/statscheck.py --bite
	@ echo "HetLitmus B7/B7b statistics layer: OK (and the gate bites)"

### hetlitmus-hist: the outcome-histogram gate.  verdictcheck and statscheck read
### the het_obs_record; nothing else looks at litmus7's inherited outs histogram,
### where a hardware run once printed a witness total ABOVE the frames examined,
### on a row whose columns contradicted the witness.
###   shape       the histogram add is inside the per-frame loop iff the harness
###               has a per-frame observable; the 11 reader-less shapes add once
###               per run (their `_weak' is the run-level observer witness, so an
###               in-loop add multiplies one observation by N)
###   display     a coherence-final [ell] column is never printed as a number: no
###               such number is measured (`_o[n_reg+j]' is the constant 0)
###   arithmetic  the store-only tally is extracted verbatim from the emitted .cu,
###               linked against the harness's own outs.c and RUN: sum_outs must
###               be R for every forced witness pattern and must not scale with N
### CUDA-free (litmus7 + cc).  --bite: 5 injections, each cmp-verified non-vacuous
### and each required to redden the phase that names it -- an injection that only
### breaks compilation (exit 2) is not a bite.  (F-A)
hetlitmus-hist: | build
	@ echo
	python3 hetlitmus/verify/histcheck.py
	python3 hetlitmus/verify/histcheck.py --bite
	@ echo "HetLitmus F-A histogram tally + display: OK (and the gate bites)"

### hetlitmus-tuner: the autotuner SEARCH MACHINERY (tune.py), validated on the
### dev box against synthetic objectives with a known optimum, because a real
### death rate is hardware-only (Q7 4.2).  Pure Python (no litmus7, no nvcc), so
### no `| build`.  The gate does not check that the search runs -- a tuner that
### always returns the seed would pass that -- but that it FINDS a known optimum,
### refuses to crown a phantom on a constant objective, and breaks when any of
### Q7's three data-peeking adaptations is removed:
###   optimum     the search returns the arg-max of distinct true means (100% of seeds)
###   phantom     a constant objective yields NO confident winner (anti-7th-constant)
###   drift       SER^3 randomized round-robin de-confounds a rising baseline where the
###               SEQUENTIAL order (Kirkham Fig.10) picks the late config     [Q7 5.2 C2]
###   overdisp    empirical-Bernstein RETAINS the true optimum where the Bernoulli CI
###               ELIMINATES it under Fano>1                                  [Q7 5.2 A]
###   structural  the sampler can never reach an INSTRUMENT/DETECTOR knob (TRAP 1/2);
###               the config file carries zero tuned numerics on the dev box
###   ks-in-loop  a non-stationary bout (het_ks2 verdict, reused) is EXCLUDED [Q7 5.2 C1]
### --bite then PROVES each guard FAILS on a broken tuner, cmp-verified non-vacuous.
hetlitmus-tuner:
	@ echo
	python3 hetlitmus/tune.py --self-test >/dev/null
	python3 hetlitmus/verify/tunecheck.py
	python3 hetlitmus/verify/tunecheck.py --bite
	@ echo "HetLitmus B8a tuner search machinery: OK (and the gate bites)"

### hetlitmus-obs: the observer-liveness gate.  statscheck feeds a synthetic
### observer_unique_count, so no gate compiles the REAL emitted observer loop --
### which is how an -O2 hoist that pinned observer_unique_count<=1, leaving the 11
### store-only tests' only channel inert, stayed invisible to CI.  This extracts
### the real emitted observer + its args struct and compiles them at clang -O2 for
### x86-64 and aarch64, asserting a per-iteration reload survives inside every
### loop body.  --bite strips the `volatile' and requires a hoisted observer to
### fail (cmp-verified non-vacuous).  (DR1)
hetlitmus-obs: | build
	@ echo
	python3 hetlitmus/verify/obscheck.py
	python3 hetlitmus/verify/obscheck.py --bite
	@ echo "HetLitmus observer-liveness gate: OK (and the gate bites)"

### hetlitmus-x86body: the P2b gate -- is the x86-64 CPU thread of a het
### harness REAL?  Until 2026-08-03 hetCpuFront.ml wired HetCpuBody.empty_plan +
### emit_stub for X86_64, so an x86 CPU proc emitted a `(void)_n' no-op: the CPU
### thread tested nothing AND, measured over the 411 x86 renderings, litmus7
### emitted a harness for 39 and REFUSED 372 (308 could bind no read buffer, 64
### no mu) -- while EXITING 0.  Seven phases: emission coverage, body-vs-column
### fidelity, tag liveness (the B4 lesson -- emitting is not testing), the
### instructions surviving gcc to the .o, an aarch64 SMOKE, the fail-closed
### refusal (exit 3 + marker + no harness, plus emit-all.sh's two detectors),
### and the B6b co-run harnesses (T + mu(T) + canary share a proc index, so
### each body must be checked against its OWN test).  P2/P3/P7 pin their counts
### against a total derived from the corpus' own columns, so a phase that
### compared nothing FAILS instead of passing.  --bite injects into every phase
### on corruption AND on omission.
### The x86 renderings are generated on demand by tests/het/generate-x86.sh
### (411, 1:1 with the corpus); they are deliberately NOT committed (the oracle
### is keyed on the AArch64 names, corpus-gate.sh pins 411 and ~90 of them would
### be dupcheck duplicates).
### NOT covered here: the emitter byte-diff.  What protects the validated NVIDIA
### lane against an emitter regression is `hetlitmus/verify/emit-all.sh SNAP_x'
### run at two revisions followed by `diff -r' (~4938 files).  That is a
### two-revision instrument and cannot be a single-shot target, so it is run by
### hand for every emitter change; P5 below is only a smoke.
hetlitmus-x86body: | build
	@ echo
	python3 hetlitmus/verify/x86bodycheck.py
	python3 hetlitmus/verify/x86bodycheck.py --bite
	@ echo "HetLitmus x86-64 tagged CPU body gate: OK (and the gate bites)"

### hetlitmus-x86fixture: is tests/het-x86 still what its generators emit?
### Those five committed files -- three .litmus renderings plus one-row-per-test
### extracts of the two AMD maps -- are the ONLY route to the populated
### (x86_64, hip) pair for cram, smoke.sh and verdictcheck, because the real x86
### corpus is generated on demand and never committed and a cram sandbox has no
### hetgen7 on $$PATH.  Nothing else compared them against generate-x86.sh /
### tests/het/control-map-amd.csv / expected-amd.csv, so they could go stale in
### silence -- and a D26-class oracle re-derivation rewrites whole columns of the
### last two.  A stale fixture breaks no gate; it makes every gate that reads it
### test a configuration nothing ships.  Two verbatim comparisons (the .litmus
### bytes, then the map rows), each of which must be seen to fail.
### CUDA-FREE: generation and comparison need no GPU, so it belongs here and not
### in the -nvcc umbrella.  Seconds -- generate-x86.sh writes all 411 in ~8 s.
hetlitmus-x86fixture: | build
	@ echo
	python3 hetlitmus/verify/x86fixturecheck.py
	python3 hetlitmus/verify/x86fixturecheck.py --bite
	@ echo "HetLitmus het-x86 fixture sync gate: OK (and the gate bites)"

### Scratch output dir for hetlitmus-d10.  Never committed (.gitignore'd): the
### D10 tests are generated on demand, exactly like the x86 renderings
### (generate-x86.sh), so that corpus-gate.sh's 411-file pin and dupcheck.py stay
### meaningful -- both scan hetlitmus/tests/het NON-recursively (`find -maxdepth
### 1' / `glob("*.litmus")'), so a subdirectory is invisible to them.
### ABSOLUTE, and that is not cosmetic: generate-d10.sh cd's to its own directory
### before it resolved OUTDIR, so the relative form of this variable used to be
### re-rooted at hetlitmus/tests/het/ and the target had NEVER worked (MEASURED
### 2026-08-03: RC=2 plus a stray hetlitmus/tests/het/hetlitmus/ tree).  The
### generator now resolves OUTDIR first; this stays absolute as the belt to that
### braces, and because the recipe below cd's into it.
HETD10OUT := $(CURDIR)/hetlitmus/tests/het/d10-out

### The GPU dialect these harnesses are rendered for.  litmus7 emits ONE vendor
### per harness dir (-gpu-target), and the ORACLE lives on the PAIR: this corpus
### has an x86_64 CPU column and ships control-map-amd.csv, so `hip' is the
### populated pair (x86_64, hip) and the one that reads those maps.  Rendering it
### for `cuda' is legal -- (x86_64, cuda) is REGISTERED WITHOUT AN ORACLE, the
### dev box -- but every harness then stamps ORACLE_NONE and co-runs nothing,
### which is a machinery smoke and not a D10 reading.
HETD10TARGET ?= hip

### hetlitmus-d10: the CPU-ONLY POSITIVE CONTROL as a first-class campaign item
### (memo sect 7.D10, PHASE2-plan:71).  Generates the six CPU-only shapes, emits
### their harnesses and prints the campaign command for a machine that has a GPU.
### It does NOT run them: the D10 reading is about the SHARED ALLOCATION of the
### target box, so a result from any other machine is not a D10 result.
### IT IS IN THE `hetlitmus-test' UMBRELLA (generate + emit need no GPU).  It was
### not, and that is exactly why a target that had never worked once shipped
### green: the SCIENCE this target carries was gated elsewhere, but nothing
### gated the COMMAND a human is told to run.
hetlitmus-d10: | build
	@ echo
	rm -rf $(HETD10OUT)
	hetlitmus/tests/het/generate-d10.sh $(HETD10OUT)
	@ set -e ; cd $(HETD10OUT) ; for t in *.litmus ; do \
	    $(CURDIR)/_build/install/default/bin/litmus7 \
	      -gpu-target $(HETD10TARGET) \
	      -set-libdir $(CURDIR)/litmus/libdir \
	      -o . "$$t" 2>&1 | grep -E 'oracle:|REFUSED' ; done
	@ set -e ; n=$$(ls -d $(HETD10OUT)/*/ 2>/dev/null | wc -l) ; \
	  test "$$n" -eq 6 || { echo "hetlitmus-d10: emitted $$n harness dir(s), expected 6" ; exit 1 ; }
	@ echo
	@ echo "D10 harnesses in $(HETD10OUT), rendered for $(HETD10TARGET).  On the TARGET box:"
	@ echo "    cd <test> && sh comp.sh $(HETD10TARGET)-link"
	@ echo "    ./<test>                            # SB and R must FIRE"
	@ echo "  then, for the campaign:"
	@ echo "    python3 hetlitmus/campaign.py --corpus $(HETD10OUT) \\"
	@ echo "        --control-map $(HETD10OUT)/control-map-amd.csv \\"
	@ echo "        --runner 'sh hetlitmus/spotcheck/run-one.sh {dir} {test}'"
	@ echo "  (no --d10 flag: campaign.py reads cpu_only= off the HetStats line,"
	@ echo "   so the WB-probe verdict cannot be forgotten at the command line.)"

### hetlitmus-hipbuild: the P2c gate -- can an AMD harness be BUILT AND RUN?
### Until 2026-08-03 hetEmit.ml contained ZERO occurrences of hip-link/hip-bin:
### comp.sh's `hip' arm was compile-only (`hipcc -c') and the Makefile had no HIP
### link target at all, so nothing this suite emits could become an AMD
### executable.  Emitting a .hip that no target links is the same defect class as
### the .hip that, until B5, no gate compiled.  Seven phases: the build-script
### arms, `hipcc --offload-arch=gfx942 -c', the two link arms each producing an
### ELF that CARRIES the gfx942 code object (the ELF is read -- a gfx90a build
### links and exits 0 too), the uname -m refusal on an AArch64 render, the
### no-silent-stale-link rounds, the allocator's fail-closed HET_ALLOC handling,
### and CUDA non-regression.  Every phase counts its assertions and fails if it
### made none.  --bite injects into all seven on corruption AND on omission.
### P5 EXISTS BECAUSE OF A MEASURED REGRESSION.  Both vendors link ./<test> on
### purpose (run-one.sh and campaign.py exec ./<test> and stay vendor-agnostic).
### With cuda-bin as a phony carrying a FILE prerequisite, `make cuda-bin' after
### `make hip-bin' printed "Nothing to be done for 'cuda-bin'", exited 0 and left
### the gfx942 binary in place -- a CUDA build handing back the AMD harness.
### Both link targets are unconditional .PHONY recipes now, and P5 alternates
### four builds because the trap needs the other vendor's object to exist and be
### OLDER than the binary: a two-round A-then-B check passes against a broken
### Makefile.
### NEEDS hipcc AND nvcc, hence the -nvcc umbrella (which is really the
### toolchain umbrella: smoke.sh already needs nvcc+hipcc+clang).
### DEFERRED, and the gate says so on success: there is NO AMD GPU on this box
### (`rocminfo' reports 0 gfx agents), so no phase EXECUTES the linked harness on
### a device.  P6 lifts the allocator resolver verbatim out of the emitted .hip
### and drives it against a stub hipDeviceGetAttribute, so every refusal path is
### really executed and its message observed; the real hipMallocManaged
### coherence behaviour stays unverified until Phase 3a (MI300X).
hetlitmus-hipbuild: | build
	@ echo
	python3 hetlitmus/verify/hipbuildcheck.py
	python3 hetlitmus/verify/hipbuildcheck.py --bite
	@ echo "HetLitmus AMD build/link gate: OK (and the gate bites)"

### hetlitmus-noracle: no committed script passes `-allow-no-oracle' (D-MV4).
### The flag emits a harness for a (CPU ISA x GPU dialect) pair the oracle table
### does not carry -- every test stamped ORACLE_NONE, the override disclosed in
### the stamp -- which is right for a human bringing up a new machine and wrong
### for a script, because in a script it turns a refusal a human reads into a
### line a campaign scrolls past.  The gate reads the tree; --bite plants the
### flag in a copy of a committed script and requires the gate to redden.
hetlitmus-noracle:
	@ echo
	bash hetlitmus/verify/allow-no-oracle-gate.sh
	bash hetlitmus/verify/allow-no-oracle-gate.sh --bite
	@ echo "HetLitmus no-oracle override containment: OK (and the gate bites)"

### hetlitmus-noracle-hw: what a REGISTERED NO-ORACLE harness PRINTS, on a GPU.
### (x86_64, cuda) is registered without an oracle AND is the pair this dev box
### is, so it is what every runtime bite in the tree actually executes.  Such a
### harness reads NO positive-control map, so nothing co-runs and nothing marks
### any row a canary -- and the statistics layer used to infer the opposite from
### "no record has a control", printing "it IS the Layer-B canary (control-map.csv
### says `self')" and "NO BOUND -- by construction, not by omission" on a real run
### where no map had been read, nothing had marked that row a canary, and the
### bound was missing because the bootstrap map generator does not exist yet.
### Every other gate on that stack drives it from synthetic records or emitted
### TEXT; this one builds the harness, RUNS it, and reads the printout.  Seven
### assertions (stamp, no self-canary sentence, the no-map sentence,
### CHARACTERIZED against the pair NAME, no MATCH/MISMATCH, no Grace/Hopper/
### NVLink/C2C/GH200, and the observation class on k < R).
### NEEDS A DEVICE, hence the -nvcc umbrella; with none visible it FAILS rather
### than skipping, because a gate that quietly stops checking is the failure mode
### this suite has already shipped twice.  Three of its assertions need one
### sighting, so it re-seeds up to 12 times (~3 s per run) before giving up.
hetlitmus-noracle-hw: | build
	@ echo
	python3 hetlitmus/verify/noraclerun.py
	python3 hetlitmus/verify/noraclerun.py --bite
	@ echo "HetLitmus registered-NO-ORACLE runtime gate: OK (and the gate bites)"

### hetlitmus-run-gate: the DEVICE-SESSION WRAPPER (hetlitmus/hetlitmus-run.sh),
### driven end to end with no device.  The wrapper is the one command a hardware
### session runs, and what it decides -- which oracle pair the corpus and the
### -gpu-target flag select, which architecture the binaries are built for,
### whether the campaign adjudicates or characterizes -- is decided on a machine
### nobody is watching and survives only in what it wrote down.
### CUDA-FREE because the wrapper's seams take stand-ins: NVCC/HIPCC point at a
### stub compiler that writes a harness printing one HetStats line, and
### HET_PROBE_SH at a stub probe.  The chain itself is real -- litmus7 emits, the
### emitted comp.sh + Makefile build, campaign.py schedules -- and the wrapper
### RECORDS that stand-ins were used, so a stubbed results dir can never be read
### as a reading of a machine.
### Eight phases: --dry-run writes nothing at all; the chain end to end on each
### dialect this host's pair table reaches, plus --reuse-emitted; the refusals,
### each by its own reason; campaign.py --characterization, where the same runner
### that stops an Allowed row OBSERVED and a Disallowed row CONFIRMED under a
### control map must reach neither, and the states no campaign may resume; the
### pair-table reader, bounded to the table literal; every fail-closed handler,
### under the condition it exists for (a failing compiler, a failing probe, two
### devices, an errored campaign, a doctored emission); a second session into a
### results dir that already holds one; and probe-hip.sh's exit paths.  --bite
### plants one defect per assertion in a COPY of the script under test and
### requires the phase to redden FOR THAT REASON.
### HOST-ADAPTIVE, not x86-only: the chain phases pick the committed x86 fixture
### on an x86_64 box and a cut of the committed AArch64 corpus on an aarch64 one,
### so the GH200 runs this same gate over its own (AArch64, cuda) pair.
hetlitmus-run-gate: | build
	@ echo
	python3 hetlitmus/verify/runcheck.py
	python3 hetlitmus/verify/runcheck.py --bite
	@ echo "HetLitmus device-session wrapper gate: OK (and the gate bites)"

### hetlitmus-run-hw: the same wrapper, on the device, with NO stand-in -- the
### real probe, the real nvcc, the real harness.  The pair it reaches is the
### (<this host's CPU lane>, cuda) row, which on the dev box is registered without
### an oracle -- exactly the new-hardware session the wrapper exists for: what is
### asserted is that the chain completes, that the campaign took the mode that
### row entitles it to unprompted, and that the results dir names the arch it
### resolved and no stand-in.
### A harness whose pinned read-modify-write is not system-atomic against the
### host can lose a barrier increment and stall (the probe measures it on this
### box); a stalled session is retried up to 3 times and only an all-stall is
### reported, the same rule noraclerun.py uses.
### NEEDS A DEVICE, hence the -nvcc umbrella.
hetlitmus-run-hw: | build
	@ echo
	python3 hetlitmus/verify/runcheck.py --hw
	python3 hetlitmus/verify/runcheck.py --hw --bite
	@ echo "HetLitmus device-session wrapper runtime gate: OK (and the gate bites)"

### hetlitmus-l0-selftest: the DISCRIMINATING-POWER proofs of the nvcc lane.
### l0_tokens.sh {selftest,guard} prove ptxcheck can detect a weakened scope/order
### and that the stress/cpustress scaffolding bites a dead layer; smoke.sh bite
### proves the co-run gate catches a missing control.  Without this target a
### silently neutered ptxcheck would still pass `make hetlitmus-test-all'.  Two
### invariance checks (stresscheck check-5 pattern-invariance, cpustresscheck
### S4/G2) pass trivially on shipped runtime-valued code and get their teeth only
### here.  (DR1)
hetlitmus-l0-selftest: | build
	@ echo
	bash hetlitmus/verify/l0_tokens.sh selftest
	bash hetlitmus/verify/l0_tokens.sh guard
	bash hetlitmus/verify/smoke.sh bite
	@ echo "HetLitmus L0 discriminating power (selftest + guard + smoke bite): OK"

### Umbrellas (what you press).  `::` accumulation, order-only `| build`.
hetlitmus-test:: | build
hetlitmus-test:: hetlitmus-cram
hetlitmus-test:: hetlitmus-corpus
hetlitmus-test:: hetlitmus-dup
hetlitmus-test:: hetlitmus-order
hetlitmus-test:: hetlitmus-oracle
hetlitmus-test:: hetlitmus-nvroundtrip
hetlitmus-test:: hetlitmus-amd-oracle
hetlitmus-test:: hetlitmus-amdorder
hetlitmus-test:: hetlitmus-amdprov
hetlitmus-test:: hetlitmus-nvprov
hetlitmus-test:: hetlitmus-amd-controlmap
hetlitmus-test:: hetlitmus-controlmap
hetlitmus-test:: hetlitmus-noracle
hetlitmus-test:: hetlitmus-verdict
hetlitmus-test:: hetlitmus-stats
hetlitmus-test:: hetlitmus-hist
hetlitmus-test:: hetlitmus-tuner
hetlitmus-test:: hetlitmus-x86body
hetlitmus-test:: hetlitmus-x86fixture
hetlitmus-test:: hetlitmus-d10
hetlitmus-test:: hetlitmus-run-gate

hetlitmus-test-nvcc:: | build
hetlitmus-test-nvcc:: hetlitmus-faithful
hetlitmus-test-nvcc:: hetlitmus-stress
hetlitmus-test-nvcc:: hetlitmus-cpustress
hetlitmus-test-nvcc:: hetlitmus-obs
hetlitmus-test-nvcc:: hetlitmus-hipbuild
hetlitmus-test-nvcc:: hetlitmus-noracle-hw
hetlitmus-test-nvcc:: hetlitmus-run-hw
hetlitmus-test-nvcc:: hetlitmus-l0-selftest
hetlitmus-test-nvcc:: hetlitmus-smoke

hetlitmus-test-all:: | build
hetlitmus-test-all:: hetlitmus-test
hetlitmus-test-all:: hetlitmus-test-nvcc

### Regenerate both corpora in place + promote cram goldens.  Does NOT commit.
hetlitmus-promote: | build
	@ echo
	PATH="$(PWD)/_build/install/default/bin:$$PATH" bash hetlitmus/tests/gpu-only/generate.sh
	PATH="$(PWD)/_build/install/default/bin:$$PATH" bash hetlitmus/tests/het/generate.sh
	bash hetlitmus/tests/het/build-nvidia-oracle.sh
	bash hetlitmus/tests/het/build-amd-oracle.sh
	# atomic: a failed --emit must not truncate the committed map (same reason
	# build-amd-oracle.sh writes to a temp file and renames -- P2a 2026-08-02)
	python3 hetlitmus/verify/controlmap.py --lattice x86 --emit > hetlitmus/tests/het/.control-map-amd.csv.new \
	  && mv -f hetlitmus/tests/het/.control-map-amd.csv.new hetlitmus/tests/het/control-map-amd.csv
	dune test hetlitmus/tests/cram --auto-promote
	@ echo "hetlitmus-promote: corpora regenerated + cram goldens promoted (NOT committed)."
	@ echo "hetlitmus-promote: review 'git diff' then commit yourself."

.PHONY: hetlitmus-cram hetlitmus-corpus hetlitmus-faithful hetlitmus-smoke
.PHONY: hetlitmus-stress hetlitmus-cpustress hetlitmus-stats hetlitmus-tuner hetlitmus-obs
.PHONY: hetlitmus-hist hetlitmus-dup hetlitmus-order hetlitmus-oracle
.PHONY: hetlitmus-nvroundtrip
.PHONY: hetlitmus-controlmap hetlitmus-verdict hetlitmus-l0-selftest
.PHONY: hetlitmus-x86body hetlitmus-hipbuild hetlitmus-d10 hetlitmus-noracle
.PHONY: hetlitmus-x86fixture hetlitmus-noracle-hw hetlitmus-run-gate hetlitmus-run-hw
### Neither AMD target was phony until P2a (2026-08-02).  They worked only
### because no file of those names happened to exist -- one `touch' away from a
### gate that silently stops running.
.PHONY: hetlitmus-amd-oracle hetlitmus-amdorder hetlitmus-amdprov hetlitmus-amd-controlmap
.PHONY: hetlitmus-nvprov
.PHONY: hetlitmus-test hetlitmus-test-nvcc hetlitmus-test-all hetlitmus-promote

include Makefile.x86_64
include Makefile.aarch64
