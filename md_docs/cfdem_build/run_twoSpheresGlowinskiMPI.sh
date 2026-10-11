#!/bin/bash
# Run CFDEMcoupling tutorial cfdemSolverIB/twoSpheresGlowinskiMPI in a fresh copy.
# Replaces the tutorial's Allrun.sh/parCFDDEMrun.sh, which source ~/.bashrc, call octave/evince
# and finally ask (read) before deleting the case.
#
# Usage: run_twoSpheresGlowinskiMPI.sh [runDirName] [endTime]
#   shipped endTime 0.1 s covers only drafting; 0.35 shows kissing and tumbling.
# Environment: MPIRUN (default "mpirun -np 4"; e.g. "srun -n 4" in a Slurm allocation).
# The case is decomposed for exactly 4 ranks (simple 2 2 1).
SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPTDIR/cfdem_env.sh" </dev/null >/dev/null 2>&1
set -e   # only after sourcing: the OpenFOAM/CFDEM bashrc files contain failing commands
MPIRUN=${MPIRUN:-mpirun -np 4}
NAME=${1:-twoSpheresGlowinskiMPI}
END=${2:-}
RUN=$CFDEM_PROJECT_USER_DIR/run/$NAME
if [ -e "$RUN" ]; then echo "$RUN exists - pick another name"; exit 1; fi
mkdir -p "$RUN"
cp -r $CFDEM_TUT_DIR/cfdemSolverIB/twoSpheresGlowinskiMPI/. "$RUN"/
mkdir -p "$RUN/DEM/post"                      # fix print writes there; not in git
cd "$RUN/CFD"
if [ -n "$END" ]; then sed -i "s/^endTime .*/endTime         $END;/" system/controlDict; fi
blockMesh      > log.blockMesh 2>&1
decomposePar -force > log.decomposePar 2>&1
for i in 0 1 2 3; do touch processor$i/file.foam; done
set +e
{ date; time $MPIRUN cfdemSolverIB -parallel; echo "EXIT $?"; date; } > log.cfdemSolverIB 2>&1
set -e
tail -3 log.cfdemSolverIB
grep -q "^EXIT 0" log.cfdemSolverIB || { echo "cfdemSolverIB failed, see $RUN/CFD/log.cfdemSolverIB"; exit 1; }
python3 -I "$SCRIPTDIR/postproc_glowinski.py" "$RUN" > "$RUN/postproc_summary.txt"
tail -4 "$RUN/postproc_summary.txt"
echo "results: $RUN"
