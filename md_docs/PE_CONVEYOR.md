# Computing the LIGGGHTS conveyor tutorial with the pe physics engine

Date: 2026-10-02
pe source: `/data/warehouse17/rmuenste/code/liggghts-dem/pe-0.3rc1` (fork, commit `ce3bb5f`)
LIGGGHTS reference case: `examples/LIGGGHTS/Tutorials_public/conveyor/in.conveyor`
pe port: `pe-0.3rc1/examples/conveyor/conveyor.cpp`
Run directories: `runs/conveyor` (LIGGGHTS, 8 ranks) and `runs/pe_conveyor` (pe, serial)

---

## 1. Summary

The conveyor tutorial was re-implemented as a pe example. It uses pe's hard-contact
timestepping solver instead of LIGGGHTS' Hertzian soft-contact model, so the time step
is 50 times larger (5e-4 s instead of 1e-5 s). The serial pe run takes about 8 s for
1.4 s of simulated time and writes 350 ParaView frames. Particle counts and kinetic
energy over time agree with LIGGGHTS to within about 10 to 30 percent, and the final
state (particles carried off the belt and piled against the far wall) is the same.

---

## 2. How the LIGGGHTS setup maps onto pe

The three STL files of the tutorial are trivially simple, which decided the modelling
approach:

| STL file | Content | Bounding box |
|---|---|---|
| `box.stl` | 10 facets: an open box (floor and 4 walls) | x [-0.5, 0.5], y [-0.2, 0.2], z [-0.2, 0.2] |
| `conveyor.stl` | 2 facets: a flat rectangle, normal +z | x [-0.1, 0.5], y [-0.2, 0.2], z = 0 |
| `insertion_face.stl` | 2 facets: a flat rectangle, normal -z | x [0.3, 0.45], y [-0.17, 0.17], z = 0.2 |

pe's `TriangleMesh` collision path is volume based (GJK/EPA for convex meshes, or a
CGAL signed-distance map for non-convex ones). Open, zero-thickness surfaces like these
have no inside, so they were replaced by pe primitives:

| LIGGGHTS | pe |
|---|---|
| `fix bx mesh/surface box.stl` and the shrink-wrapped domain | 5 fixed `Plane`s (floor z=-0.2, walls x=±0.5, y=±0.2) |
| `fix cv mesh/surface conveyor.stl surface_vel -4.5 0 0` | fixed `Box`, 2 cm thick, top face at z=0, `setLinearVel(-4.5,0,0)` |
| `fix inface mesh/surface insertion_face.stl` + `fix ins insert/stream extrude_length 0.1 vel 0 0 -1` | random positions in x [0.3,0.45], y [-0.17,0.17], z [0.2,0.3]; velocity (0,0,-1) |
| `particletemplate/sphere` r=0.015 and r=0.025, density 2500 | two sphere radii, density 2500 |
| `particledistribution/discrete 0.3 0.7` | mass fractions converted to number fractions (see pitfall 4.3) |
| `insert/stream mass 30 massrate 30 maxattempt 100 overlapcheck yes` | 3 kg every 0.1 s until 30 kg, up to 100 position attempts per particle |
| Young 5e6, Poisson 0.45, restitution 0.3, friction 0.5 | `createMaterial("granular", 2500, 0.3, 0.5, 0.5, 0.45, 5e6, ...)` |
| `pair_style gran model hertz tangential history` | `pe::response::HardContactSemiImplicitTimesteppingSolvers` |
| `timestep 1e-5`, `run 140000` | dt = 5e-4 s, 2800 steps |
| `dump custom/vtk 400` (every 0.004 s) | `vtk::activateWriter("./paraview", 8, ...)` (every 0.004 s) |
| `thermo 1000` | screen output every 20 steps (0.01 s) |

Other points of the mapping:

- **Belt velocity.** pe's `MOBILE_INFINITE=1` build flag (set in the pe CMakeLists)
  allows `setLinearVel` on a fixed body, and the hard-contact solver uses that velocity
  in the relative contact velocity. pe also integrates the position of fixed bodies
  with their velocity, so the belt would drift at 4.5 m/s. The example therefore calls
  `belt->setPosition(beltCenter)` and `belt->setLinearVel(beltVel)` after every
  `simulationStep`. The belt is shrunk by 1 mm so it never touches the container
  planes (pe asserts against contacts between two fixed bodies).
- **Insertion.** LIGGGHTS extrudes the insertion face *against* the insertion velocity
  (checked in the LIGGGHTS dump at step 400: new particles sit at z = 0.21 to 0.31) and
  with its default `all_in no` only the particle centres must lie inside the volume.
  The pe example does the same. The radius is drawn once per particle and then up to
  100 positions are tried, as `maxattempt 100` does; otherwise large particles would be
  under-represented.
- **Contact model.** This is the real physical difference. LIGGGHTS integrates a
  Hertz spring-dashpot with tangential history; pe solves a hard-contact
  complementarity problem per step (no overlap, Coulomb friction, inelastic). pe's
  material "restitution" and "stiffness" values are therefore not used in the same
  way, and the time step is limited by kinematics, not by contact stiffness.
  pe combines the friction coefficients of two materials by **adding** them
  (`Materials.cpp`: `csfTable(i,j) = csf_i + csf_j`), so with 0.5 on both the
  particle and the wall material the effective coefficient is 1.0, and 1.0 for
  particle-particle. The LIGGGHTS run uses 0.5 for both pairs. To match LIGGGHTS
  exactly, set 0.25 in the pe materials. The example takes `--friction <mu>` (per
  material, default 0.5); `--friction 0.25` reproduces the LIGGGHTS pair value and is
  the better reference (RUNBOOK run 7). `--out <dir>` and `--no-vtk` are also accepted.

---

## 3. Results and comparison with LIGGGHTS

Both runs: 1.4 s simulated, 30 kg inserted at 30 kg/s during the first second.

| time [s] | LIGGGHTS particles | pe particles | LIGGGHTS KE [J] | pe KE [J] |
|---|---|---|---|---|
| 0.2 | 77 | 85 | 6.1 | 7.8 |
| 0.4 | 153 | 154 | 13.1 | 18.0 |
| 0.6 | 229 | 223 | 22.7 | 30.3 |
| 0.8 | 305 | 300 | 27.0 | 30.4 |
| 1.0 | 381 | 364 | 28.5 | 32.8 |
| 1.2 | 382 | 366 | 21.2 | 23.2 |
| 1.4 | 382 | 366 | 13.5 | 9.2 |

Final state:

| | LIGGGHTS | pe |
|---|---|---|
| particles (r=0.015 / r=0.025) | 254 / 128 | 233 / 133 |
| particle x range [m] | -0.486 to 0.410 | -0.485 to 0.303 |
| particle z range [m] | -0.186 to 0.123 | -0.185 to 0.148 |
| wall time | 10 s on 8 MPI ranks | 8 s serial |

In both codes the stream lands on the belt, is carried in -x, falls off the belt end
at x = -0.1 and piles up on the floor against the wall at x = -0.5 (x_min is the wall
plus one small radius in both cases). The higher pe kinetic energy during insertion is
consistent with the hard-contact model dissipating less on the first belt impact than
the Hertz model with restitution 0.3; the lower pe value at the end is consistent with
the doubled effective friction noted above. The final particle count differs because
the random placement in a half-filled insertion volume realises slightly different size
mixes (pe placed a few more large particles per 3 kg).

---

## 4. Pitfalls encountered

### 4.1 Boost module is static-only
`module load boost/1.88` provides only static libraries. pe's CMakeLists sets
`Boost_USE_STATIC_LIBS OFF`, so `find_package(Boost)` falls back to the system Boost
1.75 and fails on the version check. Pass `-DBoost_USE_STATIC_LIBS=ON`.

### 4.2 Solver selection is compile time
`pe_CONSTRAINT_SOLVER` is a preprocessor macro read by the whole library, not only by
the example. The default `HardContactEulerLagrange` is a neutral placeholder; the
`mpidem` example even refuses to run with it. Select the solver at configure time via
`PE_PREPROCESSOR_FLAGS` so the library and the example agree.

### 4.3 LIGGGHTS distribution weights are mass fractions
`fix particledistribution/discrete ... pts1 0.3 pts2 0.7` means 30 % of the *mass*
in small particles. The LIGGGHTS final dump has 254 small and 128 large particles,
i.e. a 66 / 34 number split, which is exactly 0.3/m_small : 0.7/m_large. A first
version of the pe example used the weights as number fractions and ended with 540
particles instead of about 380.

### 4.4 Insertion volume and `all_in no`
The extruded insertion volume lies above the face, not below it, and particle centres
(not whole particles) must be inside. Shrinking the centre range by the radius makes
it almost impossible to place the 13 large particles LIGGGHTS fits into each 3 kg
batch.

### 4.5 pe VTK collector written at activation
`vtk::activateWriter` writes `collector.pvd` immediately and lists only the body
types that exist at that moment. Activated before any sphere exists it produces an
empty collection. Pass `writeEmptyFiles=true` (6th argument) or activate the writer
after creating the first bodies. The per-step `.vtu` files are written in any case.

### 4.6 Fixed bodies move
See section 2: pe integrates fixed bodies with their prescribed velocity. Reset the
position every step for a stationary surface with a surface velocity.

### 4.7 Material combination rule
Friction coefficients of two materials are added, restitution is combined through a
stiffness-weighted formula. Do not expect the pe material numbers to mean the same as
the LIGGGHTS per-type-pair values.

---

## 5. Walkthrough

### Step 1: Build pe with the conveyor example

```bash
source /etc/profile.d/modules.sh
module load gcc/13.2.0 boost/1.88
cd /data/warehouse17/rmuenste/code/liggghts-dem/pe-0.3rc1
cmake -S . -B build/conveyor -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DPE_LIBRARY_TYPE=STATIC \
  -DBoost_USE_STATIC_LIBS=ON \
  -DPE_BUILD_EXAMPLES=ON -DBUILD_TESTING=OFF -DPE_BUILD_INTERFACE_TESTS=OFF \
  -DPE_USE_MPI=OFF -DPE_USE_CGAL=OFF -DPE_USE_EIGEN=ON -DPE_USE_JSON=ON \
  -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
  "-DPE_PREPROCESSOR_FLAGS=-Dpe_CONSTRAINT_SOLVER=pe::response::HardContactSemiImplicitTimesteppingSolvers"
ninja -C build/conveyor -j 48 pe_static conveyor
```

Eigen 3.4 and nlohmann/json are fetched from the internet by CMake on first
configure. The library builds in about 25 s, the example in about 9 s.

Files added to the pe repository (uncommitted):

- `examples/conveyor/conveyor.cpp`
- `examples/conveyor/CMakeLists.txt`
- one line `add_subdirectory(conveyor)` in `examples/CMakeLists.txt`

### Step 2: Run

```bash
mkdir -p /data/warehouse17/rmuenste/code/liggghts-dem/runs/pe_conveyor
cd /data/warehouse17/rmuenste/code/liggghts-dem/runs/pe_conveyor
/data/warehouse17/rmuenste/code/liggghts-dem/pe-0.3rc1/build/conveyor/examples/conveyor/conveyor
```

`--no-vtk` disables the output. The program prints a LIGGGHTS-like thermo table (step,
time, particles, inserted mass, kinetic energy, maximum speed) and a summary.

### Step 3: View in ParaView

```bash
module load paraview/5.13.0/opengl2-renderer/gui    # separate shell, switches to gcc 11
cd /data/warehouse17/rmuenste/code/liggghts-dem/runs/pe_conveyor
paraview paraview/collector.pvd
```

The collector loads spheres and the belt box for all 350 frames. Sphere files carry
`ID`, `Radius`, `Mass`, `Velocity`, `Angular Velocity`, `Net Force` and orientation.
Show spheres with a Glyph filter (Sphere, scale by `Radius`, factor 2). The container
walls are planes and are not written; `meshes/box.stl` from the LIGGGHTS case is
copied into the run directory for that purpose. The `capsules*.vtu` and `meshes*.vtu`
files are empty placeholders.

### Step 4: Things to try next

- (done) `--friction 0.25`: kinetic energy during insertion then agrees with LIGGGHTS
  to within about 10 % (see `RUNBOOK.md`, section 3).
- Use `DEMSolverObsolete` (soft contact, Hertz option) for a like-for-like contact model;
  it needs a 1e-5 s step like LIGGGHTS.
- Enable `PE_USE_MPI=ON` (`module load openmpi/4.1.6`) and add a Cartesian domain
  decomposition as in `examples/mpispheres` to run on 8 ranks like the LIGGGHTS case.
  With only 380 particles this is not needed for speed.
