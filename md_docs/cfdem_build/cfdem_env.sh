# Environment for OpenFOAM-6 + LIGGGHTS-PUBLIC + CFDEMcoupling-PUBLIC.
#
# Usage:  source <LIGGGHTS-PUBLIC>/md_docs/cfdem_build/cfdem_env.sh </dev/null
#
# Layout (CFDEM_ROOT defaults to the directory that contains this LIGGGHTS checkout):
#   $CFDEM_ROOT/OpenFOAM-6
#   $CFDEM_ROOT/CFDEMcoupling-PUBLIC
#   $CFDEM_ROOT/<this LIGGGHTS checkout>
#   $CFDEM_ROOT/cfdem-user              (run directories, created here)
#
# Overridable before sourcing: CFDEM_ROOT, WM_NCOMPPROCS, CFDEM_WM_MPLIB (default SYSTEMOPENMPI).
# Load the compiler and MPI modules first: OpenFOAM's SYSTEMOPENMPI finds MPI via `mpicc`.
# Do not `set -e` before sourcing: the OpenFOAM/CFDEM bashrc files run commands that fail.

_cfdem_liggghts=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export CFDEM_ROOT=${CFDEM_ROOT:-$(dirname "$_cfdem_liggghts")}

export WM_NCOMPPROCS=${WM_NCOMPPROCS:-$(nproc)}
# No ThirdParty-6 (no scotch/metis: the tutorials decompose with "simple")
. $CFDEM_ROOT/OpenFOAM-6/etc/bashrc WM_MPLIB=${CFDEM_WM_MPLIB:-SYSTEMOPENMPI}

export CFDEM_VERSION=PUBLIC
export CFDEM_PROJECT_DIR=$CFDEM_ROOT/CFDEMcoupling-PUBLIC
export CFDEM_PROJECT_USER_DIR=$CFDEM_ROOT/cfdem-user/${USER:-$(id -un)}-$CFDEM_VERSION-$WM_PROJECT_VERSION
export CFDEM_bashrc=$CFDEM_PROJECT_DIR/src/lagrangian/cfdemParticle/etc/bashrc
export CFDEM_LIGGGHTS_SRC_DIR=$_cfdem_liggghts/src
export CFDEM_LIGGGHTS_MAKEFILE_NAME=auto
export CFDEM_LPP_DIR=$_cfdem_liggghts/lpp
# The CFDEM bashrc asks interactively (read y/n) when this directory is missing
mkdir -p $CFDEM_PROJECT_USER_DIR/run $CFDEM_PROJECT_USER_DIR/applications/solvers \
         $CFDEM_PROJECT_USER_DIR/log/logFilesCFDEM-$CFDEM_VERSION-$WM_PROJECT_VERSION
. $CFDEM_bashrc

unset _cfdem_liggghts
