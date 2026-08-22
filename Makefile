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
	dune install herdtools7 --prefix=$(PREFIX)

build-aslref:
	dune build -p aslref --profile $(DUNE_PROFILE)

install-aslref:
	dune install aslref --prefix=$(PREFIX)

install: install-herdtools

uninstall:
	dune uninstall herdtools7 --prefix=$(PREFIX)

uninstall-aslref:
	dune uninstall aslref --prefix=$(PREFIX)

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

test-all-asl:: test.herd.inst.ASL
test-all-asl:: test.herd.inst.ASL-pseudo-arch
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
cata-test:: test.herd.cata.aarch64-readers-guide

cata-test:: test.herd.cata.bpf
cata-test:: test.herd.cata.x86_64

test.herd.cata-extended.%:
	@ echo
	$(HERD_REGRESSION_TEST) \
		-j $(J) \
		$(NOHASH) \
		-herd-path $(HERD) \
		-libdir-path ./herd/libdir \
		-litmus-dir  catalogue/$*/tests \
		-conf catalogue/$*/cfgs/ci.cfg \
		$(REGRESSION_TEST_MODE)
	@ echo "herd7 catalogue extended $* tests: OK"

cata-test-all:: test.herd.cata-extended.aarch64-BBM
cata-test:: test.herd.cata-extended.linux

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

### Every emitted HIP kernel and x86_64 CPU body carries exactly the memory ops,
### orders, scopes and loop structure its .litmus annotates -- source-level, so
### no toolchain (hetlitmus/docs/amd-faithfulness.md).
hetlitmus-hipsrc: | build
	@ echo
	python3 hetlitmus/verify/hipsrccheck.py --all
	python3 hetlitmus/verify/hipsrccheck.py --bite
	@ echo "HetLitmus HIP source faithfulness (173 gpu-only + 471 x86_64 het): OK (and the gate bites)"

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

### The isomorphism gate: no two corpus tests are the same experiment up to
### (proc permutation x location renaming), which is the duplicate class the
### generators' byte-comparison cannot see (hetlitmus/verify/dupcheck.py).
hetlitmus-dup: | build
	@ echo
	python3 hetlitmus/verify/dupcheck.py
	python3 hetlitmus/verify/dupcheck.py --bite
	@ echo "HetLitmus isomorphism/dedup gate: OK (and the gate bites)"

### het_verdict() -- the rule deciding what an observation MEANS -- compiled from
### the real emitted header and driven with synthetic records, together with the
### pair each printout names (hetlitmus/verify/verdictcheck.py).
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

### The emitter/runtime skew tripwire: every field a render writes and every
### HET_* define it stamps still binds to litmus/het-runtime/*.h, which nothing
### but a compiler otherwise checks (hetlitmus/verify/recfields.py).
hetlitmus-recfields: | build
	@ echo
	python3 hetlitmus/verify/recfields.py
	python3 hetlitmus/verify/recfields.py --bite
	@ echo "HetLitmus emitter/runtime field + define binding: OK (and the gate bites)"

### hetlitmus/tests/het-x86 is still, byte for byte, what its generator emits --
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
### per harness dir: this corpus has an x86_64 CPU column, so `hip' selects the
### (x86_64, hip) pair.  `cuda' is legal too and is a machinery smoke.
HETCPUONLYTARGET ?= hip

### The negative control for the cpu_only stamp: a corpus test with a GPU proc,
### which the emitter must stamp 0.  Emitted into a temp dir, since the count of
### harness dirs in $(HETCPUONLYOUT) is pinned.  Both halves are knobs so the
### check can be shown to bite: point them at a CPU-only test and the grep fails.
HETCPUONLYNEGDIR ?= $(CURDIR)/hetlitmus/tests/het
HETCPUONLYNEG ?= MP-cg-sys-relaxed

### The CPU-only shapes as a campaign item: generate, emit, read every render for
### the `_rec.cpu_only = 1' stamp against a negative control that stamps 0, print
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
	    || { echo "hetlitmus-cpuonly: the negative control $(HETCPUONLYNEG) does not stamp" ; \
	         echo "  _rec.cpu_only = 0 -- the flag is a constant, so the six 1s above" ; \
	         echo "  vouch for nothing" ; rm -rf "$$t" ; exit 1 ; } ; \
	  rm -rf "$$t" ; \
	  echo "hetlitmus-cpuonly: the negative control $(HETCPUONLYNEG) stamps _rec.cpu_only = 0"
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
### off -- so the reading it gives is the one its own counts support, and it
### claims nothing beyond them (verify/runcheck.py --characterize-hw).  Needs a GPU.
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
### real harness -- so the chain completes and the results dir records what the
### session turned on (verify/runcheck.py --hw).  Needs a GPU.
hetlitmus-run-hw: | build
	@ echo
	python3 hetlitmus/verify/runcheck.py --hw
	python3 hetlitmus/verify/runcheck.py --hw --bite
	@ echo "HetLitmus device-session wrapper runtime gate: OK (and the gate bites)"

### The discriminating power of the toolchain lane: ptxcheck detects a weakened
### scope or order, the stress scaffolding bites a dead layer, and two
### invariance checks get their teeth here.
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
hetlitmus-test:: hetlitmus-hipsrc
hetlitmus-test:: hetlitmus-verdict
hetlitmus-test:: hetlitmus-recfields
hetlitmus-test:: hetlitmus-stats
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
	dune test hetlitmus/tests/cram --auto-promote
	@ echo "hetlitmus-promote: corpora regenerated + cram goldens promoted (NOT committed)."
	@ echo "hetlitmus-promote: review 'git diff' then commit yourself."

.PHONY: hetlitmus-cram hetlitmus-corpus hetlitmus-faithful hetlitmus-smoke
.PHONY: hetlitmus-stress hetlitmus-cpustress hetlitmus-stats
.PHONY: hetlitmus-dup hetlitmus-verdict hetlitmus-selftest
.PHONY: hetlitmus-recfields
.PHONY: hetlitmus-hipbuild hetlitmus-cpuonly
.PHONY: hetlitmus-x86fixture hetlitmus-characterize-hw hetlitmus-run-gate hetlitmus-run-hw
.PHONY: hetlitmus-hipsrc
.PHONY: hetlitmus-test hetlitmus-test-toolchain hetlitmus-test-nvcc
.PHONY: hetlitmus-test-all hetlitmus-promote

include Makefile.x86_64
include Makefile.aarch64
