#!/bin/bash
# Build OpenFOAM-6 + LIGGGHTS (this checkout, as a library) + CFDEMcoupling-PUBLIC with cfdemSolverIB.
# See ../CFDEM_BUILD_NOTES.md for the background of every step.
#
# Usage: build_stack.sh [stage ...]
#   stages: sources liggghts openfoam cfdem check   (default: all of them, in this order)
#
# Environment (all optional):
#   CFDEM_ROOT        directory that holds OpenFOAM-6, CFDEMcoupling-PUBLIC and this LIGGGHTS checkout
#                     (default: parent of this LIGGGHTS checkout)
#   JOBS              parallel compile jobs (default: nproc)
#   LIGGGHTS_USE_VTK  "OFF" (default) or "ON" (needs VTK headers)
#   CFDEM_WM_MPLIB    OpenFOAM WM_MPLIB (default SYSTEMOPENMPI; needs mpicc in PATH)
#
# Logs: $CFDEM_ROOT/cfdem_build_logs/<stage>.log
# Re-running a stage is safe; wmake and make only rebuild what changed.

SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)
LIGGGHTS_DIR=$(cd "$SCRIPTDIR/../.." && pwd)
export CFDEM_ROOT=${CFDEM_ROOT:-$(dirname "$LIGGGHTS_DIR")}
JOBS=${JOBS:-$(nproc)}
export WM_NCOMPPROCS=$JOBS
LOGDIR=$CFDEM_ROOT/cfdem_build_logs
mkdir -p "$LOGDIR"

OF_URL=https://github.com/OpenFOAM/OpenFOAM-6.git
OF_COMMIT=af7d7f427be78e9b9beb6aceca8fe7d5d4636876       # pinned in CFDEM's cfdTools/versionInfo.H
CFDEM_URL=https://github.com/CFDEMproject/CFDEMcoupling-PUBLIC.git
CFDEM_COMMIT=abedb0712debed5c055be5aa7262fef62fcf3a62    # 3.8.1, "release on 2025-07-03"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "=== [$(date +%H:%M:%S)] $*"; }

# Source inside the calling shell; never with set -e (the bashrc files run failing commands).
load_env() { source "$SCRIPTDIR/cfdem_env.sh" </dev/null >/dev/null 2>&1; }

stage_sources() {
    cd "$CFDEM_ROOT" || die "no $CFDEM_ROOT"
    if [ ! -d OpenFOAM-6 ]; then
        # not `git clone --depth 1`: that gives the master head 47517f2 (2019), CFDEM wants af7d7f4
        say "fetching OpenFOAM-6 at $OF_COMMIT"
        git init -q OpenFOAM-6 && git -C OpenFOAM-6 remote add origin $OF_URL \
            && git -C OpenFOAM-6 fetch -q --depth 1 origin $OF_COMMIT \
            && git -C OpenFOAM-6 checkout -q FETCH_HEAD || die "fetch OpenFOAM-6"
    fi
    [ "$(git -C OpenFOAM-6 rev-parse HEAD)" = $OF_COMMIT ] \
        || echo "WARNING: OpenFOAM-6 is not at $OF_COMMIT"
    if git -C OpenFOAM-6 apply --check "$SCRIPTDIR/openfoam6-gcc15.patch" 2>/dev/null; then
        say "applying openfoam6-gcc15.patch"
        git -C OpenFOAM-6 apply "$SCRIPTDIR/openfoam6-gcc15.patch" || die "patch"
    elif git -C OpenFOAM-6 apply --check -R "$SCRIPTDIR/openfoam6-gcc15.patch" 2>/dev/null; then
        say "openfoam6-gcc15.patch already applied"
    else
        die "openfoam6-gcc15.patch neither applies nor is applied"
    fi
    if [ ! -d CFDEMcoupling-PUBLIC ]; then
        say "cloning CFDEMcoupling-PUBLIC"
        git clone $CFDEM_URL CFDEMcoupling-PUBLIC || die "clone CFDEMcoupling-PUBLIC"
        git -C CFDEMcoupling-PUBLIC checkout -q $CFDEM_COMMIT || die "checkout $CFDEM_COMMIT"
    fi
    [ "$(git -C CFDEMcoupling-PUBLIC rev-parse HEAD)" = $CFDEM_COMMIT ] \
        || echo "WARNING: CFDEMcoupling-PUBLIC is not at $CFDEM_COMMIT"
}

stage_liggghts() {
    cd "$LIGGGHTS_DIR/src" || die "no $LIGGGHTS_DIR/src"
    local vtk=${LIGGGHTS_USE_VTK:-OFF}
    if [ ! -f MAKE/Makefile.user ]; then
        # what the first `make auto` would create, minus the header, with USE_VTK set
        say "creating MAKE/Makefile.user (USE_VTK = \"$vtk\")"
        sed -e '1,10d' -e "s/^USE_VTK = .*/USE_VTK = \"$vtk\"/" MAKE/Makefile.user_default > MAKE/Makefile.user
    fi
    grep -q "^USE_VTK = \"$vtk\"" MAKE/Makefile.user \
        || die "MAKE/Makefile.user has a different USE_VTK; edit it and run 'make clean-auto'"
    say "LIGGGHTS: make auto, makeshlib, Makefile.shlib auto (-j $JOBS)"
    make auto -j $JOBS && make makeshlib && make -f Makefile.shlib auto -j $JOBS \
        || die "LIGGGHTS build failed (if a USE_* option changed: make clean-auto)"
    ls -l lmp_auto liblmp_auto.so
}

stage_openfoam() {
    load_env
    [ -n "$WM_PROJECT_DIR" ] || die "OpenFOAM environment not loaded"
    cd "$WM_PROJECT_DIR"
    say "OpenFOAM: wmake/src"
    (cd wmake/src && make) || die "wmake/src (flex installed?)"
    say "OpenFOAM: src/Allwmake -k (scotchDecomp/ptscotchDecomp fail without ThirdParty: expected)"
    src/Allwmake -k -j $JOBS
    cd "$FOAM_UTILITIES"
    for u in mesh/generation/blockMesh parallelProcessing/decomposePar parallelProcessing/reconstructPar; do
        say "OpenFOAM: $u"
        wmake -j $JOBS $u || die "$u"
    done
    say "OpenFOAM: foamToVTK (library + application, needs its Allwmake)"
    (cd postProcessing/dataConversion/foamToVTK && ./Allwmake -j $JOBS) || die "foamToVTK"
    for l in finiteVolume meshTools triSurface lagrangian radiationModels turbulenceModels \
             incompressibleTurbulenceModels fvOptions incompressibleTransportModels \
             dynamicFvMesh dynamicMesh sampling; do
        [ -f "$FOAM_LIBBIN/lib$l.so" ] || die "missing $FOAM_LIBBIN/lib$l.so"
    done
}

stage_cfdem() {
    load_env
    [ -n "$CFDEM_SRC_DIR" ] || die "CFDEM environment not loaded"
    [ -f "$CFDEM_LIGGGHTS_SRC_DIR/liblmp_auto.so" ] || die "build LIGGGHTS first"
    # same as cfdemCompCFDEMsrc, without its log files in the git tree
    local libs="lagrangian/cfdemParticle eulerian/scalarTransportModelsCFDEM eulerian/fvOptionsCFDEM"
    for l in $libs; do (cd "$CFDEM_SRC_DIR/$l" && wmakeLnInclude .) || die "wmakeLnInclude $l"; done
    for l in $libs; do
        say "CFDEM: $l"
        (cd "$CFDEM_SRC_DIR/$l" && wmake -j $JOBS libso) || die "CFDEM $l"
    done
    say "CFDEM: cfdemSolverIB"
    (cd "$CFDEM_SOLVER_DIR/cfdemSolverIB" && wmake -j $JOBS) || die "cfdemSolverIB"
}

stage_check() {
    load_env
    local ok=1
    for f in "$CFDEM_LIGGGHTS_SRC_DIR/liblmp_auto.so" "$CFDEM_LIB_DIR/lib$CFDEM_LIB_NAME.so" \
             "$CFDEM_LIB_DIR/libscalarTransportModelsCFDEM.so" "$CFDEM_LIB_DIR/libfvOptionsCFDEM.so" \
             "$FOAM_APPBIN/blockMesh" "$FOAM_APPBIN/decomposePar" "$CFDEM_APP_DIR/cfdemSolverIB"; do
        if [ -e "$f" ]; then echo "ok       $f"; else echo "MISSING  $f"; ok=0; fi
    done
    echo "WM_OPTIONS=$WM_OPTIONS FOAM_MPI=$FOAM_MPI CFDEM_LIB_NAME=$CFDEM_LIB_NAME"
    if ldd "$CFDEM_APP_DIR/cfdemSolverIB" | grep "not found"; then ok=0; fi
    ldd "$CFDEM_APP_DIR/cfdemSolverIB" | grep -E "libstdc\+\+|libmpi\.|liblmp_auto|lagrangianCFDEM"
    [ $ok = 1 ] || die "check failed"
    say "check passed; next: $SCRIPTDIR/run_twoSpheresGlowinskiMPI.sh"
}

stages=${*:-sources liggghts openfoam cfdem check}
for s in $stages; do
    case $s in
        sources|liggghts|openfoam|cfdem|check) ;;
        *) die "unknown stage '$s'" ;;
    esac
done
for s in $stages; do
    say "stage $s (log: $LOGDIR/$s.log)"
    start=$SECONDS
    ( stage_$s ) > "$LOGDIR/$s.log" 2>&1
    rc=$?
    tail -3 "$LOGDIR/$s.log" | cut -c1-160
    [ $rc = 0 ] || die "stage $s failed, see $LOGDIR/$s.log"
    say "stage $s done in $(( (SECONDS - start) / 60 )) min $(( (SECONDS - start) % 60 )) s"
done
