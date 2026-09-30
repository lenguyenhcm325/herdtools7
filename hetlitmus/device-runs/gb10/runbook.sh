# The GB10 run: stress tuning on tuning-set.txt, then the campaign on the device-run subset.
# The commands to run by hand, section by section; this is not a script to execute.

# == 0. session ================================================================
command -v tmux || { $(command -v sudo) apt-get update && $(command -v sudo) apt-get install -y tmux; }
[ -n "$TMUX" ] || tmux new -A -s gb10          # a login already inside tmux stays there


# == 1. toolchain, repo, corpus ================================================
command -v nvcc || export PATH=/usr/local/cuda/bin:$PATH
nvcc --version | grep release                  # must be 12.x
nvcc --list-gpu-arch | grep -x compute_121     # the GB10's arch must be listed

$(command -v sudo) apt-get update && $(command -v sudo) apt-get install -y --no-install-recommends \
  build-essential clang git python3 ca-certificates \
  ocaml ocaml-findlib ocaml-dune menhir libmenhir-ocaml-dev \
  libzarith-ocaml-dev liblogs-ocaml-dev

git clone -b hetlitmus-work https://github.com/lenguyenhcm325/herdtools7.git ~/herdtools7
cd ~/herdtools7
git log -1 --format='%h %s'                    # the tip under test; build.txt records it too

make all -j$(nproc)
make hetlitmus-corpus-gen

HET_CORPUS=_build/default/hetlitmus/tests/het

export RESULTS=$PWD/hetlitmus/run-out/$(date +%Y%m%d)-gb10; echo $RESULTS
mkdir -p $RESULTS

cp _build/default/hetlitmus/tests/het-subset.txt $RESULTS/eval-set.txt
cp hetlitmus/device-runs/gb10/tuning-set.txt $RESULTS/

for t in $(cat $RESULTS/tuning-set.txt); do [ -f $HET_CORPUS/$t.litmus ] || echo "MISSING $t"; done


# == 2. probe ==================================================================
sh hetlitmus/probe-cuda.sh
ARCH=$(sed -n 's/^suggested_cuda_arch=//p' $RESULTS/probe.txt); echo $ARCH   # expect sm_121
grep -x 'pageableMemoryAccess=1' $RESULTS/probe.txt   # then HET_ALLOC unset (auto) means malloc


# == 3. emit: separate dirs, since the tuner rebuilds its own every configuration
hetlitmus/emit-het.sh --gpu-target cuda $HET_CORPUS --tests $RESULTS/tuning-set.txt -o $RESULTS/tune-emit
hetlitmus/emit-het.sh --gpu-target cuda $HET_CORPUS --tests $RESULTS/eval-set.txt -o $RESULTS/emit


# == 4. tune ===================================================================
TUNE_CONFIGS=50                                # scored configurations the search draws
python3 hetlitmus/tune_stress.py search --emit-dir $RESULTS/tune-emit \
    --tests $RESULTS/tuning-set.txt --out $RESULTS/tune --arch $ARCH --target gb10 --configs $TUNE_CONFIGS

#   if interrupted: the same command plus --resume
python3 hetlitmus/tune_stress.py rank --out $RESULTS/tune | tee $RESULTS/tune/rank.txt
grep -E 'no configuration revealed|never scored' $RESULTS/tune/rank.txt
#   a test listed above: replace it, re-emit tune-emit, re-tune into a fresh --out


# == 5. campaign ==============================================================
# First pass, on the whole subset: N is the winning config.
# Replace the placeholder in the commands.
FLAGS=$(grep -v '^#' $RESULTS/tune/winner-N.params | tr '\n' ' '); echo $FLAGS   # must list -D flags
NVCC="nvcc $FLAGS" hetlitmus/build.sh $RESULTS/emit --tests $RESULTS/eval-set.txt --arch $ARCH
cp $RESULTS/build.txt $RESULTS/build-cfgN.txt   # the next build overwrites build.txt

python3 hetlitmus/campaign.py --corpus $RESULTS/emit --tests $RESULTS/eval-set.txt \
  --budget-runs 10 --state $RESULTS/campaign-cfgN.csv

awk -F, 'NR > 1 && $8 == 0 { print $1 }' $RESULTS/campaign-cfgN.csv > $RESULTS/dark-cfgN.txt

# Next passes: each other winner M, only on the tests the previous pass left dark
# (dark-cfg*.txt: no clean sighting, k_eff = 0).
wc -l < $RESULTS/dark-cfgN.txt   # 0: stop here; an empty --tests runs the whole subset

FLAGS=$(grep -v '^#' $RESULTS/tune/winner-M.params | tr '\n' ' '); echo $FLAGS   # must list -D flags
NVCC="nvcc $FLAGS" hetlitmus/build.sh $RESULTS/emit --tests $RESULTS/dark-cfgN.txt --arch $ARCH
cp $RESULTS/build.txt $RESULTS/build-cfgM.txt   # the next build overwrites build.txt

python3 hetlitmus/campaign.py --corpus $RESULTS/emit --tests $RESULTS/dark-cfgN.txt \
  --budget-runs 10 --state $RESULTS/campaign-cfgM.csv

awk -F, 'NR > 1 && $8 == 0 { print $1 }' $RESULTS/campaign-cfgM.csv > $RESULTS/dark-cfgM.txt

# == 6. [dev box] fetch the results, without the harness dirs ===================
ssh -p PORT root@IP 'cd herdtools7/hetlitmus/run-out && tar -czf - --exclude=emit --exclude=tune-emit *-gb10' \
  | tar -C DEST -xzf -
