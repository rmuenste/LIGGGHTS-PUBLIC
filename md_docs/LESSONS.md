# Lessons learned: LIGGGHTS, and LIGGGHTS versus pe

Condensed findings from building LIGGGHTS-PUBLIC 3.8.0 on this cluster, running seven of its
tutorials, and porting them to the pe rigid-body engine. The evidence (run numbers, tables,
wall times) is in `RUNBOOK.md`. Section references below point there.

Related documents:
- `BUILD_NOTES.md`: compile walkthrough for LIGGGHTS and VTK.
- `PE_CONVEYOR.md`: the conveyor port in detail.
- `RUNBOOK.md`: run log, pe quirks (6), case-by-case comparisons (9), what pe is missing (10).

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
- The time step must be a small fraction of the Rayleigh/Hertz time (1e-5 s in the tutorials,
  against 5e-4 s in pe). The tutorials afford this with a Young's modulus of 5e6 Pa, orders
  of magnitude softer than real materials.
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
That is why pe's MPI support is hand-wired per example and why the ports ran serially.

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
