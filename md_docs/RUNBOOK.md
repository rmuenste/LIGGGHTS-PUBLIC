# RUNBOOK: LIGGGHTS and pe runs on this cluster

Living log of simulation runs, how they were launched, what came out, and what was
learned. Add one entry per run. Keep the quirks section (6) up to date; it is the part
that saves the most time.

Related documents:
- `BUILD_NOTES.md`: how LIGGGHTS and VTK were compiled here.
- `PE_CONVEYOR.md`: detailed write-up of the LIGGGHTS-to-pe port of the conveyor case.

Layout on disk (all under `/data/warehouse17/rmuenste/code/liggghts-dem/`):

| Path | Content |
|---|---|
| `LIGGGHTS-PUBLIC/` | LIGGGHTS source, binary `src/lmp_auto`, this `md_docs/` |
| `pe-0.3rc1/` | pe fork, build tree `build/conveyor/`, example `examples/conveyor/` |
| `vtk/install/` | VTK 9.3.1 used by LIGGGHTS (lib64, include/vtk-9.3) |
| `runs/<case>/` | one directory per run, never inside the source trees |
| `env.sh` | `source` it before any LIGGGHTS build or run |

Conventions:
- Run from a copy of the case in `runs/`, never from `examples/` (both codes write logs
  and output into the working directory).
- LIGGGHTS: `source env.sh`, then `mpirun -np N lmp_auto -in in.<case>`.
- pe: `module load gcc/13.2.0 boost/1.88`, then run the example binary from the run
  directory. It writes `./paraview/`.

---

## 1. Run log

### Run 1: LIGGGHTS `packing` (no-VTK smoke test)

| | |
|---|---|
| Date | 2026-10-02 |
| Binary | `lmp_auto` built with `USE_VTK="OFF"` (baseline toolchain check) |
| Input | `Tutorials_public/packing/in.packing`, `dump custom/vtk` replaced by `dump custom` |
| Launch | `mpirun -np 4 lmp_auto -in in.packing` |
| Size | 338 particles, 20000 steps |
| Wall time | 4 s |
| Output | 200 text dumps |
| Location | scratch only, not kept |
| Outcome | OK. Confirmed gcc 13 + OpenMPI 4.1.6 toolchain and MPI execution. |

### Run 2: LIGGGHTS `chute_wear`

| | |
|---|---|
| Date | 2026-10-02 |
| Binary | `lmp_auto` with VTK 9.3.1 |
| Input | `Tutorials_public/chute_wear/in.chute_wear`, unchanged |
| Launch | `mpirun -np 8 lmp_auto -in in.chute_wear` |
| Size | 824 particles at the end, 100000 steps (1.0 s at dt 1e-5) |
| Wall time | 15 s |
| Output | 750 particle files `post/chute_*.vtk`, 750 mesh files `post/mesh_*.vtk` (143 MB) |
| Location | `runs/chute_wear/` |
| Outcome | OK. Mesh files carry `normal_stress_average`, `shear_stress_average`, `wear` per facet. First confirmation that the VTK dump styles work. |

### Run 3: LIGGGHTS `conveyor`

| | |
|---|---|
| Date | 2026-10-02 |
| Binary | `lmp_auto` with VTK 9.3.1 |
| Input | `Tutorials_public/conveyor/in.conveyor`, unchanged |
| Launch | `mpirun -np 8 lmp_auto -in in.conveyor` |
| Size | 382 particles (254 r=0.015, 128 r=0.025), 140000 steps (1.4 s at dt 1e-5) |
| Wall time | 10 s |
| Output | 700 files `post/conveyor_*.vtk` (16 MB); no mesh dump in this input |
| Location | `runs/conveyor/` |
| Outcome | OK. 30 kg inserted in 11 insertions of about 38 particles (3 kg) at steps 1, 10001, ..., 100001. Final KE 13.5 J. Particles pile against the wall at x = -0.5. Timestep/Rayleigh-time ratio 0.005, well inside the stable range. |

### Run 4: pe `conveyor`, attempt 1 (number fractions, extrusion below the face)

| | |
|---|---|
| Date | 2026-10-02 |
| Binary | `pe-0.3rc1/build/conveyor/examples/conveyor/conveyor`, HardContactSemiImplicitTimesteppingSolvers |
| Setup | dt 5e-4, 2800 steps, distribution weights used as number fractions, insertion centres shrunk by the radius, volume z in [0.1, 0.2] |
| Launch | serial |
| Wall time | 8.5 s |
| Outcome | Ran, but 540 particles for 30 kg (LIGGGHTS: 382) and `collector.pvd` empty. Two input-mapping errors, see quirks 6.6 and section 5. |

### Run 5: pe `conveyor`, attempt 2 (mass fractions, per-particle retries)

| | |
|---|---|
| Setup | as run 4, weights converted to number fractions via f_i/m_i, radius sampled once per particle with 100 position attempts |
| Wall time | 9.0 s |
| Outcome | 561 particles. Still wrong: with centres shrunk by the radius the large particles do not fit into the small insertion volume, so the realised mix stays small-heavy. |

### Run 6: pe `conveyor`, final

| | |
|---|---|
| Date | 2026-10-02 |
| Setup | insertion volume z in [0.2, 0.3] (face extruded against the velocity), centres-only overlap check (`all_in no`), `writeEmptyFiles=true` for the VTK writer |
| Launch | serial, from `runs/pe_conveyor/` |
| Size | 366 particles (233 r=0.015, 133 r=0.025), 2800 steps (1.4 s at dt 5e-4) |
| Wall time | 7.6 s |
| Output | 350 frames in `paraview/0/{spheres,boxes}*.vtu`, `paraview/collector.pvd` with 1400 entries (21 MB) |
| Location | `runs/pe_conveyor/` |
| Outcome | OK. Matches LIGGGHTS qualitatively; numbers in section 3. Reference run for the pe port. |

### Run 7: pe `conveyor`, friction 0.25 per material (effective pair value 0.5)

| | |
|---|---|
| Date | 2026-10-02 |
| Binary | as run 6, rebuilt with the new `--friction` / `--out` / `--no-vtk` options |
| Setup | as run 6 but `--friction 0.25`, so the pair coefficient equals the LIGGGHTS 0.5 (see quirk 6.3) |
| Launch | `conveyor --friction 0.25`, serial, from `runs/pe_conveyor_mu025/` |
| Size | 366 particles (233 r=0.015, 133 r=0.025; same seed, same insertion sequence as run 6) |
| Wall time | 9.1 s |
| Output | 350 frames, `paraview/collector.pvd` |
| Location | `runs/pe_conveyor_mu025/` |
| Outcome | OK. Kinetic energy during insertion now within 10 % of LIGGGHTS (25.9 J vs 28.5 J at 1.0 s, previously 32.8 J). Final KE 9.6 J vs 13.5 J. Final x range -0.485 to 0.427 (LIGGGHTS 0.410). This is the better reference for comparisons; run 6 is kept because its material lines read like the LIGGGHTS input. |

### Runs 8 to 14: LIGGGHTS twins for the tutorial ports

| Run | Case / input | Launch | Size | Wall | Output | Outcome |
|---|---|---|---|---|---|---|
| 8 | `insert_stream/in.insert_stream` | 8 ranks | 1200 particles (300 every 0.3 s), 100000 steps, 1.0 s | 5.5 s | 125 dumps `post/stream_*.vtk` | OK, `runs/insert_stream/` |
| 9 | `contactModels/in.newModels` | 8 ranks | 1800 particles, 50000 steps, 0.5 s | 9.1 s | `post/newModels_*.vtk` | OK |
| 9b | `contactModels/in.oldModels` | 8 ranks | - | 2.5 s | - | **FAILED**: `ERROR: Invalid pair style`. The legacy `gran/hertz/history` syntax is not in LIGGGHTS 3.8; no twin for pe. |
| 10 | `cohesion/in.cohesion`, `in.noCohesion` | 8 ranks | 1000 particles (250 every 0.03 s), 50000 steps | 10.9 s / 4.5 s | `post/cohesion_*.vtk`, `post/noCohesion_*.vtk` | OK |
| 11 | `hysteresis/in.hysteresis`, `in.noHysteresis` | 8 ranks | 1000 particles, 50000 steps | 5.0 s / 4.5 s | `post/hysteresis_*.vtk`, `post/noHysteresis_*.vtk` | OK |
| 12 | `multisphere_stone_restitution/in.multisphere` | **1 rank** (input has `processors 1 1 1`; 8 ranks fail with `Specified processors != physical processors`) | 2 stones x 50 spheres, 40000 steps | 4.1 s | 200 dumps `post/multi_*.vtk` | OK |
| 13 | `meshGran/in.meshGran` | 8 ranks | 500 particles (20 every 0.02 s), 40000 steps, 2.0 s | 9.0 s | `post/meshGran_*.vtk`, mesh `post/dump*.stl` | OK |
| 14 | `movingMeshGran/in.movingMeshGran` | 8 ranks | 1275 particles, 70000 steps, 3.5 s | 19.0 s | `post/movingMesh_*.vtk`, mesh `post/dump*.stl` | OK |

All launched by `runs/run_twins.sh` on 2026-10-02. The `dump mesh/stl` files of runs 13 and 14
are the world-space meshes later used as pe input (section 9).

### Runs 15 to 21: pe ports (all serial, binaries in `pe-0.3rc1/build/cgal/examples/liggghts_ports/`)

| Run | pe program | Setup | Wall | Location | Outcome |
|---|---|---|---|---|---|
| 15a | `lp_insert_stream` (attempt 1) | insertion into the extruded volume with the full velocity, no pre-release phase | 3.4 s | - | ran, but KE 45 % above LIGGGHTS: LIGGGHTS moves fresh particles kinematically until they cross the face (section 9.1) |
| 15b | `lp_insert_stream` (attempt 2) | pre-release kinematics added | 3.0 s | - | ran, 5 particles kicked to 17 m/s at release (quirk 6.13) |
| 15 | `lp_insert_stream` | kinematics + release delayed until clear of neighbours, dt 2.5e-4, 4000 steps | 3.1 s | `runs/pe_insert_stream/` | OK, KE within 1 % of LIGGGHTS |
| 16 | `lp_cylinder_pack --case newModels` | 1800 spheres r 2.5 mm, dt 1e-4, 5000 steps | **5 min 37 s** | `runs/pe_newModels/` | OK |
| 17 | `lp_cylinder_pack --case noCohesion` | 1000 spheres r 1.5 mm, dt 1e-4, 5000 steps | 1 min 56 s | `runs/pe_noCohesion/` | OK |
| 18 | `lp_cylinder_pack --case noHysteresis` | identical to run 17 (same seed) | 1 min 53 s | `runs/pe_noHysteresis/` | OK, bit-identical to run 17 by construction |
| 19 | `lp_multisphere` | 2 unions of 50 spheres from the LIGGGHTS step-200 dump, dt 1e-4, 3980 steps | 0.3 s | `runs/pe_multisphere/` | OK |
| 20 | `lp_mesh_gran` | trough.obj (92 triangles) fixed, 500 spheres, dt 1e-4, 20000 steps | 3 min 5 s | `runs/pe_meshGran/` | OK |
| 21 | `lp_moving_mesh_gran` | 1191 spheres, kinematic bucket.obj from t = 1.5 s, dt 5e-4, 7000 steps | 4 min 57 s | `runs/pe_movingMeshGran/` | OK |

| 22 | `lp_multisphere` with Monte-Carlo clump mass | as run 19, after adding `UnionBase::recomputeMassFromVolume()` to pe (1e6 samples per stone) | 2.3 s | `runs/pe_multisphere_mc/` | OK, stone masses 0.04594 / 0.04612 kg vs LIGGGHTS 0.0460 kg (section 9.4) |
| 23 | `lp_multisphere` erp sweep | run 22 setup with `--erp 0.5 / 0.2 / 0.05 / 0.0`, no VTK | 2 s each | `runs/pe_multisphere_mc/run_erp*.log` | post-impact energy scales with erp; see 9.4 and quirk 6.20 |

### Runs 24 to 30: all pe ports rerun with erp 0.05 (the new reference runs)

After quirk 6.20 every port got an `--erp` option and was rerun with 0.05 (run script
`runs/run_pe_erp005.sh`, all seven in parallel, 2026-10-02). Everything else as in runs 7
and 15 to 22. `noHysteresis` is not repeated (identical to `noCohesion` in pe).

| Run | pe program | Wall | Location | Outcome vs erp 0.5 |
|---|---|---|---|---|
| 24 | `conveyor --friction 0.25 --erp 0.05` | 12.6 s | `runs/pe_conveyor_erp005/` | 375 particles in 10 insertions (random sequence diverged), KE within 3 % of run 7; belt case is not impact-dominated |
| 25 | `lp_insert_stream --erp 0.05` | 3.5 s | `runs/pe_insert_stream_erp005/` | identical to run 15 (free fall, no significant contacts) |
| 26 | `lp_cylinder_pack --case newModels --erp 0.05` | 5 min 39 s | `runs/pe_newModels_erp005/` | bed identical to 0.1 mm, residual KE lower |
| 27 | `lp_cylinder_pack --case noCohesion --erp 0.05` | 2 min 22 s | `runs/pe_noCohesion_erp005/` | top of bed 4.1 mm instead of 5.9 mm (stray bounced particle gone) |
| 28 | `lp_multisphere --erp 0.05` | 3.0 s | `runs/pe_multisphere_erp005/` | no rebound, both stones at rest (KE 1.8e-6 J), final positions closer to LIGGGHTS |
| 29 | `lp_mesh_gran --erp 0.05` | 3 min 18 s | `runs/pe_meshGran_erp005/` | rattling particle gone, final KE 7e-4 J instead of 1e-2 J |
| 30 | `lp_moving_mesh_gran --erp 0.05` | 5 min 18 s | `runs/pe_movingMeshGran_erp005/` | 4 particles in bucket (LIGGGHTS 5), scooping energies lower |

Sources: `pe-0.3rc1/examples/liggghts_ports/` (`liggghts_common.h` plus one `.cpp` per case,
registered in `examples/CMakeLists.txt`). Mesh conversion: `runs/stl2obj_pe.py`. All pe runs
use friction 0.025 per material (pair value 0.05, as in the LIGGGHTS inputs; conveyor-style
friction 0.5 cases use 0.25). Runs 15 to 22 used erp 0.5, runs 24 to 30 erp 0.05 (see quirk
6.20); otherwise default relaxation settings.

---

## 2. Reproduction commands

LIGGGHTS case:

```bash
source /data/warehouse17/rmuenste/code/liggghts-dem/env.sh
R=/data/warehouse17/rmuenste/code/liggghts-dem/runs
mkdir -p $R/<case> && cp -r $LIGGGHTS_ROOT/examples/LIGGGHTS/Tutorials_public/<case>/. $R/<case>/
cd $R/<case> && mpirun -np 8 lmp_auto -in in.<case> | tee run.log
```

pe conveyor:

```bash
source /etc/profile.d/modules.sh && module load gcc/13.2.0 boost/1.88
cd /data/warehouse17/rmuenste/code/liggghts-dem/pe-0.3rc1
ninja -C build/conveyor conveyor          # after editing examples/conveyor/conveyor.cpp
mkdir -p ../runs/pe_conveyor && cd ../runs/pe_conveyor
../../pe-0.3rc1/build/conveyor/examples/conveyor/conveyor | tee run.log
```

If `build/conveyor` has to be recreated, the configure command is in `PE_CONVEYOR.md`,
section 5. Do not forget `-DBoost_USE_STATIC_LIBS=ON` and the solver flag. All ports accept
`--erp <value>`; use 0.05 for granular impacts (quirk 6.20). `runs/run_pe_erp005.sh` reruns
all seven ports in parallel, `runs/summarize_erp005.py` extracts the comparison numbers.

---

## 3. Conveyor: LIGGGHTS versus pe, numbers

| time [s] | LIGGGHTS particles | pe particles (runs 6, 7) | LIGGGHTS KE [J] | pe KE, mu 0.5, erp 0.5 (run 6) [J] | pe KE, mu 0.25, erp 0.5 (run 7) [J] | pe KE, mu 0.25, erp 0.05 (run 24) [J] |
|---|---|---|---|---|---|---|
| 0.2 | 77 | 85 | 6.1 | 7.8 | 7.3 | 7.4 |
| 0.4 | 153 | 154 | 13.1 | 18.0 | 14.4 | 13.8 |
| 0.6 | 229 | 223 | 22.7 | 30.3 | 24.2 | 23.9 |
| 0.8 | 305 | 300 | 27.0 | 30.4 | 26.6 | 26.3 |
| 1.0 | 381 | 364 | 28.5 | 32.8 | 25.9 | 26.5 |
| 1.2 | 382 | 366 | 21.2 | 23.2 | 17.3 | 17.7 |
| 1.4 | 382 | 366 | 13.5 | 9.2 | 9.6 | 9.8 |

Run 24 placed 375 particles (10 insertions of the full 3 kg; the random sequence differs from
runs 6 and 7 once the dynamics differ). Its final bed: top at z = 0.077 m, 95 % below 0.025 m,
x from -0.485 to 0.478.

| final state | LIGGGHTS | pe run 6 (mu 0.5) | pe run 7 (mu 0.25) |
|---|---|---|---|
| size split (r=0.015 / 0.025) | 254 / 128 | 233 / 133 | 233 / 133 |
| x range [m] | -0.486 to 0.410 | -0.485 to 0.303 | -0.485 to 0.427 |
| z range [m] | -0.186 to 0.123 | -0.185 to 0.148 | -0.185 to 0.087 |
| steps / dt | 140000 / 1e-5 s | 2800 / 5e-4 s | 2800 / 5e-4 s |
| wall time | 10 s, 8 ranks | 8 s, serial | 9 s, serial |

With the friction corrected (run 7) the kinetic-energy history tracks LIGGGHTS to
within about 10 % while particles are being inserted. The remaining differences come
from the contact model (soft Hertz with restitution 0.3 versus inelastic hard contact)
and from the random realisation of the particle mix (366 vs 382 particles for the same
30 kg).

---

## 4. Differences between the two libraries

| Topic | LIGGGHTS-PUBLIC 3.8 | pe (fork 0.3rc1) |
|---|---|---|
| Nature | Finished DEM application driven by an input script | C++ library; every case is a compiled program |
| Contact physics | Soft contacts: Hertz or Hooke springs, dashpots, tangential history, cohesion, rolling friction | Hard contacts by default: complementarity solved per step (several relaxation models), plus FFD, and soft-contact `DEMSolver` / `DEMSolverObsolete` as alternatives |
| Solver choice | Runtime, per `pair_style` / `fix wall/gran` | Compile time macro `pe_CONSTRAINT_SOLVER`; changing it rebuilds the whole library |
| Time step | Fraction of the Rayleigh/Hertz time, here 1e-5 s | Kinematic limit only for hard contacts; 5e-4 s used here |
| Material model | Per-type properties: Young, Poisson, restitution, friction, each as pairwise tables | `createMaterial(name, density, cor, csf, cdf, poisson, young, k, dampN, dampT)`; pair values derived by fixed combination rules (friction added, restitution stiffness-weighted) |
| Geometry | Triangulated STL walls (`fix mesh/surface`), open surfaces fine, moving/rotating meshes, wall stress and wear, insertion faces | Primitives (sphere, box, capsule, cylinder, plane, ellipsoid, union) and closed triangle meshes (GJK/EPA, or CGAL signed-distance maps). Open STL surfaces are not usable as walls |
| Moving walls | `surface_vel`, `fix move/mesh` (rotate, translate, wiggle) | Set velocity on a fixed body and reset its position every step (quirk 6.1), or move it by hand |
| Particle insertion | `insert/stream`, `insert/pack`, `insert/rate/region` with templates, distributions, overlap check, mass rate | None built in; write your own loop with `createSphere`, random positions and an overlap check |
| Particle shapes | Spheres, multispheres, superquadrics | Spheres, boxes, capsules, cylinders, ellipsoids, unions, meshes, granular agglomerates |
| Parallelism | MPI domain decomposition, automatic | MPI with hand-written Cartesian decomposition and neighbour connection code per example |
| Output | `dump custom/vtk`, mesh dumps with stress and wear, text dumps, restart files | `vtk::Writer`: spheres, boxes, capsules, meshes as `.vtu` plus `collector.pvd`; planes are not written; checkpoints via `Checkpointer` |
| Thermo / diagnostics | `thermo_style custom`, computes, `fix check/timestep/gran` | Whatever the program prints; iterate `world->begin<Sphere>()` |
| Units | `units si` and others, checked | None; the user keeps SI consistent |
| Build | `make auto` with `Makefile.user`; needs MPI and VTK | CMake; needs Boost (and Eigen, json fetched from the internet); CGAL and MPI optional |
| Documentation | Full HTML manual in `doc/` | `AGENTS.md` and `doc/technical-notes/*.md`; API from headers |

---

## 5. Input-mapping lessons from the conveyor port

These are LIGGGHTS semantics that are easy to get wrong when translating an input
script into pe code:

1. `fix particledistribution/discrete ... pts1 0.3 pts2 0.7` weights are **mass**
   fractions. For number fractions LIGGGHTS has `particledistribution/discrete/numberbased`.
   The 254/128 final split of run 3 is exactly 0.3/m_small : 0.7/m_large.
2. `fix insert/stream ... extrude_length L vel v` extrudes the insertion face **against**
   `v`; particles start outside the domain side of the face and stream through it.
   Verified in the LIGGGHTS dump at step 400 (new particles at z = 0.21 to 0.31 for a
   face at z = 0.2 and `vel 0 0 -1`).
3. `all_in no` (the default) means only the particle centre must lie inside the
   insertion volume. Shrinking the centre range by the radius starves the large size
   class.
4. The insertion interval is `extrude_length / |vel|` (here 0.1 s), and the mass per
   insertion is `massrate` times that interval (3 kg). Insertion stops when `mass`
   (30 kg) is reached.
5. `maxattempt 100` is per particle, with the radius already chosen. Re-drawing the
   radius on every failed attempt biases the mix towards small particles.

---

## 6. pe quirks

Things that behaved differently from what one would assume. Verified in the source
on 2026-10-02 (commit `ce3bb5f`).

### 6.1 A "fixed" body is a kinematic body, not a stationary one
In pe, `setFixed(true)` makes a body infinite-mass and infinite-inertia (`fix()` sets
the inverse mass and inverse inertia to zero). Consequences:

- Contact impulses produce no velocity change on it and the solver adds no gravity to
  it. Nothing the particles do can influence a fixed body.
- With the `MOBILE_INFINITE=1` build flag (set in the pe CMakeLists) `fix()` leaves the
  velocity untouched and `setLinearVel` / `setAngularVel` remain allowed. The body
  therefore carries a *prescribed* velocity, which the contact solver uses in the
  relative contact velocity. This is how the belt drives the particles.
- The position-integration loop in `HardContactSemiImplicitTimesteppingSolvers.h`
  (around line 2075) integrates every awake body with its velocity, fixed ones
  included (for global fixed bodies it explicitly ignores velocity corrections and uses
  the prescribed velocity only). A fixed body with a velocity translates steadily.

So a pe fixed body is a kinematically driven body: it moves as prescribed and is
immune to collisions. That is a feature for translating or vibrating walls (set the
velocity, let pe move the wall). A conveyor belt is the one case that wants the
surface velocity without the translation, hence `belt->setPosition(beltCenter)` after
every `simulationStep` to undo the drift while keeping the velocity for the next
contact solve. `Box::setPosition` works on fixed bodies, so the reset is cheap. Without
`MOBILE_INFINITE` pe would zero the velocity in `fix()` and a moving-surface wall would
not be possible at all.

### 6.2 No contact between two fixed bodies
`pe_INTERNAL_ASSERT( !b1->isFixed() || !b2->isFixed() )` in the hard-contact
collision system. In a Release build the assert is compiled out, but do not rely on
it: keep fixed geometry from overlapping (the belt box is 1 mm smaller than the
container for this reason).

### 6.3 Material combination rules
`Materials.cpp`: static and dynamic friction of a pair are the **sum** of the two
material values; restitution is `sqrt((cor_i^2/k_i + cor_j^2/k_j) * k_ij)`. Two
materials with friction 0.5 give a pair coefficient of 1.0. The hard-contact solver
reads only the friction table (`c->getFriction()`), so restitution, Young's modulus
and the stiffness/damping numbers in `createMaterial` do not influence it at all.

### 6.4 Solver is a compile-time choice for the whole library
`pe_CONSTRAINT_SOLVER` (in `pe/config/Collisions.h`) selects the collision-system
specialisation. The default `HardContactEulerLagrange` response class is a stub with a
"TODO" doc comment; the production hard-contact family is
`HardContactSemiImplicitTimesteppingSolvers`, and `mpidem` refuses to run with
anything else. Pass the macro via `-DPE_PREPROCESSOR_FLAGS=...` at configure time so
library and executable agree; mixing is an ODR violation that will not be diagnosed.

### 6.5 Open triangle meshes have no inside
Mesh collision is volume based. A two-triangle belt or a five-sided box cannot be
loaded as a wall with any meaningful result (and the DistanceMap path, which needs
CGAL, classifies inside/outside with CGAL `Side_of_triangle_mesh`, which requires a
closed mesh). Use planes and boxes, or close the mesh.

### 6.6 VTK collector written at activation
`vtk::activateWriter(dir, spacing, tstart, tend, binary, writeEmptyFiles)` writes
`collector.pvd` in the constructor and lists only body types that already exist. With
`writeEmptyFiles=false` (default) and no spheres yet, the collection is empty while
the `.vtu` files are still written. Use `writeEmptyFiles=true` or activate after
creating the first bodies. The writer is a singleton; later calls return the same
instance and ignore the arguments.

### 6.7 VTK writer does not write planes
Planes are registered but have no writer. Load an STL of the walls into ParaView
separately. Boxes, spheres, capsules and meshes are written; `capsules*.vtu` and
`meshes*.vtu` are empty when none exist.

### 6.8 Boost module is static-only
`module load boost/1.88` has no shared libraries. pe sets `Boost_USE_STATIC_LIBS OFF`;
without `-DBoost_USE_STATIC_LIBS=ON` CMake falls back to the system Boost 1.75 and
aborts on the version check.

### 6.9 Configure needs internet
Eigen 3.4 and nlohmann/json are fetched with `FetchContent` into the build tree on the
first configure. Offline builds need the sources pre-populated under
`build/<name>/_deps/`.

### 6.10 ParaView modules switch the compiler
`module load paraview/*` loads gcc 11.4.1 and conflicts with gcc 13. Post-process in
a separate shell, never in the shell used for building LIGGGHTS or pe.

### 6.11 Timing header is not pulled in by `pe/util.h`
`pe::timing::WcTimer` needs `#include <pe/util/timing/WcTimer.h>` explicitly.

### 6.12 `createPlane(id, a, b, c, d, material)` uses `n.x = d`
Not the textbook `n.x + d = 0`. The normal points into the free half space. Floor at
z = -0.2 is `createPlane(id, 0,0,1, -0.2, mat)`; wall at x = +0.5 facing inwards is
`createPlane(id, -1,0,0, -0.5, mat)`. See `doc/technical-notes/plane-conventions.md`.

### 6.13 Overlap removal is a velocity kick
The hard-contact solver removes an existing overlap within one step (error reduction parameter
`erp`, default 0.7). A body that is suddenly made collidable while overlapping a neighbour by a
depth d receives a velocity of order `erp * d / dt`: 5 mm at dt 2.5e-4 gave 17 m/s in run 15b.
Anything that creates overlaps outside the solver (insertion, enabling collisions, moving
bodies by hand, `setPosition`) must make sure the overlap is zero first. Soft-contact codes
resolve the same overlap over many steps through the spring force.

### 6.14 The hard-contact solver ignores restitution
`HardContactSemiImplicitTimesteppingSolvers` reads only the friction coefficient of a contact
(`c->getFriction()`); all collisions are perfectly inelastic. The `cor` argument of
`createMaterial` has no effect with this solver. In `newModels` (LIGGGHTS restitution 0.95) the
LIGGGHTS bed keeps bouncing for 0.3 s while pe is at rest after 0.15 s (section 9.2). A
restitution model would have to be added to the relaxation (Newton or Poisson restitution in
the contact velocity target).

### 6.15 Union mass double-counts overlapping members (fixed, opt-in)
`UnionBase::calcCenterOfMass` / `calcInertia` sum the member masses and inertias; overlapping
volume is counted once per member. The 50-sphere stone of `multisphere_stone_restitution` has
a summed mass of 0.0741 kg, while LIGGGHTS integrates the true clump volume by Monte Carlo
(0.0460 kg); the centre of mass is biased towards the overlaps as well. Trajectories under
gravity are unaffected, but contact forces, momenta and kinetic energies are 1.6 times too
large for this stone. This is **not** a self-penetration: members are removed from the
collision system when added to a union, only the union is a detection body, and members of
the same union are never paired.

Fix (2026-10-02, uncommitted in the pe fork): `UnionBase::recomputeMassFromVolume(samples)`
samples the union's bounding box uniformly, counts every point inside at least one member once
with that member's material density, and replaces mass, centre of mass and inertia (parallel
axis about the new centre, body frame), then updates the members' relative positions. Links
are not updated. Call it once after the last `add`. With 1e6 samples the stone comes out at
0.04594 and 0.04612 kg (LIGGGHTS 0.0460), the centre of mass moves by 0.3 mm. Cost about 1 s
per 50-sphere clump. The default `add` path is unchanged, so existing simulations are
unaffected.

### 6.16 Triangle meshes: OBJ only, re-centred, winding matters for mass
`createTriangleMesh(uid, gpos, file, ...)` accepts only `.obj` (the STL branch is commented out
with the remark that STL has no half-edge information, so the OBJ needs shared vertices). The
vertices are shifted by the volume centroid (divergence-theorem formula) and placed at `gpos`,
so a mesh given in world coordinates only lands where it belongs if `gpos` equals that
centroid; `runs/stl2obj_pe.py` prints it. The signed volume (and hence mass) follows the face
winding; the script flips clockwise meshes. The `convex` argument is not checked (the line
`if( !convex, "Only convex ..." )` is a no-op comma expression), non-convex meshes work.

### 6.17 Sphere-mesh contact is a brute-force closest-triangle search
`MaxContacts::collideSphereTMesh` loops over all triangles of the mesh for every sphere whose
AABB overlaps the mesh AABB and makes one contact at the closest point. No DistanceMap, no
GJK, no CGAL needed, open meshes work too. Cost is O(triangles) per sphere per step: fine for
the 92-triangle trough, prohibitive for a 1616-facet chute with thousands of particles. The
contact normal is `centre - closest point`, so a sphere centre that passes through a thin
wall is pushed out on the wrong side.

### 6.18 Dense packings are slow
Cost of the relaxation solver scales with contacts times iterations (default 100). 1800
spheres settling in a cylinder took 5.6 min serial for 5000 steps (run 16); LIGGGHTS needed
9 s on 8 ranks for 50000 soft-contact steps. The 50x larger pe time step does not compensate.
For loose or dilute flows (insert_stream, conveyor) pe is as fast as or faster than LIGGGHTS.

### 6.19 `world->begin<Sphere>()` does not see union members
Spheres that were added to a Union leave the world's body storage; iterate the unions and
their members instead. The VTK writer still writes them (they were registered at creation).

### 6.20 The error reduction parameter is an artificial coefficient of restitution
In `HardContactSemiImplicitTimesteppingSolvers` the penetration depth of a contact is scaled
by `erp` (`dist_[j] *= erp_`, default 0.7) and the solver demands that this fraction of the
overlap vanish within the step, i.e. a separation velocity of `erp * depth / dt`. A body
approaching at speed v penetrates about `v * dt` before the contact is detected, so the
correction velocity is about `erp * v`: an impact rebounds with an effective restitution of
roughly erp, independent of dt. Measured on the multisphere stone (run 23, impact speed 2.5
m/s, kinetic energy 0.263 J before impact):

| erp | KE at 0.16 s [J] | retained | max rebound height of a sphere centre [m] | KE at 0.4 s [J] |
|---|---|---|---|---|
| 0.5 (used in runs 15 to 22) | 1.6e-2 | 6.2 % | 0.048 | 2.0e-3 |
| 0.2 | 4.3e-3 | 1.6 % | 0.024 | 1.1e-5 |
| 0.05 | 2.8e-3 | 1.1 % | 0.019 (no rebound) | 7.4e-6 |
| 0.0 | 2.6e-3 | 1.0 % | 0.019 (no rebound) | 3.8e-6 |
| LIGGGHTS, Hertz, e = 0.3 | 5.9e-3 | 2.3 % | 0.022 | 1.0e-3 |

With erp near zero the inelastic hard contact keeps about 1 % of the impact energy, which is
the tumbling of the clump about the off-centre contact point, and lies below the elastic
LIGGGHTS value as it should. With the default 0.7 the solver would behave like a restitution
of about 0.7 on every impact. Consequences: use a small erp (0.05 or less) for granular
impacts and rely on the contact threshold to keep overlaps small; a real restitution model
(6.14) should be implemented in the velocity target, not through erp. Runs 15 to 22 used
erp 0.5; all ports were rerun with 0.05 (runs 24 to 30). Settled beds and free-fall cases were
unchanged, impact-dominated cases (multisphere, meshGran tail, stray bounced particles)
changed as predicted.

---

## 7. Which LIGGGHTS tutorials could be reproduced in pe

Survey of `examples/LIGGGHTS/Tutorials_public` (2026-10-02). Basis: the commands used
in each input script, a watertightness check of every STL file, and the pe inventory:
primitives Sphere, Box, Capsule, Cylinder, InnerCylinder (sphere inside a cylindrical
container), Ellipsoid, Plane, Union (clumps of primitives), TriangleMesh (closed meshes,
DistanceMap needs CGAL); hard-contact solvers plus `DEMSolverObsolete` with `basic`
(linear) or `hertz` normal force; kinematic bodies with prescribed linear and angular
velocity (`mesh_spin` example); no cohesion, adhesion, plasticity, rolling friction,
heat transfer, SPH or particle growth found in `pe/core`.

STL watertightness (open edges = edges not shared by exactly two facets):

| mesh | facets | open edges | usable as pe TriangleMesh |
|---|---|---|---|
| conveyor/box.stl, conveyor.stl, *insertion_face.stl, hydrogel piston | 2 to 10 | 4 | no (flat or open; use planes/boxes) |
| chute_wear/simple_chute.stl | 1616 | 108 | no (open shell; would need thickening into a solid) |
| insert_stream/face.stl | 86 | 42 | no, but only used as an insertion polygon |
| meshGran/mesh.stl | 92 | 0 | yes (mm units, LIGGGHTS scales by 0.001) |
| movingMeshGran/bucket.stl | 28 | 0 | yes (mm units) |

Assessment per tutorial:

| tutorial | key LIGGGHTS features | pe feasibility | how |
|---|---|---|---|
| conveyor | STL walls, surface velocity, insert/stream | **done** (runs 6, 7) | planes + kinematic box, own insertion loop |
| packing | plane walls, insert/pack, `fix adapt` particle growth | partial | planes are trivial; growth has no pe counterpart found, settle under gravity instead |
| contactModels (new/old) | hertz vs legacy syntax, cylinder container, insert/pack, pour | **done** (run 16, newModels only; oldModels does not run in LIGGGHTS 3.8 either) | InnerCylinder + planes |
| cohesion (in.noCohesion) | cylinder container, insert/pack | **done** (run 17) | InnerCylinder + planes |
| cohesion (in.cohesion) | SJKR cohesion | no | no cohesion model in pe |
| hysteresis (in.noHysteresis) | Hooke, cylinder container | **done** (run 18) | identical to run 17 in pe |
| hysteresis (in.hysteresis) | hooke/hysteresis plastic model | no | no plasticity in pe |
| insert_stream | 1200 particles streamed through a polygonal face, free fall | **done** (run 15) | area-weighted sampling on the face, LIGGGHTS pre-release kinematics emulated |
| meshGran | closed STL trough, insert/stream, Hooke | **done** (run 20), no CGAL needed | STL converted to OBJ, fixed TriangleMesh, brute-force sphere-mesh contacts |
| movingMeshGran | closed STL bucket, plane walls, `move/mesh linear` then `rotate` | **done** (run 21), no CGAL needed | kinematic fixed mesh driven analytically (position, orientation, v, w per step) |
| multisphere_stone_restitution | 50-sphere clumps from file, drop on a plane | **done** (run 19) | `Union` of spheres; mass double-counted (quirk 6.15) |
| chute_wear | open STL chute, wear (Finnie), stress output | partial | geometry only after closing the shell into a solid plus CGAL; no wear or facet stress in pe |
| hydrogel_multicontact (default) | plane walls, moving piston (2-triangle mesh) with force output | partial | piston as kinematic box; piston force must be summed from contacts by hand |
| hydrogel_multicontact (multicontact) | large-overlap multicontact soft model | no | contradicts the hard-contact assumption |
| mesh_tet | insertion into a tetrahedral region from a VTK file | partial | no tet region in pe; a point-in-tet rejection sampler is a few lines |
| heatTransfer_1, heatTransfer_2 | `heat/gran` conduction | no | no thermal model; would have to be built on top of the contact list |
| superquadric | superquadric shapes, rolling friction | partial | Ellipsoid primitive only (exponent-2 superquadrics), no rolling friction |
| sph_1, sph_2 | SPH fluid | no | not a rigid-body problem |
| ParScale/* | external ParScale library | no | cannot even run in this LIGGGHTS build |

Recommended order for further ports: `insert_stream` (pure spheres, stresses insertion
and scaling), `multisphere_stone_restitution` (Unions), `contactModels`/`noCohesion`
(InnerCylinder), then `movingMeshGran` and `meshGran` after a CGAL build of pe
(`module load cgal/6.1.2`, check that it does not drag in a gcc 11 module first).

---

## 8. Open items

- (done, run 7) pe conveyor with friction 0.25 per material.
- pe conveyor with `DEMSolverObsolete` (Hertz) at dt 1e-5 s, like for like.
- pe MPI build (`PE_USE_MPI=ON`, `module load openmpi/4.1.6`) with a Cartesian
  decomposition for an 8-rank run.
- LIGGGHTS tutorials not yet run: `heatTransfer_*`, `packing` (VTK build), `superquadric`,
  `sph_*`, `mesh_tet`, `hydrogel_multicontact`. `ParScale/*` cannot run (external library),
  `contactModels/in.oldModels` uses a removed pair style.
- pe: a restitution model for the hard-contact solver (quirk 6.14), a Monte-Carlo or
  inclusion-exclusion mass for unions (6.15), an insertion module (what `liggghts_common.h`
  does by hand), and the soft-contact `DEMSolverObsolete` build for a like-for-like contact
  model comparison. See section 10.
- Performance: dense packings (run 16) need either MPI or fewer relaxation iterations.
- (done, runs 24 to 30) all ports rerun with erp 0.05.
- Housekeeping: `vtk/VTK-9.3.1` and `vtk/build` (about 2 GB) can be deleted;
  `LIGGGHTS-PUBLIC/src/log.liggghts` is a stray file from a smoke test.

---

## 9. Tutorial ports: pe versus LIGGGHTS, case by case

pe numbers from the serial runs 15 to 22 (erp 0.5) and 24 to 30 (erp 0.05, the reference
after quirk 6.20), LIGGGHTS numbers from runs 8 to 14 (8 ranks, except multisphere). "KE" is
the translational kinetic energy (LIGGGHTS thermo `ke`). Where erp 0.5 and 0.05 agree, the
case is not impact-dominated; where they differ, the erp 0.05 column is the one to compare.

### 9.1 insert_stream (run 8 vs run 15)

What LIGGGHTS `insert/stream` really does, read off its dumps: the face is extruded along its
normal (not along the velocity), freshly inserted particles glide with the normal velocity
component (0,0,-2) and without gravity or contacts until they cross the face, and are released
with the full velocity (0,-0.5,-2) only then. A port that releases immediately is 45 % too
energetic (run 15a). With the emulation (StreamFace / releaseStream in `liggghts_common.h`):

| time [s] | particles | LIGGGHTS KE [J] | pe KE, erp 0.5 (run 15) [J] | pe KE, erp 0.05 (run 25) [J] |
|---|---|---|---|---|
| 0.1 | 300 | 54.7 | 55.1 | 55.1 |
| 0.3 | 300 | 143.3 | 144.8 | 144.8 |
| 0.5 | 600 | 425.6 | 426.6 | 426.6 |
| 0.7 | 900 | 917.6 | 914.3 | 914.3 |
| 1.0 | 1200 | 2161.0 | 2143.3 | 2143.3 |

Agreement within 1 %; erp has no influence because hardly any contacts occur. The case is dominated by free fall, so it mainly validates insertion
geometry, mass fractions and timing. pe: 3 s serial, LIGGGHTS: 5.5 s on 8 ranks.

### 9.2 contactModels/newModels (run 9 vs run 16)

1800 spheres (r 2.5 mm) dropped at once into a cylinder, restitution 0.95 in LIGGGHTS.

| time [s] | LIGGGHTS KE [J] | pe KE, erp 0.5 (run 16) [J] | pe KE, erp 0.05 (run 26) [J] |
|---|---|---|---|
| 0.05 | 0.107 | 0.099 | 0.099 |
| 0.10 | 0.079 | 0.057 | 0.057 |
| 0.15 | 6.7e-3 | 3.7e-4 | 2.4e-4 |
| 0.20 | 4.7e-3 | 4.3e-5 | 3.7e-5 |
| 0.30 | 1.7e-3 | 8.3e-7 | 1.2e-6 |
| 0.50 | 3.5e-6 | 1.3e-8 | 1.5e-10 |

Final bed: LIGGGHTS z95 % 23.0 mm, top 25.9 mm; pe 23.6 / 27.4 mm (erp 0.5) and 23.5 / 27.5 mm
(erp 0.05). The packing height agrees to 3 % and is insensitive to erp, but pe comes to rest 2
to 3 times faster because every hard contact is inelastic (quirk 6.14). Wall time 5.6 min (pe serial) vs 9 s (LIGGGHTS, 8 ranks): quirk 6.18.
The `oldModels` twin could not be run (legacy pair style removed from LIGGGHTS).

### 9.3 cohesion and hysteresis families (runs 10, 11 vs runs 17, 18)

Same container, 1000 spheres r 1.5 mm in four batches. LIGGGHTS runs four contact models on
identical insertion; pe can only represent the two without cohesion/plasticity, and for pe
those two are the same simulation (bit-identical runs 17 and 18).

| time [s] | L noCohesion (Hertz) | L noHysteresis (Hooke) | L cohesion (SJKR) | L hysteresis (plastic) | pe, erp 0.5 (run 17) | pe, erp 0.05 (run 27) |
|---|---|---|---|---|---|---|
| 0.05 | 2.80e-3 | 2.80e-3 | 2.80e-3 | 2.80e-3 | 2.80e-3 | 2.80e-3 |
| 0.10 | 7.03e-3 | 7.07e-3 | 5.78e-3 | 6.23e-3 | 5.67e-3 | 5.56e-3 |
| 0.20 | 3.08e-3 | 3.09e-3 | 6.5e-5 | 1.68e-3 | 8.8e-4 | 7.8e-4 |
| 0.30 | 1.28e-3 | 1.31e-3 | 2.0e-5 | 4.0e-4 | 9.1e-5 | 8.6e-5 |
| 0.50 | 7.7e-5 | 8.1e-5 | 3.5e-6 | 1.9e-5 | 1.9e-6 | 1.2e-6 |

Final bed height (z95 % / top, mm): noCohesion 4.4 / 8.5, noHysteresis 4.3 / 21.4 (one stray
particle), cohesion 12.4 / 14.5 (cohesive, loose), hysteresis 3.9 / 4.5 (plastic, densest),
pe 3.7 / 5.9 (erp 0.5) and 3.7 / 4.1 (erp 0.05, no bounced stragglers). pe reproduces the frictional no-cohesion bed to within one particle diameter
and, as expected, cannot reproduce the loose cohesive bed or the compacted plastic bed. What
would be needed for those is listed in section 10.

### 9.4 multisphere_stone_restitution (run 12 vs run 19)

Two 50-sphere stones, initial state taken from the LIGGGHTS dump at step 200.

| quantity | LIGGGHTS | pe, summed mass, erp 0.5 (run 19) | pe, MC mass, erp 0.5 (run 22) | pe, MC mass, erp 0.05 (run 28) |
|---|---|---|---|---|
| stone mass | 0.0460 kg (Monte Carlo volume) | 0.0741 kg (quirk 6.15) | 0.04594 / 0.04612 kg | 0.04611 / 0.04602 kg |
| KE at 0.10 s (free fall) | 0.181 J | 0.296 J (1.64x) | 0.184 J (+2 %) | 0.184 J |
| KE at 0.14 s (just before impact) | 0.259 J | - | 0.264 J | 0.264 J |
| first floor impact | about 0.15 s | about 0.15 s | about 0.15 s | about 0.15 s |
| KE at 0.16 s | 5.9e-3 J | - | 1.6e-2 J | 2.9e-3 J |
| KE at 0.20 s | 1.3e-3 J | 1.2e-2 J | 7.4e-3 J | 4.4e-3 J |
| KE at 0.40 s | 1.0e-3 J | 2.3e-3 J | 2.9e-3 J | 1.8e-6 J (at rest) |
| final: top sphere centre [m] | 0.022 | 0.021 | 0.025 | 0.019 |
| final x range of sphere centres [m] | -0.153 to -0.034 | -0.116 to -0.025 | -0.125 to -0.024 | -0.144 to -0.022 |

With the Monte-Carlo mass the free-fall energy matches LIGGGHTS to 2 % (the remaining
difference is the 1e-4 s pe step against the 0.002 s offset of the start state). The impact
itself still differs: LIGGGHTS (restitution 0.3, Hertz) retains 2.3 % of the pre-impact energy
at 0.16 s, pe with erp 0.5 retains 6 %. That is not elasticity but the penetration correction
acting as an artificial restitution of about erp (quirk 6.20, run 23): with erp 0.05 or 0 the
inelastic hard contact retains 1 %, the rebound disappears, and both stones are at rest after
0.4 s (KE 4e-6 J) while LIGGGHTS still has 1e-3 J. The energies after impact are therefore a
property of the contact model and of erp, not of the mass. Final resting positions of both pe runs are within one sphere radius of each other.
Wall time 2.3 s (pe, of which about 2 s are the two 1e6-sample integrations) vs 4 s (LIGGGHTS,
1 rank).

### 9.5 meshGran (run 13 vs run 20)

500 spheres (r 5 mm) streamed into a closed trough mesh and sliding 1.2 m down to its end.

| time [s] | LIGGGHTS KE [J] | pe KE, erp 0.5 (run 20) [J] | pe KE, erp 0.05 (run 29) [J] |
|---|---|---|---|
| 0.4 | 1.08 | 1.16 | 1.15 |
| 0.6 | 2.17 | 1.95 | 2.01 |
| 0.8 | 1.81 | 1.61 | 1.71 |
| 1.0 | 0.53 | 0.44 | 0.37 |
| 1.4 | 0.054 | 0.058 | 0.041 |
| 2.0 | 1.6e-4 | 1.1e-2 | 7.1e-4 |

Final state identical in character: all 500 particles inside the trough, piled at its lower end
(median z -1.189 LIGGGHTS, -1.195 / -1.190 pe; 95 % below -1.176 / -1.177 / -1.175), one
particle resting on a ledge at z = -0.245 in all runs, none through the outlet. The rattling
particle of run 20 is an erp artefact and is gone in run 29. The trough came from the LIGGGHTS
STL dump at step 0 (world coordinates) via `stl2obj_pe.py`; the pe AABB matched the LIGGGHTS
mesh to 1e-5 m. Wall time 3 min (pe) vs 9 s (LIGGGHTS, 8 ranks).

### 9.6 movingMeshGran (run 14 vs run 21)

1275 (LIGGGHTS) / 1191 (pe) spheres r 4 cm in a 2 x 1 x 1 m box; bucket appears at 1.5 s,
translates, then rotates about the y axis through the origin.

| time [s] | event | LIGGGHTS KE [J] | pe KE, erp 0.5 (run 21) [J] | pe KE, erp 0.05 (run 30) [J] |
|---|---|---|---|---|
| 0.5 | settling | 83.5 | 24.4 | 22.9 |
| 1.0 | settling | 1.40 | 0.46 | 0.31 |
| 1.5 | bucket appears | 0.018 | 0.039 | 0.085 |
| 2.0 | bucket translating | 2.98 | 5.05 | 4.39 |
| 2.25 | rotation starts | 6.39 | 6.39 | 6.99 |
| 2.5 | rotating | 19.1 | 10.4 | 8.9 |
| 3.0 | rotating | 8.5 | 5.4 | 3.9 |
| 3.5 | end | 18.4 | 7.6 | 5.0 |

Bucket kinematics agree with the LIGGGHTS `dump mesh/stl` (centroid at 3.5 s: LIGGGHTS
(0.161, 0.200, 0.147), pe (0.165, 0.200, 0.155)); 5 (LIGGGHTS) and 5 / 4 (pe, erp 0.5 / 0.05)
particles end up inside the bucket's bounding box. The settling energy at 0.5 s is 3.5 times
lower in pe for both erp values, so the difference there is the inelastic contact (6.14) and
the smaller particle count, not the stabilization. pe's insertion placed 1191 instead of 1275 particles (the
`insertPack` helper gives up earlier than LIGGGHTS' `ntry_mc`), and the energies during the
scooping differ by up to a factor two (fewer particles, inelastic contacts, 10x larger step).
Wall time 5 min (pe) vs 19 s (LIGGGHTS, 8 ranks).

---

## 10. State of pe after the ports: what is missing

Observed while porting seven LIGGGHTS tutorials. Ordered by how much they limited the
comparisons.

1. **Contact models.** pe's production path is the inelastic hard-contact solver. Missing for
   the LIGGGHTS tutorials:
   - *Restitution* (every tutorial): a Newton restitution target in the relaxation
     (`v_n^+ = -e v_n^-` for impacts above a velocity threshold) would close the gap seen in
     9.2 and 9.4 and make `createMaterial`'s `cor` meaningful again. Today the only "bounce"
     is the penetration correction, whose effective restitution is about erp (6.20) and whose
     default of 0.7 is far too bouncy for granular impacts.
   - *Cohesion (SJKR, `cohesion/in.cohesion`)*: an attractive normal force
     `F = k_c * A_contact` with `A = pi * (r_eff * delta)`-type contact area. In a hard-contact
     setting this is a bilateral constraint with a tensile strength (the contact may carry
     tension up to `k_c A` before breaking); in a soft-contact solver it is one extra term. pe
     has neither an adhesive constraint nor a cohesive force term. The cohesive bed in 9.3 is
     three times looser than the frictional one and cannot be reproduced.
   - *Plastic hysteresis (`hysteresis/in.hysteresis`, Walton-Braun / Luding)*: loading
     stiffness k1, unloading stiffness k2 > k1, adhesive branch k_adh, plasticity depth. This
     needs per-contact history (maximum overlap reached) and a force-displacement law, i.e. a
     soft-contact solver with contact history. `DEMSolverObsolete` has linear and Hertz normal
     forces but no history-dependent plasticity and no tangential history.
   - *Tangential history / static friction with stick*: the relaxation handles Coulomb
     friction impulsively; there is no tangential spring, so quasi-static piles are held by
     the iterative solve, which is why dense packings cost so much (6.18).
   - *Rolling friction* (superquadric tutorial) and *heat conduction* (heatTransfer): absent.
2. **Particle insertion.** No equivalent of `insert/pack`, `insert/stream`, templates or
   distributions. `liggghts_common.h` now provides region samplers, mass-fraction
   distributions, face-based streaming with pre-release kinematics and overlap checks; it
   would be worth moving into `pe/util` as a proper module (and matching LIGGGHTS' `ntry_mc`
   packing density, see 9.6).
3. **Clumps.** Unions work mechanically, but mass and inertia double-count overlaps (6.15).
   Done: `UnionBase::recomputeMassFromVolume()` (Monte-Carlo, opt-in, uncommitted). Left to
   decide: whether to make it the default for unions of overlapping primitives, and whether
   to refresh the links afterwards.
4. **Triangle meshes.** STL import is disabled (OBJ only, shared vertices required), meshes are
   re-centred so world placement needs the centroid (6.16), and sphere-mesh contact is a
   linear scan over triangles (6.17). A BVH over the triangles, STL reading, and a "keep world
   coordinates" creation flag would make LIGGGHTS-style wall meshes routine. The DistanceMap
   path (CGAL) is only used for mesh-mesh and plane-mesh pairs.
5. **Performance for dense granular beds.** 5.6 min serial for 1800 particles x 5000 steps
   (9.2). Options: MPI domain decomposition (exists, hand-coded per example), fewer relaxation
   iterations with a convergence check, or a soft-contact solver for dense static beds.
6. **Diagnostics.** No built-in thermo output, no kinetic-energy or lost-particle accounting,
   planes are not written to VTK, `world->begin<Sphere>()` skips union members (6.19).
7. **Small API hazards.** `createMaterial` friction pairs are sums (6.3), the VTK collector
   needs `writeEmptyFiles=true` (6.6), the `convex` flag of `createTriangleMesh` is a no-op
   (6.16), fixed bodies move (6.1).

What worked well: kinematic bodies (belt, bucket) are a clean fit; closest-point sphere-mesh
contacts handle arbitrary (even open) meshes without CGAL; insertion-dominated and dilute
cases match LIGGGHTS within a few percent; the hard-contact solver takes 10 to 50 times larger
steps than the Hertz model.
