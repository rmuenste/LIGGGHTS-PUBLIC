# Building CFDEMcoupling (OpenFOAM-6 + LIGGGHTS + CFDEMcoupling) on the workstation

Date: 2026-10-11
Host: `edenprime` (Ubuntu 26.04.1 LTS, Linux 7.0.0-38-generic, 16 cores, 30 GB RAM)
Layout: everything under `/home/raphael/code/pe-new` (`$CFDEM_ROOT` in section 0; `pe-new/` below)

| Code | Version / commit | Location |
|---|---|---|
| OpenFOAM | OpenFOAM-6, shallow fetch of commit `af7d7f4` (the one CFDEM pins, see 2.10) | `pe-new/OpenFOAM-6` |
| ThirdParty | not used (no scotch, no ptscotch, no CGAL) | – |
| LIGGGHTS | LIGGGHTS-PUBLIC 3.8.0, commit `6f3d0655` (user repo) | `pe-new/LIGGGHTS-PUBLIC` |
| CFDEMcoupling | CFDEMcoupling-PUBLIC 3.8.1, commit `abedb07` ("release on 2025-07-03") | `pe-new/CFDEMcoupling-PUBLIC` |

Toolchain (all from Ubuntu packages):

| Tool | Version |
|---|---|
| GCC | 15.2.0 (Ubuntu 15.2.0-16ubuntu1) |
| MPI | OpenMPI 5.0.10 (system, `/usr/lib/x86_64-linux-gnu/openmpi`) |
| CMake | 4.2.3 (not used by any of the three builds) |
| flex / bison / m4 | 2.6.4 / 3.8.2 / 1.4.21 |
| Python | `/usr/bin/python3` with numpy 2.3.5, scipy 1.16.3 (for post-processing) |
| VTK | only the runtime `libvtk9.5`, no headers -> LIGGGHTS built with `USE_VTK = "OFF"` |
| Octave | not installed (the tutorial's `postproc.m` is replaced by a Python script) |

This document records how the stack was compiled here, which problems came up,
and a step-by-step walkthrough so the build can be reproduced.

Result: the full stack builds natively with GCC 15 after **two small patches in
OpenFOAM-6** (one compile error, one run-time error). LIGGGHTS and CFDEMcoupling
needed no source changes. The tutorial `cfdemSolverIB/twoSpheresGlowinskiMPI`
runs on 4 MPI ranks in 19 s and shows drafting, kissing and tumbling when run
longer than the shipped `endTime` (section 6).

---

## 0. Quick start (any machine, e.g. a cluster)

Everything needed is in `md_docs/cfdem_build/` of this repository:

| File | Purpose |
|---|---|
| `build_stack.sh` | clones OpenFOAM-6 and CFDEMcoupling-PUBLIC at the pinned commits, applies the patch, builds LIGGGHTS, OpenFOAM, the CFDEM libraries and `cfdemSolverIB`, checks the result |
| `cfdem_env.sh` | environment for all three codes; source it in every shell that builds or runs |
| `openfoam6-gcc15.patch` | the two OpenFOAM-6 fixes of 2.5 and 2.8 (harmless with older GCCs) |
| `run_twoSpheresGlowinskiMPI.sh` | runs the tutorial in a fresh copy under `cfdem-user/` |
| `postproc_glowinski.py` | replaces the tutorial's Octave `postproc.m` (numpy; matplotlib optional for the PNGs) |

Layout: one root directory `$CFDEM_ROOT` that holds this LIGGGHTS checkout next to
`OpenFOAM-6/` and `CFDEMcoupling-PUBLIC/` (both cloned by the script) and `cfdem-user/`
(run directories). `$CFDEM_ROOT` defaults to the parent of this checkout, so no path
has to be edited.

```bash
mkdir cfdem && cd cfdem
git clone git@github.com:rmuenste/LIGGGHTS-PUBLIC.git
# cluster: load the compiler and MPI modules first, e.g. module load gcc openmpi
JOBS=16 LIGGGHTS-PUBLIC/md_docs/cfdem_build/build_stack.sh          # ~30 min at 14 jobs
LIGGGHTS-PUBLIC/md_docs/cfdem_build/run_twoSpheresGlowinskiMPI.sh      # ~20 s, 4 ranks
LIGGGHTS-PUBLIC/md_docs/cfdem_build/run_twoSpheresGlowinskiMPI.sh glow_t035 0.35   # ~80 s, full DKT
```

- Stages can be run one by one: `build_stack.sh sources liggghts openfoam cfdem check`.
  `liggghts` and `openfoam` are independent; `cfdem` needs both. Logs go to
  `$CFDEM_ROOT/cfdem_build_logs/<stage>.log`, a summary to stdout.
- Options (environment): `JOBS`, `CFDEM_ROOT`, `LIGGGHTS_USE_VTK=ON` (only with VTK
  headers, see 5.12), `CFDEM_WM_MPLIB` (OpenFOAM `WM_MPLIB`, default `SYSTEMOPENMPI`),
  and for the run script `MPIRUN` (default `mpirun -np 4`, e.g. `MPIRUN="srun -n 4"`).
- Interactive use: `source LIGGGHTS-PUBLIC/md_docs/cfdem_build/cfdem_env.sh </dev/null`.
- Requirements: g++, make, an MPI with `mpicc` in `PATH`, flex, bison, m4, zlib headers,
  git and network access for the two clones, python3 with numpy for the post-processing.
  The OpenFOAM build needs about 1.2 GB of disk space.

### 0.1 Notes for a cluster

- **Network:** compute nodes often have no internet access. Run the `sources` stage on
  a login node; the build stages can then run in a batch job.
- **MPI:** with `WM_MPLIB=SYSTEMOPENMPI`, OpenFOAM asks `mpicc --showme:link` for
  the library path, so this works only with Open MPI. For Intel MPI or MPICH, set
  `CFDEM_WM_MPLIB=INTELMPI` (needs `MPI_ROOT`) or `SYSTEMMPI` (needs `MPI_ROOT`,
  `MPI_ARCH_FLAGS`, `MPI_ARCH_INC`, `MPI_ARCH_LIBS`, see `OpenFOAM-6/etc/config.sh/mpi`).
  LIGGGHTS (`make auto`) uses `mpicxx` from `PATH`. All three codes must use the same MPI,
  and the same modules must be loaded when running.
- **Compiler:** OpenFOAM-6 uses `gcc`/`g++` from `PATH` (`WM_COMPILER=Gcc`). GCC 7–15
  should work; the patch is only *needed* for GCC ≥ 15 (FixedList: `-Wtemplate-body`;
  OSHA1stream: libstdc++ 15). With an old system GCC and a newer module GCC, check with
  `ldd $(which cfdemSolverIB) | grep libstdc++` that the module's libstdc++ is used at
  run time (the `check` stage prints it).
- **Memory:** OpenFOAM `src/` compiles with about 1–1.5 GB per job; on a shared login
  node use a moderate `JOBS` or a batch job.
- **Rebuild after module changes:** `make clean-auto` in `LIGGGHTS-PUBLIC/src`,
  `wclean all` / removing `OpenFOAM-6/platforms` and `CFDEMcoupling-PUBLIC/platforms`,
  then run `build_stack.sh` again.
- **Ranks:** the tutorial is decomposed for exactly 4 ranks (`simple (2 2 1)` and
  LIGGGHTS `processors 2 2 1`); changing it needs both files edited consistently.
- **Verification:** compare with 6.2–6.4. The 0.1 s run ends with
  vz1 ≈ −9.76 cm/s and vz2 ≈ −8.48 cm/s at t = 0.099 s (printed by the post-processing in
  `postproc_summary.txt`); the 0.35 s run shows contact at t ≈ 0.153 s and
  particle 1 passing below particle 2 at t ≈ 0.288 s. Small differences are expected
  with a different compiler or MPI, since the tumbling starts from round-off
  (6.4).

### 0.2 Tested on the cluster (longhouse1a, 2026-10-12)

Built next to the existing LIGGGHTS checkout, `CFDEM_ROOT=/data/warehouse17/rmuenste/code/liggghts-dem`
(default), with the toolchain from `BUILD_NOTES.md`:

```bash
cd /data/warehouse17/rmuenste/code/liggghts-dem
source env.sh                       # module load gcc/13.2.0 openmpi/4.1.6, VTK in LD_LIBRARY_PATH
JOBS=32 LIGGGHTS_USE_VTK=ON LIGGGHTS-PUBLIC/md_docs/cfdem_build/build_stack.sh
LIGGGHTS-PUBLIC/md_docs/cfdem_build/run_twoSpheresGlowinskiMPI.sh
LIGGGHTS-PUBLIC/md_docs/cfdem_build/run_twoSpheresGlowinskiMPI.sh glow_t035 0.35
```

All stages passed on the first attempt in 24 min (sources 1 min, liggghts 23 s
incremental, openfoam 21 min 43 s, cfdem 55 s, check 1 s); the only compile errors
were the two expected scotch ones (2.6). Both tutorial runs reproduced the
workstation numbers of 6.3 and 6.4 to every printed digit (RUNBOOK runs 31, 32;
22 s and 77 s on 4 ranks). Differences from the workstation:

- **`nproc` returns 1** because the login environment sets `OMP_NUM_THREADS=1`
  (GNU `nproc` honours it). The script's default `JOBS=$(nproc)` would build serially;
  always pass `JOBS` explicitly here.
- **VTK on:** `MAKE/Makefile.user` already had `USE_VTK = "ON"` with the self-built
  VTK 9.3.1, so `LIGGGHTS_USE_VTK=ON` is required (otherwise the `liggghts` stage stops
  on the USE_VTK mismatch). `liblmp_auto.so` then depends on the VTK libraries; linking
  and running `cfdemSolverIB` needs `env.sh` sourced (VTK via `LD_LIBRARY_PATH`). The
  CFDEM build needed no extra flags.
- **Static libstdc++:** the `gcc/13.2.0` module ships only `libstdc++.a`, so
  `cfdemSolverIB`, every OpenFOAM library, `liblmp_auto.so` and the CFDEM libraries each
  contain their own copy of libstdc++ (`ldd` lists no `libstdc++.so`; the `check`
  stage's `libstdc++` line is therefore empty). This did not cause problems in the
  tutorial.
- GCC 13 does not need the patch in `openfoam6-gcc15.patch`; it was applied anyway and is
  harmless.

---

## 1. Summary of the final setup

| Component | Choice | Location |
|---|---|---|
| Environment | `source md_docs/cfdem_build/cfdem_env.sh </dev/null` (step 2 of section 4) | `LIGGGHTS-PUBLIC/md_docs/cfdem_build/cfdem_env.sh` |
| OpenFOAM options | `WM_MPLIB=SYSTEMOPENMPI`, `WM_NCOMPPROCS=14` -> `WM_OPTIONS=linux64GccDPInt32Opt`, `FOAM_MPI=openmpi-system`, `-std=c++11` (OF default) | `OpenFOAM-6/platforms/linux64GccDPInt32Opt` |
| OpenFOAM built | all of `src/` (except scotchDecomp/ptscotchDecomp), utilities blockMesh, decomposePar, reconstructPar, foamToVTK. No solvers. | `$FOAM_LIBBIN`, `$FOAM_APPBIN` |
| LIGGGHTS | `make auto` with `USE_VTK = "OFF"`, `USE_SUPERQUADRICS = "ON"`, `USE_FPIC = "ON"`, `-std=c++17` (auto-detected) | `LIGGGHTS-PUBLIC/src/lmp_auto`, `src/liblmp_auto.so` |
| LIGGGHTS lib/ packages | none. CFDEM's `package-liggghts-list.txt` and `library-liggghts-list.txt` contain only comments, so POEMS etc. are not needed | – |
| CFDEM libs | `liblagrangianCFDEM-PUBLIC-6.so`, `libscalarTransportModelsCFDEM.so`, `libfvOptionsCFDEM.so`, plus a symlink `liblmp_auto.so -> LIGGGHTS-PUBLIC/src/liblmp_auto.so` | `CFDEMcoupling-PUBLIC/platforms/linux64GccDPInt32Opt/lib` (`$CFDEM_LIB_DIR`) |
| CFDEM solver | `cfdemSolverIB` | `CFDEMcoupling-PUBLIC/platforms/linux64GccDPInt32Opt/bin` (`$CFDEM_APP_DIR`) |
| Scripts and patch | `build_stack.sh`, `cfdem_env.sh`, `run_twoSpheresGlowinskiMPI.sh`, `postproc_glowinski.py`, `openfoam6-gcc15.patch` | `LIGGGHTS-PUBLIC/md_docs/cfdem_build/` |
| Run directory | `$CFDEM_PROJECT_USER_DIR/run/...` | `pe-new/cfdem-user/raphael-PUBLIC-6/run/` |

Source patches (visible with `git diff` in `OpenFOAM-6`, nothing committed):

| Repo | File | Change |
|---|---|---|
| OpenFOAM-6 | `src/OpenFOAM/containers/Lists/FixedList/FixedList.C` | `a.Size` -> `a.size()` (GCC 15 compile error, 2.5) |
| OpenFOAM-6 | `src/OpenFOAM/db/IOstreams/hashes/OSHA1stream.H` | add `overflow()` to `sha1streambuf` (GCC 15 libstdc++ run-time error, 2.8) |
| LIGGGHTS-PUBLIC | – | none (only the gitignored `src/MAKE/Makefile.user`) |
| CFDEMcoupling-PUBLIC | – | none (build products are untracked: `platforms/`, `*/lnInclude/`, `*/Make/linux64GccDPInt32Opt/`) |

`ldd cfdemSolverIB` resolves `libstdc++.so.6` to `/usr/lib/x86_64-linux-gnu`
(no anaconda involvement), `libmpi.so.40` to the system OpenMPI, and
`liblmp_auto.so` through the symlink in `$CFDEM_LIB_DIR`.

---

## 2. Errors encountered and fixes

### 2.1 OpenFOAM: `flex` missing

OpenFOAM's dependency scanner `wmake/src/wmkdep.l` and three library sources
(`surfMesh/.../STLsurfaceFormatASCII.L`, `triSurface/.../readSTLASCII.L`,
`chemkinReader/chemkinLexer.L`) are flex lexers, so `(cd wmake/src && make)` is
the first thing that fails without flex. Fix: the user installed the Ubuntu
packages `flex` and `bison`. No source change.

### 2.2 LIGGGHTS: VTK auto-detection fails

`make auto` aborted with

    Could not obtain VTK_MAJOR_VERSION

The machine has only the VTK 9.5 runtime libraries, no headers (`vtkVersion.h`
is missing), so `Makefile.auto` cannot compile its version probe. Fix: set
`USE_VTK = "OFF"` in `LIGGGHTS-PUBLIC/src/MAKE/Makefile.user` (auto-generated
from `Makefile.user_default` on the first `make auto`, gitignored).
The tutorial's LIGGGHTS input uses only `dump custom` (text), so VTK is not needed.

### 2.3 LIGGGHTS: changing a `USE_*` option requires `make clean-auto`

After flipping `USE_VTK` the next `make auto` aborts with
`variable USE_VTK has changed. Please run "make clean-all" or "make clean-auto"`.
Run `make clean-auto` first (same as in `BUILD_NOTES.md` 3.3).

### 2.4 CFDEM bashrc blocks on an interactive prompt

`CFDEMcoupling-PUBLIC/src/lagrangian/cfdemParticle/etc/bashrc` checks whether
`$CFDEM_PROJECT_USER_DIR` exists and, if not, asks
`Do you want to create it now? (y/n)` with `read`. When sourced from a
non-interactive script this hangs (or silently consumes stdin). Fix: the env script
`pe-new/cfdem_env.sh` creates the directory (plus `run/`, `applications/solvers`,
`log/...`) before sourcing the CFDEM bashrc, and is itself sourced with `</dev/null`.

### 2.5 OpenFOAM: GCC 15 rejects `a.Size` in `FixedList.C` (`-Wtemplate-body`)

First pass of `src/Allwmake -k` failed in essentially every library
(191 times the same error, starting with `src/Pstream/dummy` and `src/OSspecific/POSIX`):

    src/OpenFOAM/lnInclude/FixedList.C:90:18: error: 'const class Foam::FixedList<T, Size>'
      has no member named 'Size'; did you mean 'size'? [-Wtemplate-body]

`Size` is the template parameter, not a member. OpenFOAM never instantiates
`operator<`, and older GCCs did not check that template body; GCC 15 diagnoses errors in
uninstantiated template bodies (`-Wtemplate-body`, an error by default).
Fix in `OpenFOAM-6` (both sides have the same compile-time `Size`, so `a.size()` is equivalent):

```diff
--- a/src/OpenFOAM/containers/Lists/FixedList/FixedList.C
+++ b/src/OpenFOAM/containers/Lists/FixedList/FixedList.C
@@ -87,7 +87,7 @@ bool Foam::FixedList<T, Size>::operator<(const FixedList<T, Size>& a) const
-    if (Size < a.Size)
+    if (Size < a.size())
```

### 2.6 OpenFOAM: `scotchDecomp` cannot be built (expected)

    scotchDecomp.C:36:10: fatal error: scotch.h: No such file or directory

No ThirdParty-6 and no system scotch headers. Not needed: the tutorial uses
`method simple` in `decomposeParDict`. `decomposePar` still links because
`src/dummyThirdParty` builds stub `libscotchDecomp.so` / `libmetisDecomp.so`
into `$FOAM_LIBBIN/dummy`, and `decomposePar/Make/options` links
`-L$(FOAM_LIBBIN)/dummy -lmetisDecomp -lscotchDecomp`. The error in the log is
harmless; `src/Allwmake -k` continues past it. (Ignore the line
`using SCOTCH_ARCH_PATH=.../ThirdParty-6/...` – `etc/config.sh/scotch` always sets
that path, whether it exists or not.)

### 2.7 OpenFOAM: `foamToVTK` fails to link with plain `wmake`

    /usr/bin/x86_64-linux-gnu-ld.bfd: cannot find -lfoamToVTK: No such file or directory

`applications/utilities/postProcessing/dataConversion/foamToVTK` contains a
library sub-directory `foamToVTK/` that must be built first. Use its `Allwmake`
(`./Allwmake -j 4`), not `wmake`. No source change.

### 2.8 OpenFOAM: run-time `FOAM FATAL IO ERROR` in `OSHA1stream` (GCC 15 libstdc++)

Everything compiled and linked, but `cfdemSolverIB` died right after
`Starting time loop` on all ranks:

    --> FOAM FATAL IO ERROR:
    error in IOstream "OSHA1stream.sinkFile_" for operation Ostream& operator<<(Ostream&, const word&)
    file: OSHA1stream.sinkFile_ at line 0.
        From function virtual bool Foam::IOstream::check(const char*) const
        in file db/IOstreams/IOstreams/IOstream.C at line 96.

`OSHA1stream` (used to compute SHA1 digests of dictionaries, e.g. for the
`functions` sub-dictionary of `controlDict`) wraps a `std::streambuf` subclass
`sha1streambuf` that overrides only `xsputn()`. In GCC 15's libstdc++
(`/usr/include/c++/15/bits/ostream.h`), `operator<<(ostream&, char)` now calls
`__out.put(__c)` when `width() == 0`, i.e. `sputc()` -> `overflow()`, instead of
`__ostream_insert(__out, &__c, 1)` (-> `xsputn()`) as older versions did. The
default `streambuf::overflow()` returns EOF, which sets `badbit`, and OpenFOAM's
next `check()` aborts. A 10-line test program confirms it: with GCC 15 a
streambuf with only `xsputn()` fails on `os << 'c'` but not on `os << "abc"`.

Fix in `OpenFOAM-6/src/OpenFOAM/db/IOstreams/hashes/OSHA1stream.H`: add an
`overflow()` override to `sha1streambuf`:

```diff
@@ class sha1streambuf
         virtual std::streamsize xsputn(const char* str, std::streamsize n)
         {
             sha1_.append(str, n);
             return n;
         }
+
+        //- Process a single character
+        //  (newer libstdc++ writes single chars via sputc() -> overflow()
+        //  instead of xsputn(); the default overflow() returns EOF and sets
+        //  badbit on the stream)
+        virtual int overflow(int c = EOF)
+        {
+            if (c != EOF)
+            {
+                const char ch = static_cast<char>(c);
+                sha1_.append(&ch, 1);
+                return c;
+            }
+            return 0;
+        }
```

This is a header used by many translation units, so `src/Allwmake` has to be
re-run afterwards (wmake's dependency tracking rebuilds only the dependents).
This is the only other custom `std::streambuf` in OpenFOAM-6 besides
`gzstream`, which already implements `overflow()`.

This error is the dangerous kind: it does not show up at compile time, and the
utilities (`blockMesh`, `decomposePar`) run fine. Only an application that
hashes a dictionary hits it.

### 2.9 LIGGGHTS and CFDEMcoupling: no GCC 15 errors

LIGGGHTS compiled without errors (`Makefile.auto` detects and uses `-std=c++17`).
The CFDEM libraries and `cfdemSolverIB` are compiled through wmake with
OpenFOAM's `-std=c++11` and include LIGGGHTS headers (`library_cfd_coupling.h`
etc.); that also compiled and linked without errors. The CFDEM build picks up
`-DSUPERQUADRIC_ACTIVE_FLAG -DNONSPHERICAL_ACTIVE_FLAG` from LIGGGHTS'
`Makefile.user` (`etc/addLibs_universal/additionalLibs_superquadric`), so the
two builds agree on the superquadric data layout. If `USE_SUPERQUADRICS` is
changed in LIGGGHTS, rebuild the CFDEM libraries as well.

### 2.10 `git clone --depth 1` of OpenFOAM-6 gives the wrong commit

CFDEM 3.8.1 is pinned to OpenFOAM-6 commit `af7d7f4` (2018-09-14,
`cfdTools/versionInfo.H`: `OFversion="6-commit-af7d7f4..."`), but the OpenFOAM-6 master
head is `47517f2` (2019-07-08). The workstation tree was fetched at `af7d7f4`
explicitly; a first test of `build_stack.sh` with a plain shallow clone got `47517f2`.
Fetch the commit itself (section 4, step 1); `build_stack.sh` does that and warns if an
existing `OpenFOAM-6` is at another commit. The build with `47517f2` was not tried.

---

## 3. Wall times

| Stage | Command | Wall time |
|---|---|---|
| LIGGGHTS `make auto -j8` + `makeshlib` + `Makefile.shlib auto` | see walkthrough | about 2 min (10:04:42 -> 10:06:36, ran concurrently with the OF build) |
| OpenFOAM-6 `src/Allwmake -k -j 14` (after the FixedList fix) | `src/Allwmake -k -j 14` | 25 min 43 s real (180 min user) |
| OF utilities blockMesh, decomposePar, reconstructPar | `wmake -j 6 <dir>` each | 1 min 48 s total |
| OF foamToVTK (lib + app) | `./Allwmake -j 4` | 7 s (most objects already compiled by the failed `wmake`) |
| CFDEM src libs (lagrangianCFDEM, scalarTransportModelsCFDEM, fvOptionsCFDEM) | step 5 of section 4, `-j 8` | 1 min 9 s |
| cfdemSolverIB | `wmake -j 8` | 13 s |
| OF `src/Allwmake -k -j 14` again after the OSHA1stream.H fix | `src/Allwmake -k -j 14` | 42 s (only `dictionary.C` and `dynamicCodeContext.C` recompiled) |
| Tutorial, shipped `endTime 0.1` (333 CFD steps) | `mpirun -np 4 cfdemSolverIB -parallel` | 19 s |
| Tutorial, `endTime 0.35` (1167 CFD steps) | same | 1 min 16 s |

Reproduction test of `md_docs/cfdem_build/` (2026-10-11, same machine, fresh directory,
empty environment `env -i HOME=$HOME USER=$USER PATH=/usr/local/bin:/usr/bin:/bin`,
`JOBS=14`): `build_stack.sh` passed all stages in 31 min (sources 10 s, liggghts 2 min 16 s,
openfoam 27 min 16 s, cfdem 1 min 15 s); the only compile errors were the two expected
scotch ones (2.6). `run_twoSpheresGlowinskiMPI.sh` then ran in 19.2 s, and the particle
trajectories and velocities were bitwise identical to the original run.

Total from a clean tree, if nothing has to be debugged: about 30 min, dominated
by OpenFOAM `src/` (26 min at `-j 14`). LIGGGHTS and OpenFOAM can be built at the
same time (they are independent); CFDEM needs both.

Build logs (in `pe-new/`): `cfdem_build_liggghts.log`, `cfdem_build_of_src.pass1.log`
(the failed first pass, FixedList error), `cfdem_build_of_src.log`,
`cfdem_build_of_src_pass3.log`, `cfdem_build_of_utils.log`,
`cfdem_build_cfdem_src.log`, `cfdem_build_cfdem_sol.log`. `build_stack.sh` writes
one log per stage to `$CFDEM_ROOT/cfdem_build_logs/`.


---

## 4. Walkthrough by hand (what `build_stack.sh` does)

`$CFDEM_ROOT` is the directory that contains the LIGGGHTS checkout; `$B` is
`$CFDEM_ROOT/LIGGGHTS-PUBLIC/md_docs/cfdem_build`. Required packages on Ubuntu:
`g++`, `make`, `libopenmpi-dev` + `openmpi-bin`, `flex`, `bison`, `m4`, `zlib1g-dev`
(on the workstation only flex/bison were missing).

### Step 1: Sources

```bash
cd $CFDEM_ROOT
# OpenFOAM-6 at the commit CFDEM pins (cfdTools/versionInfo.H). Not `git clone --depth 1`:
# that gives the master head 47517f2 (2019).
git init OpenFOAM-6 && cd OpenFOAM-6
git remote add origin https://github.com/OpenFOAM/OpenFOAM-6.git
git fetch --depth 1 origin af7d7f427be78e9b9beb6aceca8fe7d5d4636876 && git checkout FETCH_HEAD
git apply $B/openfoam6-gcc15.patch          # 2.5 and 2.8
cd $CFDEM_ROOT
git clone https://github.com/CFDEMproject/CFDEMcoupling-PUBLIC.git
git -C CFDEMcoupling-PUBLIC checkout abedb0712debed5c055be5aa7262fef62fcf3a62
```

No ThirdParty-6.

### Step 2: Environment

`$B/cfdem_env.sh` sources `OpenFOAM-6/etc/bashrc WM_MPLIB=SYSTEMOPENMPI`, sets the
`CFDEM_*` variables (project dir, user dir `$CFDEM_ROOT/cfdem-user/$USER-PUBLIC-6`,
`CFDEM_LIGGGHTS_SRC_DIR` = this checkout's `src`, makefile name `auto`), creates the
user directory (2.4) and sources the CFDEM bashrc. Source it in every shell:

```bash
source $B/cfdem_env.sh </dev/null
echo $WM_OPTIONS $FOAM_MPI $CFDEM_LIB_NAME
# -> linux64GccDPInt32Opt openmpi-system lagrangianCFDEM-PUBLIC-6
```

### Step 3: LIGGGHTS (independent of step 4)

```bash
cd $CFDEM_ROOT/LIGGGHTS-PUBLIC/src
# Makefile.user = Makefile.user_default without its 10-line header, USE_VTK "OFF" (2.2);
# keep USE_SUPERQUADRICS and USE_FPIC "ON"
sed -e '1,10d' -e 's/^USE_VTK = .*/USE_VTK = "OFF"/' MAKE/Makefile.user_default > MAKE/Makefile.user
make auto -j 8 && make makeshlib && make -f Makefile.shlib auto -j 8
ls -l lmp_auto liblmp_auto.so
```

This is what CFDEM's `cfdemCompLIG` (`etc/compileLIGGGHTS.sh`) does, minus its
`make clean-auto` and its `compileLIGGGHTS_lib.sh` step, which builds nothing
here because the package lists are empty.

### Step 4: OpenFOAM-6 libraries and the four utilities

```bash
source $B/cfdem_env.sh </dev/null
cd $WM_PROJECT_DIR
(cd wmake/src && make)
src/Allwmake -k -j 14          # ~26 min; only scotchDecomp/ptscotchDecomp fail (expected, 2.6)
cd $FOAM_UTILITIES
wmake -j 6 mesh/generation/blockMesh
wmake -j 6 parallelProcessing/decomposePar
wmake -j 6 parallelProcessing/reconstructPar
(cd postProcessing/dataConversion/foamToVTK && ./Allwmake -j 4)     # 2.7
```

Check the libraries CFDEM links: `finiteVolume meshTools triSurface lagrangian
radiationModels turbulenceModels incompressibleTurbulenceModels fvOptions
incompressibleTransportModels dynamicFvMesh dynamicMesh sampling` must all be
in `$FOAM_LIBBIN` (`sampling` is needed at run time by the tutorial's `probes`
function object).

### Step 5: CFDEMcoupling libraries and solver

The same as `cfdemCompCFDEMsrc` (`etc/compileCFDEMcoupling_src.sh`), without its
log files in the git tree: `wmakeLnInclude .` in each library listed in
`etc/library-list.txt`, then `wmake libso` in each. `cfdemParticle/Make/options`
symlinks `liblmp_auto.so` into `$CFDEM_LIB_DIR`.

```bash
source $B/cfdem_env.sh </dev/null
libs="lagrangian/cfdemParticle eulerian/scalarTransportModelsCFDEM eulerian/fvOptionsCFDEM"
for l in $libs; do (cd $CFDEM_SRC_DIR/$l && wmakeLnInclude .); done
for l in $libs; do (cd $CFDEM_SRC_DIR/$l && wmake -j 8 libso); done                # ~1 min
cd $CFDEM_SOLVER_DIR/cfdemSolverIB && wmake -j 8                                    # ~13 s
which cfdemSolverIB
```

Other solvers in `etc/solver-list.txt` (cfdemSolverPiso, ...PisoScalar, ...PisoSTM)
were not built; they would be built the same way.

### Step 6: Run the tutorial

```bash
$B/run_twoSpheresGlowinskiMPI.sh                                  # shipped endTime 0.1 s
$B/run_twoSpheresGlowinskiMPI.sh twoSpheresGlowinskiMPI_t035 0.35  # kissing and tumbling
```

The script copies the tutorial to `$CFDEM_PROJECT_USER_DIR/run/<name>`, creates
`DEM/post`, runs `blockMesh`, `decomposePar -force`,
`mpirun -np 4 cfdemSolverIB -parallel` (`$MPIRUN`), and `postproc_glowinski.py` (writes
`postproc_summary.txt` and, with matplotlib, the two PNG plots in `CFD/octave/`).

---

## 5. Pitfalls

### 5.1 Compile-clean is not run-clean
The OSHA1stream problem (2.8) appears only when an application hashes a
dictionary. After any toolchain change, run a real case, not only `blockMesh`.

### 5.2 Do not run the tutorial's own `Allrun.sh` / `parCFDDEMrun.sh` as is
`parCFDDEMrun.sh` starts with `. ~/.bashrc` (which does not set up CFDEM here),
then calls `octave` and `evince` (not installed), copies the log to
`$CFDEM_TEST_HARNESS_PATH`, and finally calls `cleanCFDEMcase`, which waits on
`read` and then **deletes the results** (`cleanCase`, `DEM/post/*`).
It also runs inside the CFDEM git tree. Use the run script from step 6.

### 5.3 `DEM/post` must exist
The LIGGGHTS input writes `../DEM/post/position_particle_*.txt` etc. with
`fix print ... file`. The directory is not in git; create it before the run.

### 5.4 OpenMPI 5 quirks
- Many commands (`mpirun --version`, `ompi_info`, `MPI_ABORT`) print
  `Sorry! You were supposed to get help about: ... couldn't open the help file
  .../pmix2/share/pmix/help-*.txt`. Harmless, the Ubuntu package lacks the help files.
- Because of this, CFDEM's `get_mpirun_cmd` (`functions.sh`) does not detect
  OpenMPI (`mpirun -version | grep "Open MPI"` matches nothing) and omits
  `-oversubscribe`. With 4 ranks on 16 cores it is not needed; add
  `--oversubscribe` by hand for more ranks than cores.

### 5.5 Sourcing the environment
`cfdem_env.sh` must be sourced, not run in a pipe (`source cfdem_env.sh | tail`
runs in a subshell and loses all variables), and with `</dev/null`. Do not
`set -e` before sourcing it: the OpenFOAM/CFDEM bashrc files contain commands
that return non-zero, and the shell exits silently.

### 5.6 `reconstructPar` does not work on this case
The case uses `dynamicRefineFvMesh`, so the processor meshes change with time
and there is no `pointProcAddressing` for the later times:
`cannot find file ".../processor0/0.0099/polyMesh/pointProcAddressing"`.
This is expected (CFDEM's `parCFDDEMrun` does not reconstruct either). Visualise
the decomposed case (`processor*/file.foam` in ParaView) or use
`mpirun -np 4 foamToVTK -parallel`.

### 5.7 `foamToVTK -parallel` aborts on CFDEM's lagrangian cloud
`foamToVTK` writes the mesh and fields of each processor, then aborts with
`wrong token type - expected Scalar, found on line 5 the punctuation token ')'`
in `processor*/<time>/lagrangian/particleCloud/positions`: CFDEM writes the
positions in the pre-OpenFOAM-5 `(x y z) celli` format, OpenFOAM-6 expects
barycentric coordinates. OF-6 `foamToVTK` has no `-noLagrangian` option. The
`processor*/VTK/processor*_<index>.vtk` files written before the abort are fine.
The particle data is in `DEM/post/dump.liggghts_run` (text) anyway.

### 5.8 `ls` is aliased to `eza` in the user's shell
In non-interactive tool shells `ls` (-> `eza --icons`) can hang. Use `/bin/ls`
in scripts.

### 5.9 Killing builds
`pkill -f <pattern>` also matches the shell that runs the `pkill` when the
pattern appears in its own command line; it killed the calling shell twice.
Use `pgrep -af '[O]penFOAM-6'` style patterns or kill by PID.

### 5.10 Warnings
OpenFOAM-6 `src/` with GCC 15 produces about 58 000 warnings: 42 000
`-Wdeprecated-copy` (e.g. `DLListBase::const_iterator` has a user-provided
`operator=`), 9 500 `-Woverloaded-virtual`, 6 100 `-Wtemplate-id-cdtor`.
The CFDEM libraries show the same three kinds (about 4 200). None are errors.
Do not add `-Werror`.

### 5.11 Anaconda
`~/anaconda3` was not involved: all binaries resolve `libstdc++.so.6` to
`/usr/lib/x86_64-linux-gnu`. If a `GLIBCXX_3.4.xx not found` error ever appears,
check `ldd` and put `/usr/lib/x86_64-linux-gnu` first in `LD_LIBRARY_PATH`.

### 5.12 No VTK output from LIGGGHTS
With `USE_VTK = "OFF"`, `dump custom/vtk` and `dump mesh/gran/VTK` are compiled
out. This tutorial does not use them; other CFDEM tutorials do (grep
`DEM/in.*` for `vtk`). Enabling VTK needs VTK headers (a `libvtk9-dev` package or
a self-built VTK as in `BUILD_NOTES.md`).

---

## 6. Tutorial run: cfdemSolverIB/twoSpheresGlowinskiMPI

### 6.1 Case

Two spheres (d = 0.167 cm, density 1.5 g/cm^3, cgs units, g = 981 cm/s^2)
released at rest one above the other on the axis of a 1 x 1 x 4 cm box
(z = 3.5 and 3.16 cm, centre distance 2.03 d), fluid nu = 0.01 cm^2/s.
Mesh 10 x 10 x 40 (4000 cells), `dynamicRefineFvMesh` with up to 2 refinement
levels around the particles (4000 -> 7332 cells). CFD dt = 3e-4 s,
DEM dt = 3e-5 s, coupling every 10 DEM steps, `twoWayMPI`, `engineIB` locate
model, `IB` void fraction, forces `ShirgaonkarIB` + `ArchimedesIB`.
Decomposition `simple (2 2 1)` for OpenFOAM and `processors 2 2 1` for LIGGGHTS.

### 6.2 Commands and wall times

```bash
source $B/cfdem_env.sh </dev/null
cd $CFDEM_PROJECT_USER_DIR/run/twoSpheresGlowinskiMPI/CFD
blockMesh; decomposePar -force; for i in 0 1 2 3; do touch processor$i/file.foam; done
mpirun -np 4 cfdemSolverIB -parallel > log.cfdemSolverIB 2>&1
```

| Run | endTime | CFD steps | Wall time | Directory (under `cfdem-user/raphael-PUBLIC-6/run/`) |
|---|---|---|---|---|
| shipped tutorial | 0.1 s | 333 | 19.2 s | `twoSpheresGlowinskiMPI` |
| repeat via run script | 0.1 s | 333 | 18.8 s | `twoSpheresGlowinskiMPI_scripttest` (trajectory identical to 4 decimals) |
| extended | 0.35 s | 1167 | 75.6 s | `twoSpheresGlowinskiMPI_t035` |

About 55-65 ms per CFD time step on 4 ranks. The full-length run is cheap, so
no short test segment was needed.

### 6.3 Results, shipped endTime 0.1 s

Only the drafting phase is covered. Particle 1 (upper, "following") falls
faster than particle 2 (leading) from t ~ 0.04 s on; their centre distance
shrinks from 2.03 d to 1.88 d at t = 0.1 s. Velocities at t = 0.099 s:
vz1 = -9.76 cm/s, vz2 = -8.48 cm/s. Both stay on the axis (x = y = 0.500).

### 6.4 Results, extended run to 0.35 s

| Phase | Simulation | Reference (CFD/octave/*.mat) |
|---|---|---|
| Drafting: following particle accelerates in the wake of the leading one | 0.04 – 0.153 s, peak vz1 = -13.4 cm/s at 0.153 s | peak about -18 cm/s at about 0.155 s |
| Kissing: contact, both move together | from t = 0.153 s (centre distance 1.00 d), velocities jump to about -12 cm/s for both | velocity jump at t = 0.158 s, both about -15.5 cm/s |
| Tumbling: pair rotates, leading particle slows down, the following one passes it | lateral offset grows from 0.03 d (0.15 s) to 0.68 d (0.25 s) and 1.2 d (0.30 s); contact lost at about 0.273 s; particle 1 passes below particle 2 at t = 0.288 s | leading particle decelerates from 0.20 s; both at the same height at t = 0.25 s |

Selected samples (z in cm, distances in units of d):

| t (s) | z1 | z2 | centre distance | lateral offset |
|---|---|---|---|---|
| 0.099 | 2.874 | 2.561 | 1.877 | 0.006 |
| 0.150 | 2.285 | 2.106 | 1.068 | 0.028 |
| 0.201 | 1.660 | 1.496 | 1.000 | 0.169 |
| 0.249 | 1.056 | 0.934 | 1.000 | 0.684 |
| 0.300 | 0.506 | 0.551 | 1.229 | 1.199 |
| 0.345 | 0.099 | 0.238 | 1.770 | 1.562 |

At t = 0.345 s particle 1 is at z = 0.099 cm, i.e. touching the bottom wall
(radius 0.0835 cm); the run should not be extended much further.

The initial phase (t < 0.05 s) agrees closely with the reference velocities.
Afterwards the simulated settling velocities are 20-30 % lower than the
reference, and tumbling happens about 0.03 s later. The setups differ, so only
qualitative agreement is expected: the reference curves start with a centre
distance of 0.49 cm (vs 0.34 cm here), and the Octave script applies a single
offset (`5 - z1(0)`) to both simulated curves, so the leading particle starts
at 4.66 cm in the plot vs 4.50 cm in the reference. The mesh is also coarse
(d/dx = 1.7 on the base mesh, 6.7 after two refinement levels).
The symmetry breaking that starts the tumbling is numerical here: the
particles start exactly on the axis and drift together towards
(x, y) = (0.6-0.8, 0.6-0.8).

Output files: `DEM/post/position_particle_{1,2}.txt`,
`DEM/post/velocity_particle_{1,2}.txt` (columns t, x, y, z or t, vx, vy, vz,
every 100 DEM steps), `DEM/post/dump.liggghts_run`, `postproc_summary.txt`,
`CFD/octave/pos_z_two_part_rec_glow.png`, `CFD/octave/vel_z_two_part_rec_glow.png`.

### 6.5 Not tested / still missing on this machine

- Octave (tutorial's `postproc.m`), evince, ParaView: not installed; the Python
  script replaces `postproc.m`.
- VTK development headers: LIGGGHTS VTK dumps disabled (5.12).
- scotch/ptscotch, metis: not available; only `simple`/`hierarchical`/`manual`
  decomposition works.
- OpenFOAM solvers, other CFDEM solvers and utilities: not built.
