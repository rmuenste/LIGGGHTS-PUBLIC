# Building LIGGGHTS-PUBLIC on this cluster

Date: 2026-10-02
Host: `longhouse1a` (RHEL 9, Linux 5.14, 128 cores, module system under `/sfw/modulefiles`)
Source: LIGGGHTS-PUBLIC 3.8.0, git commit `3d5c00f2` (master)

This document records how the code was compiled here, which problems came up,
and a short step-by-step walkthrough so the build can be reproduced.

---

## 1. Summary of the final setup

| Component | Choice | Location |
|---|---|---|
| Compiler | GCC 13.2.0 (`module load gcc/13.2.0`) | `/sfw/gcc/13.2.0-static-gmp-mpfr-mpc-isl` |
| MPI | OpenMPI 4.1.6 built for GCC 13 (`module load openmpi/4.1.6`) | `/sfw/openmpi/gcc13.2.x/4.1.6/ucx-threaded-noverbs` |
| VTK | 9.3.1, self-built, MPI on, no rendering | `/data/warehouse17/rmuenste/code/liggghts-dem/vtk/install` |
| Boost | not needed (GCC 13 provides `std::beta`) | – |
| Build system | LIGGGHTS' own `make auto` (`src/MAKE/Makefile.auto` + `Makefile.user`) | `src/` |
| Binary | `src/lmp_auto` | – |
| Env helper | `source /data/warehouse17/rmuenste/code/liggghts-dem/env.sh` | – |

Build times on this node: VTK about 6 min with `-j 64`, LIGGGHTS about 80 s with `-j 48`.

---

## 2. How the build was arrived at

### 2.1 Toolchain discovery

The default environment has GCC 11.5 (Red Hat) and CMake 3.31 but no MPI wrapper
(`mpicxx` is not on `PATH`). The module system provides several compilers and one
OpenMPI version. The OpenMPI module is "hierarchical": `module show openmpi/4.1.6`
prints nothing useful, but after loading a compiler module it resolves to the
OpenMPI build that matches that compiler (`/sfw/openmpi/gcc13.2.x/...` for GCC 13).
So the compiler module must be loaded **before** the OpenMPI module.

GCC 13 was chosen because it is recent, has a matching OpenMPI build, and its
standard library implements the C++17 special math functions. LIGGGHTS'
superquadric code needs the beta function; `Makefile.auto` tests for `std::beta`
and only falls back to Boost if that fails. With GCC 13 the test passes, so Boost
is not required.

### 2.2 Baseline build without VTK

To verify the toolchain quickly, a first build was done with `USE_VTK = "OFF"` in
`src/MAKE/Makefile.user`. It compiled without errors (warnings only, see section 3.4)
and the resulting binary ran the `packing` tutorial on 4 MPI ranks once its
`dump custom/vtk` line was changed to a plain `dump custom`.

This baseline binary is of limited use: all 22 inputs in
`examples/LIGGGHTS/Tutorials_public` use `dump custom/vtk` or `dump mesh/gran/VTK`,
which are compiled out when VTK is disabled.

### 2.3 VTK: why a self-built one

Three options were considered:

1. **ParaView-bundled VTK** (`paraview/5.13.0/...` and `paraview/6.0.1` modules).
   These ship VTK libraries named `libvtk*-pv5.13.so` and headers under
   `include/paraview-5.13`. But the ParaView modules force `gcc/11.4.1-rh9` and
   conflict with `gcc/13.2.0`, and their libraries were linked against the
   GCC 11 OpenMPI (`/sfw/openmpi/gcc11.4.x/...`). Mixing that with a GCC 13
   LIGGGHTS build would have meant two different OpenMPI installs in one process.
   Rejected.
2. **`AUTOINSTALL_VTK` in Makefile.auto.** This downloads and builds VTK 8.0.1.
   VTK 8.0 is from 2017 and is unlikely to compile cleanly with GCC 13 without
   patching. Rejected.
3. **Build a current VTK 9.3.1 ourselves** with the same GCC 13 + OpenMPI 4.1.6
   toolchain. `Makefile.auto` already handles VTK major version 9 in its library
   list (`ifneq (, $(filter $(VTK_MAJOR_VERSION),7 8 9))`), so no source patching
   was needed. Chosen.

The VTK build was kept minimal: no rendering, no Qt, no Python, no X. Only the
I/O, filter and MPI modules LIGGGHTS links against were enabled. This is why it
builds in six minutes rather than an hour.

### 2.4 Pointing LIGGGHTS at the custom VTK

`Makefile.auto` searches `/usr` and `lib/vtk/install` for VTK by default. Since the
custom VTK lives elsewhere, the three `*_USR` variables in `Makefile.user` were set
explicitly (see walkthrough). `VTK_APPENDIX_USR=9.3` tells the makefile that the
libraries are named `libvtkXxx-9.3.so`.

After `make clean-auto` and a fresh `make -j 48 auto`, the log shows
`-DLAMMPS_VTK` in the compile flags and 19 `-lvtk*-9.3` libraries at link time.
`ldd lmp_auto` resolves all VTK libraries when `LD_LIBRARY_PATH` includes the VTK
`lib64` directory.

### 2.5 Verification

Both runs were done in scratch copies so the `examples/` tree stays clean.

| Case | Ranks | Steps | Wall time | Output |
|---|---|---|---|---|
| `Tutorials_public/packing` (no-VTK binary, text dump) | 4 | 20000 | 4 s | 200 text dumps |
| `Tutorials_public/chute_wear` (VTK binary) | 8 | 100000 | 15 s | 1500 `.vtk` files (particles + stressed mesh) |

The VTK files are legacy ASCII (`# vtk DataFile Version 5.1`) and open directly
in ParaView.

---

## 3. Pitfalls and things to watch for

### 3.1 Module order
Load `gcc/13.2.0` first, then `openmpi/4.1.6`. Loading OpenMPI first (or with no
compiler module) silently gives you no `mpicxx`.

### 3.2 Do not mix the ParaView modules with this build
Loading any `paraview/*` module swaps the compiler to GCC 11 and will break the
`make auto` configuration checks. Use ParaView only in a separate shell for
post-processing.

### 3.3 Changing `USE_*` options requires `make clean-auto`
`Makefile.auto` records the option set in `Obj_auto/` and aborts with
`variable USE_VTK has changed. Please run "make clean-all" or "make clean-auto"`
if you flip an option and rebuild without cleaning.

### 3.4 Compiler warnings
GCC 13 emits a few hundred warnings. The most frequent are harmless for this code:
`-Wclass-memaccess` (memset on `ForceData` / `SurfacesIntersectData`),
`-Woverloaded-virtual` (`Fix::min_rad`/`max_rad` hidden) and
`-Wint-in-bool-context` in `general_container_I.h` for `bool` containers.
None of these are errors; do not add `-Werror`.

### 3.5 Runtime: VTK libraries are dynamic
`lmp_auto` is linked dynamically against `libvtk*-9.3.so`. If you run it from a
clean shell you get `error while loading shared libraries: libvtkCommonCore-9.3.so.1`.
Always `source env.sh` first (it sets `LD_LIBRARY_PATH`). The OpenMPI libraries
are found via an rpath baked in by `mpicxx`, so they do not have this problem.

### 3.6 VTK output disabled silently without VTK
A binary built with `USE_VTK = "OFF"` compiles fine but any input using
`dump custom/vtk` or `dump mesh/gran/VTK` errors out with an unknown dump style.
All public tutorials are affected.

### 3.7 `lmp_auto` writes `log.liggghts` into the current directory
Run cases from a scratch or case directory, not from `src/` or the repo root, or
you will litter the repo with untracked log files.

### 3.8 ParScale examples
`Tutorials_public/ParScale/*` need the external ParScale library and cannot be run
with this build.

### 3.9 Disk space
`/data/warehouse17` was 95 % full at build time. The VTK source and build trees
(`vtk/VTK-9.3.1`, `vtk/build`, about 2 GB) can be deleted after installation;
only `vtk/install` is needed at runtime.

---

## 4. Compile walkthrough (reproducible steps)

All paths assume the layout
`/data/warehouse17/rmuenste/code/liggghts-dem/{LIGGGHTS-PUBLIC,vtk,env.sh}`.

### Step 1: Environment

```bash
source /etc/profile.d/modules.sh
module load gcc/13.2.0 openmpi/4.1.6
which mpicxx          # -> /sfw/openmpi/gcc13.2.x/4.1.6/ucx-threaded-noverbs/bin/mpicxx
mpicxx --version      # -> g++ (GCC) 13.2.0
```

### Step 2: Build VTK 9.3.1 (once)

```bash
mkdir -p /data/warehouse17/rmuenste/code/liggghts-dem/vtk
cd /data/warehouse17/rmuenste/code/liggghts-dem/vtk
curl -sL -o VTK-9.3.1.tar.gz https://www.vtk.org/files/release/9.3/VTK-9.3.1.tar.gz
tar xzf VTK-9.3.1.tar.gz
mkdir build && cd build
cmake ../VTK-9.3.1 -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/data/warehouse17/rmuenste/code/liggghts-dem/vtk/install \
  -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
  -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
  -DVTK_BUILD_EXAMPLES=OFF -DVTK_BUILD_TESTING=OFF \
  -DVTK_GROUP_ENABLE_Rendering=DONT_WANT -DVTK_GROUP_ENABLE_Qt=NO \
  -DVTK_GROUP_ENABLE_Views=NO -DVTK_GROUP_ENABLE_Web=NO \
  -DVTK_GROUP_ENABLE_Imaging=DONT_WANT -DVTK_GROUP_ENABLE_StandAlone=WANT \
  -DVTK_GROUP_ENABLE_MPI=YES -DVTK_USE_MPI=ON \
  -DVTK_MODULE_ENABLE_VTK_ParallelMPI=YES \
  -DVTK_MODULE_ENABLE_VTK_IOParallelXML=YES \
  -DVTK_MODULE_ENABLE_VTK_IOMPIImage=YES \
  -DVTK_MODULE_ENABLE_VTK_IOMPIParallel=YES \
  -DVTK_MODULE_ENABLE_VTK_IOLegacy=YES -DVTK_MODULE_ENABLE_VTK_IOXML=YES \
  -DVTK_MODULE_ENABLE_VTK_IOImage=YES -DVTK_MODULE_ENABLE_VTK_FiltersCore=YES \
  -DVTK_WRAP_PYTHON=OFF -DVTK_USE_X=OFF -DVTK_OPENGL_HAS_OSMESA=OFF
make -j 64 install
```

Check: `ls install/lib64/libvtkParallelMPI-9.3.so` and `ls install/include/vtk-9.3/vtkVersion.h` exist.

### Step 3: Configure LIGGGHTS

```bash
cd /data/warehouse17/rmuenste/code/liggghts-dem/LIGGGHTS-PUBLIC/src
cp MAKE/Makefile.user_default MAKE/Makefile.user   # skip if Makefile.user already exists
```

Edit `MAKE/Makefile.user` so that these lines read:

```make
USE_MPI = "ON"
USE_VTK = "ON"
USE_SUPERQUADRICS = "ON"
USE_FPIC = "ON"
USE_DEBUG = "OFF"

VTK_INC_USR=-I/data/warehouse17/rmuenste/code/liggghts-dem/vtk/install/include/vtk-9.3
VTK_LIB_USR=-L/data/warehouse17/rmuenste/code/liggghts-dem/vtk/install/lib64
VTK_APPENDIX_USR=9.3
```

(All other options stay at their defaults: CATALYST, JPG, CONVEX, GZIP, XDR,
MFEM off; `BUILD_LIBRARIES = "NONE"`.)

### Step 4: Compile LIGGGHTS

```bash
make clean-auto        # only needed when USE_* options changed
make -j 48 auto
```

Expected result: `../lmp_auto` is produced, `size` prints its segments, and the
link line contains `-lvtkCommonCore-9.3 ... -lvtkParallelMPI-9.3`.

### Step 5: Runtime environment

`/data/warehouse17/rmuenste/code/liggghts-dem/env.sh`:

```bash
source /etc/profile.d/modules.sh
module load gcc/13.2.0 openmpi/4.1.6
export LIGGGHTS_ROOT=/data/warehouse17/rmuenste/code/liggghts-dem/LIGGGHTS-PUBLIC
export VTK_ROOT=/data/warehouse17/rmuenste/code/liggghts-dem/vtk/install
export LD_LIBRARY_PATH=$VTK_ROOT/lib64:$LD_LIBRARY_PATH
export PATH=$LIGGGHTS_ROOT/src:$PATH
alias liggghts=$LIGGGHTS_ROOT/src/lmp_auto
```

### Step 6: Smoke test

```bash
source /data/warehouse17/rmuenste/code/liggghts-dem/env.sh
echo "" | lmp_auto                 # prints the version banner
mkdir -p ~/nobackup/liggghts_runs && cd ~/nobackup/liggghts_runs
cp -r $LIGGGHTS_ROOT/examples/LIGGGHTS/Tutorials_public/chute_wear .
cd chute_wear
mpirun -np 8 lmp_auto -in in.chute_wear
ls post | head                     # chute_*.vtk and mesh_*.vtk
```

### Rebuilding after source changes

```bash
source /data/warehouse17/rmuenste/code/liggghts-dem/env.sh
cd $LIGGGHTS_ROOT/src && make -j 48 auto
```

Incremental rebuilds work; only `make clean-auto` is needed when `Makefile.user`
options change.
