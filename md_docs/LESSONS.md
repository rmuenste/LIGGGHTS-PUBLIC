# Lessons learned: LIGGGHTS, and LIGGGHTS versus pe

Condensed findings from building LIGGGHTS-PUBLIC 3.8.0 on this cluster, running seven of its
tutorials, and porting them to the pe rigid-body engine. The evidence (run numbers, tables,
wall times) is in `RUNBOOK.md`. Section references below point there.

Related documents:
- `BUILD_NOTES.md`: compile walkthrough for LIGGGHTS and VTK.
- `PE_CONVEYOR.md`: the conveyor port in detail.
- `RUNBOOK.md`: run log, pe quirks (6), case-by-case comparisons (9), what pe is missing (10).
- `CFDEM_SURVEY.md`: survey of CFDEMcoupling-PUBLIC (LIGGGHTS + OpenFOAM) for pe and FeatFloWer.

---

## Part A: LIGGGHTS

### A.1 Building on this cluster

- Builds cleanly with `module load gcc/13.2.0 openmpi/4.1.6` (gcc first) and `make auto` in
  `src/`, configured through `src/MAKE/Makefile.user`. Binary: `src/lmp_auto`.
- **VTK is effectively mandatory.** All 22 tutorial inputs write `dump custom/vtk`; a binary
  without VTK only runs the `packing` smoke test.
- The ParaView modules bundle VTK but force gcc 11, so VTK 9.3.1 was built separately (no
  rendering, MPI on) into `../vtk/install`. `Makefile.user` needs `VTK_APPENDIX_USR=9.3`.
- gcc 13 provides `std::beta`, so the superquadric code needs no Boost.
- `source env.sh` before every run; without it `lmp_auto` does not find the VTK libraries.

### A.2 Input semantics that are easy to misread

- **`particledistribution/discrete` weights are mass fractions**, not number fractions (the
  `/numberbased` variant is for the latter). The conveyor's 254 : 128 small/large split is
  exactly 0.3/m_small : 0.7/m_large.
- **`insert/stream` mechanics** (read off the dumps; the manual does not spell this out):
  1. the insertion face is extruded along its normal, on the side opposite to the velocity;
  2. fresh particles glide kinematically with only the normal velocity component, without
     gravity or contacts, until they cross the face;
  3. only then are they released with the full velocity.
  Releasing immediately makes a port 45 % too energetic (RUNBOOK 9.1).
- **`all_in no`** (default): only the particle centre must lie inside the insertion volume.
- Insertion interval = `extrude_length / |vel|`; mass per insertion = `massrate` x interval;
  insertion stops when `mass` is reached.
- **`maxattempt` is per particle with its radius already chosen.** Re-drawing the radius on
  each failed attempt biases the mix towards small particles.
- **Multisphere mass is a Monte-Carlo volume integral** and handles overlapping members
  correctly (0.0460 kg for the stone tutorial). This was the target for the pe union fix.

### A.3 Physics and numerics

- Soft contacts: Hertz or Hooke springs, dashpots, tangential history springs, with optional
  cohesion (SJKR), plastic hysteresis and rolling friction. Restitution is an input that the
  dashpot reproduces.
- The time step must be a small fraction of the Rayleigh/Hertz time (1e-5 s in most tutorials,
  5e-5 s in the mesh cases, against 1e-4 to 5e-4 s in pe). The tutorials afford this with a
  Young's modulus of 5e6 Pa, orders of magnitude softer than real materials. Details in B.10.
- Contact models change results visibly: on identical insertion the bed height (z95 %) was
  12.4 mm with cohesion, 4.4 mm without, 3.9 mm with plastic hysteresis (RUNBOOK 9.3).
- **Beds settle slowly and never become completely still.** Energy rings through the spring
  network and is removed only by the dashpots; 1e-3 to 1e-5 J remained at times when pe was
  already at rest. The final resting geometry was nevertheless the same as in pe.

### A.4 Parallelism

- Automatic spatial domain decomposition with ghost particles.
- Contact forces are explicit functions of the current state. With `newton off` both ranks
  evaluate a boundary pair and each applies the force only to its own particle; with
  `newton on` the ghost forces are sent back by reverse communication. No unknowns are
  shared between ranks, so nothing needs to be solved across domains.
- This is what makes it fast: 9 s on 8 ranks for newModels, 9 to 19 s for the mesh cases.

### A.5 Rough edges found

- `contactModels/in.oldModels` fails with `Invalid pair style`: the legacy style was removed.
- `multisphere_stone_restitution` only runs on one rank (`processors 1 1 1`).
- Mesh walls are open STL surfaces. LIGGGHTS handles them fine (including moving meshes, wall
  stress and wear); for pe they had to be converted to closed OBJ meshes (`stl2obj_pe.py`).

---

## Part B: what the comparison with pe taught us

### B.1 Where the two codes agree, and where they cannot

| Regime | Agreement | Evidence |
|---|---|---|
| Free fall, insertion, dilute flow | within 1 to 2 % in kinetic energy | insert_stream (9.1), multisphere free fall (9.4) |
| Final static state (bed height, pile location) | within 3 %, or one particle diameter | newModels, noCohesion, meshGran (9.2, 9.3, 9.5) |
| Kinematic walls (belt, bucket) | same trajectory | conveyor (3), movingMeshGran (9.6) |
| Impact and settling transients | differ by factors 2 to 100 | 9.2, 9.4, 9.6 |
| Cohesive or plastic beds | not reproducible in pe | 9.3, RUNBOOK 10 |

The dividing line is the contact model, not geometry or integration: whenever contacts are
rare or the system is at rest, both codes give the same answer.

### B.2 The contact model dominates the transients

- pe's hard-contact solver ignores restitution; every contact is fully inelastic in the
  normal direction. pe beds therefore come to rest 2 to 3 times faster.
- The only "bounce" in pe comes from the Baumgarte penetration correction, which acts as an
  artificial coefficient of restitution of about erp (quirk 6.20). The default erp 0.7 is far
  too bouncy for granular impacts. At erp 0.5 the inelastic contact seemed to retain more
  energy (6 %) than LIGGGHTS' elastic-dissipative one (2.3 %); at erp 0.05 it retains 1 %.
- **Methodological rule:** run pe at two erp values. If the result changes, the case is
  impact-dominated and erp must be small (0.05 is the reference here) before comparing.

### B.3 Geometry and mass must match exactly before the physics can be compared

- With summed union masses the multisphere stone was 1.6 times too heavy, and everything
  downstream was off by the same factor. After the Monte-Carlo mass fix the free fall agreed to
  2 %. Mapping errors look like physics differences until they are removed.
- The same applies to insertion: different packing algorithms put 1191 instead of 1275
  particles into the movingMeshGran box, which alone shifts energies during scooping.
- Starting pe from a LIGGGHTS dump state (multisphere, step 200) removes insertion differences
  entirely and isolates the contact model; this is the cleanest comparison set-up found.

### B.4 Cost models are opposite

- LIGGGHTS: cost is proportional to particles x steps and is the same whether the bed moves
  or rests; steps are small and stiff.
- pe: steps are 10 to 50 times larger, but each step's cost grows with the density and depth
  of the contact network. In dilute cases pe is competitive (insert_stream: 3 s serial against
  5.5 s on 8 ranks); in dense beds it is slow (newModels: 5.6 min serial against 9 s on
  8 ranks, about 5 times more core time; the mesh cases 2 to 2.5 times more core time).

### B.5 Parallelism is easy for soft contacts and hard for hard contacts

Explicit soft-contact forces need only ghost data, so LIGGGHTS parallelises automatically. pe's
contact impulses are coupled unknowns of a global complementarity problem; a body touching two
subdomains receives impulses from both, which must be iterated to consistency across ranks.
That is why pe's MPI support is hand-wired per example and why the ports ran serially
(`conveyor` and `cylinder_pack` have since been made MPI-capable, pe commit `fd4a1a4`). The two
domain decompositions are compared in detail in B.8.

### B.6 Stacking: same answer, different pain

Both codes reach the same static piles. Soft contacts need stiff springs, small steps and
damping to hold a stack, settle slowly and never stop moving completely. Hard contacts hold a
stack without overlap and come exactly to rest, but pay with relaxation iterations that grow
with stack height and with an indeterminate, ordering-dependent force network. For
quasi-static piles the hard-contact model is the more natural one; for flowing, inserting and
colliding phases the explicit soft-contact scheme is cheaper and trivially parallel.

### B.7 The infrastructure gap is larger than the physics gap

Most porting effort went into things LIGGGHTS provides out of the box: insertion
(`insert/stream`, `insert/pack`, distributions), open STL walls, moving meshes, thermo output,
energy diagnostics. pe's physics was adequate for frictional, non-cohesive cases; what is
missing to make it a DEM tool comparable to LIGGGHTS is listed in RUNBOOK section 10
(restitution, cohesion, history-dependent contacts, insertion module, mesh BVH, diagnostics).

### B.8 Domain decomposition compared

Both codes decompose space, give each body to the process that contains its centre and keep
copies of nearby bodies from neighbouring processes (LIGGGHTS: ghost atoms, pe: shadow copies).
The bookkeeping is comparable; what has to be communicated per step is not. Read from the code
on 2026-10-09 (LIGGGHTS `3d5c00f2`, pe `807f656`); paths below are relative to `src/` for
LIGGGHTS and to the pe root for pe.

| | LIGGGHTS-PUBLIC 3.8 | pe |
|---|---|---|
| Subdomains | Automatic regular brick from `processors Px Py Pz`; the factorisation with the smallest surface is chosen (`procmap.cpp:868`); splits are always uniform (`comm.cpp:340`) | Hand-defined: `defineLocalDomain(...)` with an intersection or union of half-spaces, `connect(rank, geometry, offset)` per neighbour. Helpers: `RectilinearGrid` (non-uniform), `pe/interface/decompose.h`, `decomposeSlabs()` in `liggghts_common.h` |
| Neighbours | 6, from `MPI_Cart_shift`; edge and corner ghosts arrive by forwarding through the x, y, z swaps in order | Explicit graph; every process that can share a body must be connected directly (26 for a 3-D grid) |
| Ghost criterion | Distance: within cutoff + skin of the subdomain face; the granular variant adds each particle's own radius (`comm_I.h:66`) | Shape: the body's geometry intersects the remote domain inflated by `contactThreshold` (`Process::intersectsWith`); works unchanged for boxes, capsules, unions, meshes |
| Ghost and migration update | Only on reneighbour steps (an atom moved more than skin/2); other steps forward positions and velocities only (`verlet.cpp:299-330`) | Every step in `synchronize()`: update, copy or removal notification per body and connected neighbour |
| Migration limit | An atom that moves more than one subdomain between reneighbours is lost (`comm.cpp:888`) | Only to connected neighbours, so effectively the same limit |
| Contact across a boundary | Computed on both processes with `newton off`, which tangential history requires (`pair_gran.cpp:260`); each applies the force to its own particle only (`pair_gran_base.h:427`). No reverse communication of forces | Resolved once, by the owner of the contact point (`HardContactSemiImplicitTimesteppingSolvers.h` around line 1812); the other body gets the impulse through velocity-correction messages |
| Messages per step | One forward communication (6 point-to-point pairs) plus mesh updates | One `synchronize()`, then two neighbour exchanges per relaxation iteration in `synchronizeVelocities()` (corrections to the owner, updated velocities back), plus an `MPI_Allreduce` per iteration if non-fixed global bodies exist. About 200 exchanges per step at the default 100 iterations |
| Contact history | Per atom, keyed by the partner's global tag, migrates with the atom (`fix_contact_history.cpp`); each side of a boundary contact keeps its own copy | None to migrate (no tangential springs in the hard-contact model) |
| Walls | Mesh triangles distributed: owned by the process containing the centroid, ghost triangles near the faces (`multi_node_mesh_parallel_I.h`); wall contacts computed on the particle owner. `mesh/surface/planar` is not split | Large static geometry is usually global (`pe_GLOBAL_SECTION`) and replicated on every process; global-global contacts on root only, global-remote contacts rejected. A non-global `TriangleMesh` is shadow-copied whole |
| Clumps | Parallel multisphere code exists (`multisphere_parallel.cpp`), but the PUBLIC tutorial states serial only (`processors 1 1 1`); no rank check in the code | A `Union` is one body; migrates and is copied as a whole |
| Periodicity | Ghost coordinates shifted by the box length during the swaps | `offset` vector in `connect(...)` |
| Load balancing | None (no `balance`, `fix balance`, RCB or tiled communication in this version) | None |

What follows from this:

- **pe's machinery is more general, LIGGGHTS' more automatic.** pe can describe any convex
  subdomain, which is what allows it to follow a FeatFloWer partition, and its shape-based
  ghost test needs no special handling for non-spherical bodies. LIGGGHTS only does uniform
  bricks and handles clumps by enlarging the ghost cutoff, but needs no setup code and skips
  the ghost rebuild on most steps thanks to the skin.
- **The cost difference is the solver, not the decomposition.** A soft-contact force depends
  only on the current state, so one halo exchange per step suffices and computing boundary
  contacts twice is cheaper than sending forces back. pe's impulses are coupled: within a
  process the relaxation is Gauss-Seidel, across processes the boundary bodies are exchanged
  once per sweep and damped by `relaxationParam_` (0.9). The convergence check is compiled out
  (`#if 0` around line 2096), so all 100 sweeps always run.
- **pe results depend on the decomposition.** The partitioned sweep combines boundary updates
  differently for each partition, so trajectories change with the process count (commit
  `fd4a1a4` reports kinetic energies within 10 % on 1, 2 and 4 processes). LIGGGHTS differs
  only by floating-point summation order.
- **Walls scale differently.** LIGGGHTS distributes a large wall mesh; pe replicates global
  geometry on every process, which is fine for planes and a belt box but not for a large mesh.
- **Cheapest improvements on the pe side:** re-enable the convergence check with a reduction
  every few sweeps rather than every sweep, and exchange boundary velocities only every k
  sweeps (only bodies with shadow copies are sent already, so the gain is in fewer message
  rounds, not smaller messages).

### B.9 Lubrication and liquid films

LIGGGHTS-PUBLIC has no lubrication model for fully immersed particles: the LAMMPS FLD package
(`pair lubricate`) is not included, only a leftover comment in `src/pair.cpp:1357` mentions it.
What it has is a lubrication-type viscous force inside two liquid-bridge cohesion models for
wet granular material in air (the pendular regime), used as `cohesion <model>` in `pair gran`
(`src/cohesion_model_{easo,washino}_capillary_viscous.h`, `doc/gran_cohesion_*.txt`):

- Each particle carries a surface liquid content; liquid is redistributed between the two
  particles when a bridge ruptures (scalar transport fix `liquidtransfer`).
- While a bridge exists the pair feels a capillary force (Soulie 2006, depends on bridge volume,
  contact angle and gap) and a viscous force (Nase, cited by Shi and McCarthy 2008): normal
  `6 pi mu R_eff^2 v_n / h`, tangential `6 pi mu R_eff v_t (8/15 ln(R_eff/h) + 0.9588)`. The
  gap has a floor of `minSeparationDistanceRatio * R_eff`, which is also the value used while
  the particles overlap. Both forces are explicit.
- `easo/capillary/viscous` forms the bridge only on contact (without one, `surfacesClose`
  returns early), so approaching particles feel no squeeze-film damping, only separating ones
  until rupture at `(1 + theta/2) V_bond^(1/3)` (Lian). Walls are dry only.
  `washino/capillary/viscous` forms and ruptures the bridge at the same distance, so approaches
  inside the rupture distance are damped too.

The CFD coupling does not add lubrication either. `fix couple/cfd/force` pushes positions,
velocities, radii (and optional shape data) and pulls only `dragforce` and `hdtorque`
(`src/fix_cfd_coupling_force.cpp:362-381`); all fluid forces are computed in CFDEMcoupling from
the volume-averaged field. The public CFDEMcoupling (github.com/CFDEMproject/CFDEMcoupling-PUBLIC,
`cfdem-3.8.1` for LIGGGHTS 3.8.0 and OpenFOAM 6, last pushed 2025-07-03, README says no further
updates are planned) has these force models: Archimedes, ArchimedesIB, DiFeliceDrag,
GidaspowDrag, KochHillDrag, LaEuScalarTemp, MeiLift, SchillerNaumannDrag, ShirgaonkarIB,
gradPForce, viscForce, virtualMassForce and some bookkeeping models; none is a pairwise
lubrication force. Short-range squeeze films between immersed particles, which an unresolved
CFD mesh cannot see, are therefore not modelled in the public LIGGGHTS/CFDEM chain.

| | LIGGGHTS capillary/viscous | pe `LubricationStage` |
|---|---|---|
| Physical setting | Wet granular in air, pendular liquid bridges | Particles fully immersed in fluid, coupled to CFD |
| Model | Capillary force + leading-order Reynolds normal term + log tangential term | Kroupa et al. 2016: normal squeeze with `1/eps`, `ln eps`, `eps ln eps` terms, sliding force and torque |
| Active | While a bridge exists (Easo: only after contact) | Every pair below the cutoff, including on approach |
| Near contact | Gap floor at a minimum separation | Vinogradova slip above `h_c`, force frozen below |
| CFD awareness | None | Cutoff can be clamped to the CFD cell size (`lubricationMeshClampFactor_`) |
| Integration | Explicit force (the 1/h damping tightens the time step) | Semi-implicit normal mode, stable at CFD time steps |
| Capillary force, liquid transport | Yes | No |

The two codes cover different physics: pe is ahead for suspension lubrication, LIGGGHTS has the
wet-granular cohesion pe lacks (it belongs with the missing cohesion models in RUNBOOK section 10).

### B.10 Time step limits

LIGGGHTS generally needs a much smaller step than pe, because the two limits have different
origins.

**LIGGGHTS (soft contacts, explicit integration).** The step must resolve the compression and
recovery of the contact spring. Common rules: a fraction (about 10 to 20 %) of the Rayleigh
time `pi R sqrt(rho/G) / (0.1631 nu + 0.8766)`, or about 1/50 of the Hertz contact duration.
Both shrink with stiffness. Computed for the small conveyor sphere (r 15 mm, rho 2500,
nu 0.45):

| Young's modulus | Rayleigh time | Hertz contact time, sphere-sphere at 2 m/s | Resulting step |
|---|---|---|---|
| 5e6 Pa (tutorials) | 1.9e-3 s | 3.3e-3 s | about 7e-5 to 2e-4 s |
| 7e10 Pa (glass-like) | 1.6e-5 s | 7e-5 s | about 1e-6 to 3e-6 s |

The tutorials soften the material by roughly four orders of magnitude to keep the step
affordable, and the conveyor's 1e-5 s is still conservative (0.5 % of the Rayleigh time, RUNBOOK
run 3). The explicit viscous liquid-bridge force of B.9 adds another limit at small gaps.

**pe (hard contacts).** Stiffness does not enter. The limits are geometric:

- Displacement per step must stay well below the particle size and the contact threshold, or
  contacts are detected late or missed. Conveyor at 5e-4 s: 4.5 m/s x 5e-4 s = 2.25 mm, about
  15 % of the small radius.
- Penetration per step is about `v dt`, and the error reduction turns it into a rebound of about
  `erp` (quirk 6.20). Larger steps mean larger overlaps and larger artefacts; the split-impulse
  option (pe commit `100a3e4`) removes the velocity kick of the correction itself.
- Impacts are instantaneous, so a smaller step only improves temporal resolution; there is no
  stiffness instability.

Steps used in the ports:

| case | LIGGGHTS step | pe step | ratio |
|---|---|---|---|
| conveyor | 1e-5 | 5e-4 | 50 |
| insert_stream | 1e-5 | 2.5e-4 | 25 |
| newModels, noCohesion (cylinder_pack) | 1e-5 | 1e-4 | 10 |
| multisphere | 1e-5 (E 1e7) | 1e-4 | 10 |
| meshGran | 5e-5 | 1e-4 | 2 |
| movingMeshGran | 5e-5 | 5e-4 | 10 |

With realistic stiffness the LIGGGHTS steps would shrink by a factor of about 100 while the pe
steps stay as they are.

A larger step does not make pe faster by itself: each step runs 100 relaxation sweeps over the
contact network (and two neighbour exchanges per sweep under MPI, B.8), so dense beds still cost
about 5 times more core time (B.4). pe wins for stiff materials in dilute or long-lasting
contacts (belt transport, slow shear); LIGGGHTS wins for many contacts per particle with an
affordable softened material. The soft-contact `DEMSolverObsolete` in pe has the same stiffness
limit as LIGGGHTS (about 1e-5 s for the tutorials). The large hard-contact step is paid for in
fidelity: restitution, contact duration and wave propagation through a packing are not
resolved, which is where the two codes disagree (B.1, B.2).
