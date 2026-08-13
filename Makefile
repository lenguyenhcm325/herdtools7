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
### `/usr/local/cuda/bin` on the toolchain lane), so leaf targets just invoke them.

### Building blocks (run solo while iterating).
hetlitmus-cram: | build
	@ echo
	dune runtest hetlitmus/tests/cram
	@ echo "HetLitmus Layer-1 cram: OK"

### hetlitmus-corpus: the Layer-2 golden gate -- corpus regression, census and
### emission golden.  --bite is the corpus half's evidence: [1/3] regenerates
### into a temp tree and compares it against the committed one, so a generator
### that writes nothing and one byte of drift each redden it by file name.
hetlitmus-corpus: | build
	@ echo
	bash hetlitmus/verify/corpus-gate.sh
	bash hetlitmus/verify/corpus-gate.sh --bite
	@ echo "HetLitmus Layer-2 corpus golden: OK (and the gate bites)"

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
### Every test off the lattice floor -- 333 of the 411 -- must name a mu(T) that
### EXISTS, is structurally identical, is at the floor of the strength lattice,
### carries the same scopes, and holds the rest of the experiment fixed (same init
### block, `scopes:' tree and condition, so it counts T's outcome and not another
### one); the other 78 ARE the floor and name `none'.  It is
### re-derived from the corpus sources and never from the test's name
### (MP-gc-sys-acquire and two siblings do not exist at all).  It fails closed: a
### missing mutant breaks the build rather than skipping the control, because a
### silently absent control does not weaken a null -- it makes it unfalsifiable.
### CUDA-free.
### --bite is that fail-closed claim's evidence: seven injections into a scratch
### copy of the corpus + map, run as eight arms because one of them is fed to two
### readers.  mu's .litmus deleted; mu swapped for a sibling of identical
### ordering strength on this lattice; the Mu column rewritten from the test's
### name; mu swapped for another shape; mu swapped for a strictly stronger
### sibling; the retired 8-column schema fed to both this gate and the emitter's
### own reader; and a mu whose accesses and annotations all still match while its
### `exists' counts a different outcome.  Each must redden by the NAME of the
### property it broke.
hetlitmus-controlmap: | build
	@ echo
	python3 hetlitmus/verify/controlmap.py --check
	python3 hetlitmus/verify/controlmap.py --bite
	@ echo "HetLitmus B6 control map: OK (and the gate bites)"

### hetlitmus-amd-controlmap: the SAME gate on the AMD / MI300A map.  It is a
### separate artifact and a separate lattice, not a translation (memo 7.D11): on
### x86 the CPU strength lattice loses its middle rung, so a candidate that only
### moves within {ra,st,ld} is NOT a weakening there.  The floor set is the same
### 78 rows either way -- no row's only ordering op is one of the four the x86
### lattice drops -- so the two maps differ in their MuAlt column, not their
### census; --check re-measures both floor sets rather than assuming it.
### --bite runs the same injections against a scratch copy of this lattice's
### artifact.  Its end-to-end arm feeds the emitter an x86 rendering out of
### tests/het-x86 rather than a corpus test, because litmus7 asks for the map by
### a name it takes from the CPU column (litmus/hetCpuFront.ml) and the het
### corpus is rendered for AArch64 under either lattice.
### Regenerate with:
###   python3 hetlitmus/verify/controlmap.py --lattice x86 --emit \
###     > hetlitmus/tests/het/control-map-amd.csv
hetlitmus-amd-controlmap: | build
	@ echo
	python3 hetlitmus/verify/controlmap.py --lattice x86 --check
	python3 hetlitmus/verify/controlmap.py --lattice x86 --bite
	@ echo "HetLitmus AMD control map: OK (and the gate bites)"

### hetlitmus-dup: the isomorphism gate.  generate.sh dedups only by
### byte-comparing a variant against ONE designated sibling, which cannot see a
### duplicate up to (proc permutation x location renaming).  The corpus carried 39
### such classes, all cg/gc mirror pairs of a rotation-invariant shape (SB/LB/2+2W)
### (env-research/Q10-corpus-coverage.md sect 2.1), and a mirror is not an
### independent sample.  They were removed at the source on 2026-08-01, so the 411
### files are 411 distinct experiments.  The gate is one check with no exceptions:
### any duplicate class at all fails it.  --bite clones a test under a new name
### twice, once per half of the canonical form -- locations renamed, and P0/P1
### swapped with their device tags -- and requires each to redden.  The second is
### the half the 39 were duplicates under.
hetlitmus-dup: | build
	@ echo
	python3 hetlitmus/verify/dupcheck.py
	python3 hetlitmus/verify/dupcheck.py --bite
	@ echo "HetLitmus Q10 isomorphism/dedup gate: OK (and the gate bites)"

### hetlitmus-lattice: the per-primitive ordering table behind the control-map
### lattice, machine-checked against both constituent solvers.  Each CPU
### primitive {STLR/LDAPR, DMB.SY, DMB.ST, DMB.LD} and each GPU primitive
### {rel/acq atoms, fence.sc, fence.release, fence.acquire}.sys orders a specific
### set of program-order pairs, and that set is the `ord' half of the (tier, ord)
### strength lattice controlmap.py uses to pick each test's positive-control
### sibling, so a wrong entry silently certifies a sibling that is not weaker.
### Which cells forbid is not "both sides have a fence": DMB.LD orders nothing on
### a store;store producer and a PTX release fence nothing on a load;load
### consumer, so the table meets the solvers rather than being asserted.
###   ARM    96 CPU-only AArch64 cells under herd7's native model
###   PTX    96 GPU-only LISA/Bell cells under nvidia-ptx.cat (Lustig'19)
###   AGREE  the 8 primitives keyed one by one against controlmap.py's own copy
###          of the same `ord' sets: agreeing with herd7 is not what keeps two
###          restated tables agreeing with each other.  The lattice's TIER half
###          is out of its reach and ordercheck.py says so at the key map.
### --bite corrupts the table five ways (a CPU ordered-pair set, a GPU one, a
### pattern role, the pattern clause itself, and controlmap's own copy) and
### requires each to redden the phase that names it -- which is the only phase it
### runs.  No nvcc, no GPU.
hetlitmus-lattice: | build
	@ echo
	python3 hetlitmus/verify/ordercheck.py
	python3 hetlitmus/verify/ordercheck.py --bite
	@ echo "HetLitmus ordering-table lattice gate: OK (and the gate bites)"

### hetlitmus-verdict: het_verdict() -- the rule that decides what an observation
### MEANS -- compiled from the real emitted header and fed synthetic records.
###   Phase 1 (rule)     all four outcomes are reachable (a rule that always
###                      returns the same one is not a decision); an UNSTAMPED
###                      record fails closed; exhaustive_valid==0 can never yield
###                      the strong null; every liveness disqualifier bites.
###   Phase 2 (printout) each outcome's sentences are reachable from THAT outcome
###                      and from no other, checked both ways.  The enum changing
###                      is not the deliverable; the sentence is.
###   Phase 3 (corpus)   all 411 emitted harnesses stamp rec_magic exactly once
###                      and co-run the mu(T)/canary population control-map.csv
###                      gives them (333 / 409).
###   Phase 4 (machine)  which MACHINE the printout names.  The interconnect prose
###                      comes from defines the emitter stamps out of the PAIR
###                      table, scraped here from real emissions: unstamped is the
###                      generic frame, each pair prints its own machine, and no
###                      frame prints another pair's.
### --bite: 17 injections (8 against the rule and its printouts, 2 against its
### reporting paths, 2 against the emitted corpus, 5 against the machine prose),
### each verified to have actually changed the code it corrupts.  A machine arm
### also names the diagnostic it expects first, because the prose is guarded in
### two directions -- a sentence that stopped printing and a sentence that names
### another vendor -- and only the last arm reddens on the second.
hetlitmus-verdict: | build
	@ echo
	python3 hetlitmus/verify/verdictcheck.py
	python3 hetlitmus/verify/verdictcheck.py --bite
	@ echo "HetLitmus B6 decision rule: OK (and the gate bites)"

### hetlitmus-stats: het_stats_compute() -- what a "Never" is WORTH -- compiled
### from the real emitted header and driven with synthetic record streams
### (statscheck.py).  A gate that exists but is not in the build is not a gate but
### a script, which is why this target lands with the script it runs.
###   window map  het_win_of maps frames to windows and is not a constant
###   aggregate   every statistic differentially checked vs an independent Python
###               re-derivation; every class/flag/tier reachable (anti-constant)
###   emptiness   the guard that refuses the KS gate on a control stream that is
###               absent, all-zero or desynced -- the one thing standing between an
###               all-zero stream and a P_rep unlocked by a test that never ran
###   producer    the per-window sub-tallies live BOTH ways on the real emitted scan
###   corpus      all 411 carry the post-pass + a decode channel
###   stop rule   het_verdict.h's own policy, which branches on no class: a
###               corroborated sighting stops a row, a LONE one holds it open to
###               the confirmation window and then ends it UNCONFIRMED-SIGHTING,
###               HET_RATE turns the sighting stop off alone, an unstamped record
###               buys no stop at all, and a null runs to its budget
###   scheduler   campaign.py on a stub runner: one policy applied a second time
###               over pooled runs, plus the mirror that rejects a header which
###               moved the corroboration bar or renamed a stop
### --bite: cmp-verified injections into the statistics.  (B7)
hetlitmus-stats: | build
	@ echo
	python3 hetlitmus/verify/statscheck.py
	python3 hetlitmus/verify/statscheck.py --bite
	@ echo "HetLitmus B7 statistics layer: OK (and the gate bites)"

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

### hetlitmus-recfields: the EMITTER/RUNTIME SKEW tripwire.  het_obs_record and
### the HET_* knob defaults live in litmus/het-runtime/*.h, the lines that fill
### them in litmus/hetEmit.ml, and NOTHING but a compiler binds the two -- so on
### every CPU-only lane a renamed field, a dropped record stamp or a define
### stamped under a drifted name is invisible until an nvcc/hipcc build runs.
### Four properties over real emissions of both pairs (6 shapes, ~5 s, no GPU):
###   fields    every `_rec.<name>' a render writes is a het_obs_record member
###   stamp     every render writes `_rec.rec_magic = HET_REC_MAGIC;' ONCE, by the
###             SYMBOL -- het_verdict() reads no field of a record without it
###   live      every stamped `#define HET_*' is read by some lane's code or by a
###             staged runtime header (judged over the UNION: HET_WINDOW is read
###             by the windowed scan alone)
###   default   every stamped define het_verdict.h reads has an `#ifndef' default
###             there, so a lane that stamps nothing still compiles
### --bite: 6 injections, each required to redden BY NAME -- four into the
### emitted render and two into the header, since either side can drift.
hetlitmus-recfields: | build
	@ echo
	python3 hetlitmus/verify/recfields.py
	python3 hetlitmus/verify/recfields.py --bite
	@ echo "HetLitmus emitter/runtime field + define binding: OK (and the gate bites)"

### hetlitmus-x86body: the P2b gate -- is the x86-64 CPU thread of a het
### harness REAL?  Until 2026-08-03 hetCpuFront.ml wired an empty plan +
### emit_stub for X86_64, so an x86 CPU proc emitted a `(void)_n' no-op: the CPU
### thread tested nothing AND, measured over the 411 x86 renderings, litmus7
### emitted a harness for 39 and REFUSED 372 (308 could bind no read buffer, 64
### no mu) -- while EXITING 0.  Seven phases: emission coverage, body-vs-column
### fidelity, tag liveness (the B4 lesson -- emitting is not testing), the
### instructions surviving gcc to the .o, the aarch64 lane (no x86 leak, and
### its classifier refusing the four CPU columns it cannot render), the
### fail-closed refusal (exit 3 + marker + no harness, plus emit-all.sh's
### detectors -- the refusal pair and the five per-lane stamp/machine-word
### ones, which live here because this gate owns the emit-all stand-in rig),
### and the B6b co-run harnesses (T + mu(T) + canary share a proc index, so
### each body must be checked against its OWN test).  P2/P3/P7 pin their counts
### against a total derived from the corpus' own columns, so a phase that
### compared nothing FAILS instead of passing.  --bite injects into every phase
### on corruption AND on omission.
### The x86 renderings are generated on demand by tests/het/generate-x86.sh
### (411, 1:1 with the corpus); they are deliberately NOT committed
### (corpus-gate.sh pins 411 and ~90 of them would be dupcheck duplicates).
### NOT covered here: the emitter byte-diff.  What protects the validated NVIDIA
### lane against an emitter regression is `hetlitmus/verify/emit-all.sh SNAP_x'
### run at two revisions followed by `diff -r' (16,732 files, measured
### 2026-08-13), with HET_LANES_ONLY and HET_TESTS_ONLY unset -- either seam
### emits a subset, which emit-all.sh marks with a .het-partial-snapshot dotfile
### carrying a per-run nonce, so two subsets cannot diff clean against each
### other either.  That is a two-revision instrument and cannot be a single-shot
### target, so it is run by hand for every emitter change.  P5 does not stand in
### for it: what P5 owns is the aarch64 lane's refusals, which the byte-diff
### cannot see because a refused shape is by construction absent from the
### corpus.
hetlitmus-x86body: | build
	@ echo
	python3 hetlitmus/verify/x86bodycheck.py
	python3 hetlitmus/verify/x86bodycheck.py --bite
	@ echo "HetLitmus x86-64 tagged CPU body gate: OK (and the gate bites)"

### hetlitmus-x86fixture: is tests/het-x86 still what its generators emit?
### Those five committed files -- four .litmus renderings plus a one-row-per-test
### extract of control-map-amd.csv -- are the ONLY route to the populated
### (x86_64, hip) pair for cram, smoke.sh and verdictcheck, because the real x86
### corpus is generated on demand and never committed and a cram sandbox has no
### hetgen7 on $$PATH.  Nothing else compared them against generate-x86.sh /
### tests/het/control-map-amd.csv, so they could go stale in silence -- and a
### regenerated map rewrites whole columns of the extract.  A stale fixture breaks
### no gate; it makes every gate that reads it test a configuration nothing ships.
### Two verbatim comparisons (the .litmus bytes, then the map rows), each of which
### must be seen to fail.
### CUDA-FREE: generation and comparison need no GPU, so it belongs here and not
### in the toolchain umbrella.
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
### per harness dir (-gpu-target), and the MACHINE lives on the PAIR: this corpus
### has an x86_64 CPU column, so `hip' is the pair (x86_64, hip) that names the
### MI300A.  Rendering it for `cuda' is legal and reads the same control map --
### the map is named by the CPU frontend, not the dialect -- but the render then
### names no machine, which is a machinery smoke and not a D10 reading.
HETD10TARGET ?= hip

### The NEGATIVE control for the cpu_only stamp: a corpus test with a GPU proc,
### which the emitter must stamp 0.  It is emitted into a temp dir rather than
### into $(HETD10OUT), whose harness-dir count is pinned at six.  Both halves are
### knobs so that the check can be shown to bite: point them at one of the D10
### tests and the grep for `= 0' must fail.
HETD10NEGDIR ?= $(CURDIR)/hetlitmus/tests/het
HETD10NEG ?= MP-cg-sys-relaxed

### hetlitmus-d10: the CPU-ONLY POSITIVE CONTROL as a first-class campaign item
### (memo sect 7.D10, PHASE2-plan:71).  Generates the six CPU-only shapes, emits
### their harnesses and prints the campaign command for a machine that has a GPU.
### It does NOT run them: the D10 reading is about the SHARED ALLOCATION of the
### target box, so a result from any other machine is not a D10 result.
### IT IS IN THE `hetlitmus-test' UMBRELLA (generate + emit need no GPU).  It was
### not, and that is exactly why a target that had never worked once shipped
### green: the SCIENCE this target carries was gated elsewhere, but nothing
### gated the COMMAND a human is told to run.
### The renders are read, not merely counted: all six must stamp
### `_rec.cpu_only = 1' -- the flag het_verdict.h keys its D10 sentences off --
### and a corpus test with a GPU proc, emitted into a temp dir, must stamp 0, so
### the six 1s are a measurement of the emitter's classifier and not of a
### constant.  See HETD10NEGDIR for how the second half is bitten.
hetlitmus-d10: | build
	@ echo
	rm -rf $(HETD10OUT)
	hetlitmus/tests/het/generate-d10.sh $(HETD10OUT)
	@ set -e ; cd $(HETD10OUT) ; for t in *.litmus ; do \
	    $(CURDIR)/_build/install/default/bin/litmus7 \
	      -gpu-target $(HETD10TARGET) \
	      -set-libdir $(CURDIR)/litmus/libdir \
	      -o . "$$t" 2>&1 | grep -E 'pair:|REFUSED' ; done
	@ set -e ; n=$$(ls -d $(HETD10OUT)/*/ 2>/dev/null | wc -l) ; \
	  test "$$n" -eq 6 || { echo "hetlitmus-d10: emitted $$n harness dir(s), expected 6" ; exit 1 ; }
	@ set -e ; n=0 ; for d in $(HETD10OUT)/*/ ; do \
	    r=$$(ls $$d*.hip $$d*.cu 2>/dev/null | head -1) ; \
	    test -n "$$r" || { echo "hetlitmus-d10: $$d carries no render" ; exit 1 ; } ; \
	    grep -q '_rec\.cpu_only = 1;' "$$r" || { \
	      echo "hetlitmus-d10: $$r does not stamp _rec.cpu_only = 1 -- a CPU-only" ; \
	      echo "  cycle whose harness does not say so is reported as a compound-model row" ; \
	      exit 1 ; } ; \
	    n=$$((n+1)) ; done ; \
	  echo "hetlitmus-d10: $$n/6 renders stamp _rec.cpu_only = 1"
	@ set -e ; t=$$(mktemp -d) ; \
	  $(CURDIR)/_build/install/default/bin/litmus7 -gpu-target cuda \
	    -set-libdir $(CURDIR)/litmus/libdir -o "$$t" \
	    $(HETD10NEGDIR)/$(HETD10NEG).litmus >"$$t/emit.log" 2>&1 \
	    || { cat "$$t/emit.log" ; rm -rf "$$t" ; exit 1 ; } ; \
	  r="$$t/$(HETD10NEG)/$(HETD10NEG).cu" ; \
	  grep -q '_rec\.cpu_only = 0;' "$$r" \
	    || { echo "hetlitmus-d10: the het control $(HETD10NEG) does not stamp" ; \
	         echo "  _rec.cpu_only = 0 -- the flag is a constant, so the six 1s above" ; \
	         echo "  vouch for nothing" ; rm -rf "$$t" ; exit 1 ; } ; \
	  rm -rf "$$t" ; \
	  echo "hetlitmus-d10: the het control $(HETD10NEG) stamps _rec.cpu_only = 0"
	@ echo
	@ echo "D10 harnesses in $(HETD10OUT), rendered for $(HETD10TARGET).  On the TARGET box:"
	@ echo "    cd <test> && sh comp.sh $(HETD10TARGET)-link"
	@ echo "    ./<test>                            # SB and R must FIRE"
	@ echo "  then, for the campaign:"
	@ echo "    python3 hetlitmus/campaign.py --corpus $(HETD10OUT) \\"
	@ echo "        --runner 'sh hetlitmus/spotcheck/run-one.sh {dir} {test}'"
	@ echo "  (no --d10 flag: campaign.py reads cpu_only= off the HetStats line,"
	@ echo "   so the WB-probe verdict cannot be forgotten at the command line.)"

### hetlitmus-hipbuild: the P2c gate -- can an AMD harness be BUILT AND RUN?
### Until 2026-08-03 hetEmit.ml contained ZERO occurrences of hip-link/hip-bin:
### comp.sh's `hip' arm was compile-only (`hipcc -c') and the Makefile had no HIP
### link target at all, so nothing this suite emits could become an AMD
### executable.  Emitting a .hip that no target links is the same defect class as
### the .hip that, until B5, no gate compiled.  Eight phases: the build-script
### arms, `hipcc --offload-arch=gfx942 -c', the two link arms each producing an
### ELF that CARRIES the gfx942 code object (the ELF is read -- a gfx90a build
### links and exits 0 too), the uname -m refusal on an AArch64 render, the
### no-silent-stale-link rounds, the allocator's fail-closed HET_ALLOC handling,
### the compile-time refusal of the CUDA-only HET_PLACE lever (its own phase: it
### is the hipcc half of the allocator story, and the allocator's own injections
### all corrupt a resolver driven under a stub, which no compile-time refusal can
### see), and CUDA non-regression.  Every phase counts its assertions and fails
### if it made none.  --bite injects into all eight on corruption AND on omission.
### P5 EXISTS BECAUSE OF A MEASURED REGRESSION.  Both vendors link ./<test> on
### purpose (run-one.sh and campaign.py exec ./<test> and stay vendor-agnostic).
### With cuda-bin as a phony carrying a FILE prerequisite, `make cuda-bin' after
### `make hip-bin' printed "Nothing to be done for 'cuda-bin'", exited 0 and left
### the gfx942 binary in place -- a CUDA build handing back the AMD harness.
### Both link targets are unconditional .PHONY recipes now, and P5 alternates
### four builds because the trap needs the other vendor's object to exist and be
### OLDER than the binary: a two-round A-then-B check passes against a broken
### Makefile.
### NEEDS hipcc AND nvcc, hence the toolchain umbrella.
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

### hetlitmus-characterize-hw: what a het harness PRINTS, on a GPU.  The pair is
### (x86_64, cuda) -- the dev box, and what every runtime bite in this tree
### actually executes.  Every other gate on the verdict/statistics stack drives it
### from synthetic records or from emitted TEXT; this one builds a harness, RUNS
### it and reads the printout, which is the only artefact a result is read off.
### TWO ARMS, because the sentence a reader must never see swapped is chosen by
### whether a positive-control map was read: the committed x86 fixture, whose map
### names that row its OWN canary (calibration channel missing BY CONSTRUCTION),
### and the same test copied away from the map (missing by OMISSION).  The
### statistics layer once printed the first on a run that was the second.  Six
### assertions per arm (stamp, the arm's own control sentence and NOT the
### other's, OBSERVED against the pair NAME, no Grace/Hopper/NVLink/C2C/GH200
### -- this pair has no machine row -- and the observation class on k < R).
### NEEDS A DEVICE, hence the toolchain umbrella; with none visible it FAILS rather
### than skipping, because a gate that quietly stops checking is the failure mode
### this suite has already shipped twice.  Three assertions per arm need one
### sighting, so it re-seeds up to 12 times (~3 s per run) before giving up.
hetlitmus-characterize-hw: | build
	@ echo
	python3 hetlitmus/verify/runcheck.py --characterize-hw
	python3 hetlitmus/verify/runcheck.py --characterize-hw --bite
	@ echo "HetLitmus harness-printout runtime gate: OK (and the gate bites)"

### hetlitmus-run-gate: the DEVICE-SESSION WRAPPER (hetlitmus/hetlitmus-run.sh),
### driven end to end with no device.  The wrapper is the one command a hardware
### session runs, and what it decides -- which pair the corpus and the -gpu-target
### flag select, which machine that pair may name, which architecture the binaries
### are built for -- is decided on a machine nobody is watching and survives only
### in what it wrote down.
### CUDA-FREE because the wrapper's seams take stand-ins: NVCC/HIPCC point at a
### stub compiler that writes a harness printing one HetStats line, and
### HET_PROBE_SH at a stub probe.  The chain itself is real -- litmus7 emits, the
### emitted comp.sh + Makefile build, campaign.py schedules -- and the wrapper
### RECORDS that stand-ins were used, so a stubbed results dir can never be read
### as a reading of a machine.
### Eight phases: --dry-run writes nothing at all; the chain end to end on each
### dialect, plus --reuse-emitted; the refusals, each by its own reason, and the
### unregistered pair, which is NOT one -- it warns once and emits a harness that
### names no machine; campaign.py's stop rule, where a reproduced sighting ends a
### row CORROBORATED, a lone one outruns the budget to end UNCONFIRMED-SIGHTING at
### the confirmation window, --rate runs both to budget, and a row banked by
### another stop rule is not resumable; the machine-table reader, bounded to the
### table literal; every fail-closed handler,
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
### (<this host's CPU lane>, cuda) row, which on the dev box carries no machine:
### what is asserted is that the chain completes, that the results dir records
### the machine that row entitles the session to name and no other, and that it
### names the arch it resolved and no stand-in.
### A harness whose pinned read-modify-write is not system-atomic against the
### host can lose a barrier increment and stall (the probe measures it on this
### box); a stalled session is retried up to 3 times and only an all-stall is
### reported, the same rule --characterize-hw uses.
### NEEDS A DEVICE, hence the toolchain umbrella.
hetlitmus-run-hw: | build
	@ echo
	python3 hetlitmus/verify/runcheck.py --hw
	python3 hetlitmus/verify/runcheck.py --hw --bite
	@ echo "HetLitmus device-session wrapper runtime gate: OK (and the gate bites)"

### hetlitmus-l0-selftest: the DISCRIMINATING-POWER proofs of the toolchain lane.
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
hetlitmus-test:: hetlitmus-d10
hetlitmus-test:: hetlitmus-run-gate

### The second umbrella takes a target when it needs a TOOLCHAIN or a DEVICE
### this box may not have -- nvcc, hipcc, clang, an NVIDIA GPU, an AMD GPU -- and
### not when it is about GPU code: x86body and d10 read emitted GPU renders and
### belong to the CUDA-free lane.  `hetlitmus-test-nvcc' stays as its old name.
hetlitmus-test-toolchain:: | build
hetlitmus-test-toolchain:: hetlitmus-faithful
hetlitmus-test-toolchain:: hetlitmus-stress
hetlitmus-test-toolchain:: hetlitmus-cpustress
hetlitmus-test-toolchain:: hetlitmus-obs
hetlitmus-test-toolchain:: hetlitmus-hipbuild
hetlitmus-test-toolchain:: hetlitmus-characterize-hw
hetlitmus-test-toolchain:: hetlitmus-run-hw
hetlitmus-test-toolchain:: hetlitmus-l0-selftest
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
.PHONY: hetlitmus-controlmap hetlitmus-verdict hetlitmus-l0-selftest
.PHONY: hetlitmus-recfields
.PHONY: hetlitmus-x86body hetlitmus-hipbuild hetlitmus-d10
.PHONY: hetlitmus-x86fixture hetlitmus-characterize-hw hetlitmus-run-gate hetlitmus-run-hw
.PHONY: hetlitmus-amd-controlmap
.PHONY: hetlitmus-test hetlitmus-test-toolchain hetlitmus-test-nvcc
.PHONY: hetlitmus-test-all hetlitmus-promote

include Makefile.x86_64
include Makefile.aarch64
