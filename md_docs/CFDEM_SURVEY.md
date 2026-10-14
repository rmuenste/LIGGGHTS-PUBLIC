# CFDEMcoupling-PUBLIC: survey for pe and FeatFloWer

Date: 2026-10-09
Source: CFDEMcoupling-PUBLIC `cfdem-3.8.1`, commit `abedb07` (2025-07-03), cloned to
`CFDEMcoupling-PUBLIC/` next to `LIGGGHTS-PUBLIC/` and `pe-0.3rc1/`
Coupled codes: LIGGGHTS 3.8.0 (this repository), OpenFOAM-6 commit `af7d7f4` (`OpenFOAM-6/`)

Sections 1 to 10 were written as a read-only survey (2026-10-09). The stack has since been built
and the `twoSpheresGlowinskiMPI` tutorial run on the workstation and on the cluster
(`CFDEM_BUILD_NOTES.md`, RUNBOOK runs 31 and 32); sections 11 to 13 use those results.
Marks: **[V]** verified in the code, **[I]** inferred.
Path shorthands: `cP/` = `src/lagrangian/cfdemParticle/`, `sM/` = `cP/subModels/` (both in the
CFDEMcoupling repository), `L/` = `LIGGGHTS-PUBLIC/src/`.

Related documents:
- `LESSONS.md`: LIGGGHTS versus pe, including domain decomposition (B.8), lubrication (B.9) and
  time steps (B.10).
- pe side: `pe-0.3rc1/doc/technical-notes/pe-interface-serial-mode.md`,
  `euler-lagrange-solver-conventions.md`, `lubrication-contacts.md`.

---

## 1. Summary

CFDEMcoupling couples OpenFOAM (finite volume) with LIGGGHTS (soft-contact DEM). It offers
unresolved coupling (volume-averaged Navier-Stokes with drag closures, particles smaller than
cells) and a resolved immersed-boundary variant. It is a frozen public release: the README states
it "will not be updated in the foreseeable future", it is pinned to OpenFOAM-6, and active
development continues in the commercial DCS products.

For pe and FeatFloWer the main findings are:

- The parallel data exchange is the same pattern as pe `PE_SERIAL_MODE` with FeatFloWer
  `COMM_SUMMN`: global particle arrays summed with `MPI_Allreduce` on every rank (section 4).
- Implicit drag on both sides (section 3) is already present in pe + FeatFloWer; what
  FeatFloWer lacks is the volume-averaged fluid operator (section 12).
- The resolved IB solver is a non-iterative first-order splitting; FeatFloWer's fictitious
  boundary method should be more accurate (section 6).
- There is no lubrication or other short-range hydrodynamic pair force anywhere (section 7).
- Three tutorials are natural benchmark twins for pe and FeatFloWer (section 8).
- Resolved-particle classification (section 13, pe `1f60291`): pe + FeatFloWer handle six shape
  types, own overlaps deterministically and are tested in CI; CFDEM IB handles spheres only and
  blends overlapping cells in loop order, but its seed-and-flood search scales with coverage.

---

## 2. Architecture

`cfdemCloud` (`cP/cfdemCloud/cfdemCloud.C`) creates every model through OpenFOAM run-time
selection (`::New`, lines 169-251, 360-399) **[V]**.

| model family | job | implementations |
|---|---|---|
| dataExchangeModel | move data between CFD and DEM, run the DEM | twoWayMPI, twoWayFiles, oneWayVTK, noDataExchange |
| forceModel | fluid force per particle | 17 models (section 7), plus `forceSubModel` ImEx for implicit/explicit/DEM-side switches (`sM/forceModel/forceSubModels/forceSubModel/forceSubModel.C:130-162`) |
| locateModel | cell containing each particle | standardSearch (`mesh.findCell`), engineSearch (`meshSearch`, optional octree), engineSearchIB (extra surface points) |
| voidFractionModel | particles to Eulerian volume fraction alpha | centre, divided, bigParticle, Gauss, trilinear, IB, noVoidFraction |
| averagingModel | particle quantities to cells (Us) | dense (weighted), dilute (one particle per cell) |
| momCoupleModel | fluid-side momentum source | implicitCouple (Ksl), explicitCouple, noCouple |
| smoothingModel | diffuse coupling fields | constDiffSmoothing, noSmoothing |
| meshMotionModel | | noMeshMotion only |
| liggghtsCommandModel | inject commands into LIGGGHTS | runLiggghts, execute, readLiggghtsData, writeLiggghts, setDEMGravity |
| clock, probe, IO, registry | timing, per-particle debug output, output formats | standardClock/noClock, particleProbe, basic/soph/trackIO, defaultRegistry |

Solvers in `applications/solvers/`: `cfdemSolverPiso`, `cfdemSolverPisoScalar` (temperature),
`cfdemSolverPisoSTM` (scalar transport), `cfdemSolverIB` (resolved). There is no compressible
solver, no region model and no `turboEngine` locate model in the public version (the latter is
only named in a warning, `sM/forceModel/checkCouplingInterval/checkCouplingInterval.C:454`) **[V]**.

---

## 3. Coupling loop and time stepping

**Time steps [V].**
- Coupling time = `couplingInterval * DEMts` (`dataExchangeModel.H:211`); `DEMts` is read from
  LIGGGHTS (`twoWayMPI.C:82`). The CFD side overrides LIGGGHTS `couple_every`
  (`L/fix_cfd_coupling.cpp:114`).
- `checkTSsize` (`dataExchangeModel.H:221-241`) aborts if the CFD step exceeds the coupling time
  or if the coupling time is not a multiple of the CFD step. The CFD may sub-step within a
  coupling interval; the CFD step must be fixed (`cfdemCloud.C:740-743`).

**Order of operations in `cfdemCloud::evolve`** (`cfdemCloud.C:660-810`), called before the flow
solve (`cfdemSolverPiso.C:100`) **[V]**:

1. `couple(0)` runs LIGGGHTS for `couplingInterval` steps (`run N pre no post no`,
   `runLiggghts.C:122`; `twoWayMPI.C:215-345`) with the forces of the previous exchange. The
   DEM runs ahead of the fluid.
2. Pull positions, velocities, radii (`getDEMdata`, :699); locate (:706); void fraction (:713);
   averages (:719); optional smoothing (:723-730).
3. Forces from the current (old) fluid fields (`setForces`, :770), deposited to cells (:779),
   pushed to the DEM (`giveDEMdata`, :786).
4. Flow solve.

Between exchanges alpha, Us and Ksl are interpolated linearly in time from Prev/Next pairs using
`timeStepFraction` (`dataExchangeModel.C:263`, `implicitCouple.C:175`) **[V]**.

**Implicit momentum coupling [V].**
- Fluid side: `Ksl = |F_imp| / |U - Us| / V_cell`, capped by `KslLimit`
  (`sM/momCoupleModel/implicitCouple/implicitCouple.C:146-161`); the momentum equation gets
  `-fvm::Sp(Ksl/rho, U) + Ksl/rho Us` (`cfdemSolverPiso.C:132,146`), the flux `rUAf Ksl/rho phis`
  (:176).
- Particle side: with `implForceDEM` CFDEM sends `Ksl` and the fluid velocity `uf` per particle
  (`forceSubModel.C:220ff`), and `fix couple/cfd/force/implicit` evaluates
  `F = Ksl (uf - v_p)` at every DEM sub-step with the current particle velocity, optionally
  Crank-Nicolson (`L/fix_cfd_coupling_force_implicit.cpp:249-280`). Plain `couple/cfd/force`
  holds a constant `dragforce` over all sub-steps (`L/fix_cfd_coupling_force.cpp:415-436`).
- No public solver uses `explicitCouple`; all read `implicitCouple_index`
  (`cfdemSolverPiso.C:107`).
- `modelType` A, B, Bfull are the volume-averaged Navier-Stokes forms of Zhou et al. (2010);
  `cP/cfdTools/sanityChecks/level0_Solver.H` requires gradPForce and viscForce for A and Bfull
  and forbids them for B.

---

## 4. Data exchange and parallelism

- **twoWayMPI** (production): LIGGGHTS is instantiated in-process on `MPI_Comm_dup(MPI_COMM_WORLD)`
  and driven through `lmp->input->one()` (`twoWayMPI.C:71-79, 293-341`). Both codes use all
  ranks with independent decompositions; nothing has to match **[V]**.
- Exchange arrays are **global, indexed by atom tag**, of length `tag_max()` (`twoWayMPI.C:352`,
  `L/cfd_datacoupling_mpi.cpp:138,175`) **[V]**.
  - DEM to CFD (`push_mpi`): every LIGGGHTS rank writes its own atoms into a zeroed array,
    followed by `MPI_Allreduce(SUM)` over all particles (`L/cfd_datacoupling_mpi.h:273`).
  - CFD to DEM (`pull_mpi`): every CFD rank fills the particles whose cells it owns, zeros
    elsewhere, `MPI_Allreduce(SUM)` (`L/cfd_datacoupling_mpi.h:126`), and each DEM rank picks
    its atoms with `atom->map`. Partial forces of particles spanning several CFD ranks add up in
    the sum.
- Every CFD rank runs locate, void fraction and force loops over all N particles
  (`engineSearch.C:94`, `cfdemCloud::setForces`) **[V]**.
- Cost **[I]**: O(N_total) memory and Allreduce volume per field on every rank, per coupling.
  Fine for 1e5 to 1e6 particles, not for large core counts. This is structurally pe
  `PE_SERIAL_MODE` plus FeatFloWer `COMM_SUMMN` (`pe-interface-serial-mode.md`), so the pattern
  is common practice and its ceiling is known.
- twoWayFiles: ASCII files per field, written by one side and read by the other. oneWayVTK: reads
  LIGGGHTS VTK dumps, for post-processing only (`oneWayVTK.C:108-164`) **[V]**.

---

## 5. Unresolved coupling: void fraction and particles larger than cells

| model | method | notes |
|---|---|---|
| centre | whole volume in the centre cell | |
| trilinear | trilinear volume weights | |
| divided | 29 marker points (radii `cbrt(1/29)`, `cbrt(15/29)`), 1/29 of the volume each | alpha clipped at `alphaMin` (default 0.1), excess tracked in `tooMuch_` (`dividedVoidFraction.C:73,115-128,280-285`) **[V]**; spreads over at most about 3 cells per direction **[I]** |
| bigParticle | recursive flood fill from the centre cell; every cell whose centre lies inside gets `V_p / n_cells` (staircase) | docs ask for about 8 cells per diameter (`bigParticleVoidFraction.C:126,214-230`) **[V]**; `cellCells` does not cross processor boundaries, so cells on neighbour ranks are probably missed **[I]** |
| Gauss | Gaussian kernel over 3 r | marked "TODO revise" (`GaussVoidFraction.C:128,154`) **[V]** |
| IB | partial alpha from segment-sphere intersections | section 6 |

All models can enlarge the region of influence at constant volume ("porosity"/"scaleUpVol").
`constDiffSmoothing` takes an implicit diffusion step with `D = L^2/dt` and clips to
`[lowerLimit, upperLimit]` (`constDiffSmoothing.C:110-122`); all tutorials have smoothing off
**[V]**.

---

## 6. Resolved coupling (IB) and comparison with the FeatFloWer FBM

`cfdemSolverIB` per time step **[V]**:

1. `evolve`: DEM steps, locate with `engineSearchIB`, `IBVoidFraction`, forces.
2. PISO on the whole domain, ignoring the solids (`cfdemSolverIB.C:129-218`).
3. `calcVelocityCorrection` (`cP/derived/cfdemCloudIB/cfdemCloudIB.C:277-310`): set
   `U = (1 - alpha)(v_p + omega x r) + alpha U` in covered cells (:340), solve
   `lap(phiIB) = div U + d(alpha)/dt`, then `U -= grad phiIB` and `p += phiIB/dt`. The code asks
   itself "do we have to account for rho here?" at :303.

Details **[V]**:
- `IBVoidFraction` computes partial alpha from 8 vertex-centre segment-sphere intersections,
  periodic images included (`IBVoidFraction.C:139-172`).
- `engineSearchIB` adds satellite points on the particle surface so ranks that do not hold the
  centre still find the cells they cover (`engineSearchIB.C:176-248`).
- `ShirgaonkarIB`: `F = sum_cells (mu lap U - grad p) V_cell`, `T = sum (x_c - x_p) x (...) V`,
  over the particle's cells with full cell volume and no alpha weighting
  (`ShirgaonkarIB.C:124-140`, `forceSubModel.C:781-788`). Uses the previous step's fields:
  explicit and lagged.
- `ArchimedesIB`: `-g rho sum V (1 - alpha)`. Torque goes to LIGGGHTS as `hdtorque`.
- The tutorial refines with `dynamicRefineFvMesh` on the `interFace` indicator; `setInterFace`
  loops over all cells for every particle, O(N_p N_cells) (`cfdemCloudIB.C:253`).

Comparison **[I]**: CFDEM-IB is a non-iterative first-order splitting (unconstrained solve,
direct forcing, projection) with lagged volume-integral forces. FeatFloWer's FBM imposes the
rigid-body velocity as a constraint inside the FEM solve and evaluates the force as a volume
integral of `sigma . grad(alpha)`. Expect larger interface slip and noisier forces from CFDEM at
6 to 8 cells per diameter. Worth borrowing: the satellite-point ownership, AMR driven by the
interface indicator, and the explicit sum of partial forces over ranks (as in pe serial mode).

---

## 7. Force models (`sM/forceModel/`) [V]

| model | formula / reference |
|---|---|
| DiFeliceDrag | `Cd = (0.63 + 4.8/sqrt(Re))^2`, `beta ~ 0.125 Cd rho pi d^2 alpha^(2-chi) |Ur|`, `Re = d alpha |Ur| / nu` (:251-267) |
| KochHillDrag | Koch-Hill/Beetstra F0 (branches phi < 0.4 and >= 0.4) and F3, `F = alpha (F0 + 0.5 F3 Re)`, `beta = 18 nu rho alpha F / d^2` (:222-249) |
| GidaspowDrag | Wen-Yu `24/Re (1 + 0.15 Re^0.687) alpha^-2.65` for alpha > 0.8, else Ergun `150 phi nu rho / ...` (:222-234) |
| SchillerNaumannDrag | `Cd = max(0.44, 24/Re (1 + 0.15 Re^0.687))`, no voidage dependence (:201-207) |
| gradPForce | `-V_s grad p (1 + C_add)` (:184) |
| viscForce | `-V_s div tau` (:164) |
| virtualMassForce | `C_add rho V_s D(Ur)/Dt` (:227) |
| MeiLift | Saffman-Mei/McLaughlin `J*` (:203-231) |
| Archimedes | `-g rho V_s`, applied on the CFD side (:218) |
| ShirgaonkarIB, ArchimedesIB | section 6 |
| utilities | noDrag, LaEuScalarTemp, scalarGeneralExchange, fieldStore, fieldTimeAverage, particleCellVolume, particleVolume, volWeightedAverage, checkCouplingInterval |

Voidage sub-model switches: DiFelice, Rong, Tang.

Buoyancy is owned by the CFD side, which matches pe's `HardContactEulerLagrange` convention
(the driver owns gravity and buoyancy; `euler-lagrange-solver-conventions.md`, section 2).

**No lubrication.** A case-insensitive search for `lubric`, `squeeze`, `Brenner` and
`near-contact` over the whole repository (sources, applications, tutorials, docs) gives no hits
**[V]**. Particle-particle hydrodynamics is Hertz contact plus the drag closure. LIGGGHTS has only
the liquid-bridge models of `LESSONS.md` B.9.

---

## 8. Tutorials (`tutorials/`) [V]

| case | solver / exchange | models and checks |
|---|---|---|
| ErgunTestMPI (+ `_cgs`, `_restart`) | Piso, model A, twoWayMPI | divided, engine, dense, KochHill + gradP + visc + Archimedes, implicit; octave script checks the Ergun pressure drop |
| settlingTestMPI | Piso, model B | one particle d = 0.1 mm, rho = 3000; DiFelice + Archimedes; `settlingVelocity.m` |
| periodicChannel | Piso, model A | cyclic patches with `meanSupVelocityForce`, LIGGGHTS `p f f`, restart |
| voidfractionTest | Piso, model B | trilinear |
| packedBedTemp | PisoScalar, PisoSTM, ParScale | KochHill with heat and species exchange; Ergun and Nusselt checks |
| twoSpheresGlowinskiMPI | IB | two spheres d = 0.167, rho = 1.5, nu = 0.01 in a 1 x 1 x 4 box, 10 x 10 x 40 mesh plus AMR level 2, ShirgaonkarIB + ArchimedesIB, Hertz contact |
| fillCylinder | cfdemPostproc | oneWayVTK |

Benchmark twins for pe and FeatFloWer:

| CFDEM tutorial | what it tests | pe + FeatFloWer counterpart |
|---|---|---|
| twoSpheresGlowinskiMPI | drafting-kissing-tumbling of two spheres, resolved | resolved pe + FBM head to head; showcase for pe's lubrication, which CFDEM lacks |
| settlingTestMPI | terminal velocity of one particle | pe Euler-Lagrange settling setup |
| ErgunTestMPI | packed-bed pressure drop against Ergun | drag closure check |

---

## 9. Other notes

- Version pinning: OpenFOAM-6 commit `af7d7f4` (`cP/cfdTools/versionInfo.H`, which also names
  LIGGGHTS 3.8.0). The release notes call it a maintenance freeze and say Ubuntu 24.04 needs
  `WM_CXX_STD=c++14` **[V]**.
- Coarse graining: LIGGGHTS `force->cg()` is passed to `cfdemCloud::cg_`
  (`dataExchangeModel.H`, `setCGs`) and `forceSubModel::scaleCoeff`; type-specific coarse
  graining is commented out as untested **[V]**.
- Periodicity: `checkPeriodicCells` and `wall_periodicityCheckRange` exist only on the IB path
  (`cfdemCloud.C:129`); unresolved cases rely on OpenFOAM cyclic patches and LIGGGHTS wrapping
  **[V]**.
- Restart: LIGGGHTS restart file plus the OpenFOAM time directory, with `timeIndexOffset_`
  resetting the coupling counter. `KslPrev`/`KslNext` are `NO_WRITE` (`implicitCouple.C:127-128`),
  so the first interval after a restart loses its time-interpolation history **[I]**.
- No adaptive CFD time step (aborts, section 3) and no mesh motion.

---

## 10. Most relevant for pe

1. **Implicit drag recomputed at each DEM step** (`F = Ksl (uf - v_p)`). Already covered, in a
   stronger form: pe's `elSemiImplicitVelocity` (`pe/core/collisionsystem/ELSemiImplicitDrag.h`)
   treats the drag backward-Euler implicitly in every PE sub-step and is unconditionally stable
   (section 12).
2. **Fluid-side Ksl coupling with time interpolation.** The implicit sink is already in
   FeatFloWer (`ELDragCoupling = semi_implicit`, `B` on the Q2 velocity diagonal). The time
   interpolation is only needed when the CFD takes several steps per exchange; FeatFloWer
   exchanges every fluid step and sub-steps PE instead (section 12).
3. **Benchmark twins**: twoSpheresGlowinskiMPI, settlingTestMPI, ErgunTestMPI (section 8); the
   last two come with analytical check scripts.
4. **Particles spanning several CFD ranks**: satellite surface points in `engineSearchIB` plus
   the sum of partial forces over ranks, directly analogous to pe's handling of bodies that span
   CFD domains.
5. **Exchange pattern**: tag-indexed global arrays plus `MPI_Allreduce(SUM)`, identical in
   structure and cost to `PE_SERIAL_MODE` plus `COMM_SUMMN`.
6. **No lubrication**: pe's Kroupa-2016 lubrication stage is a genuine differentiator, best shown
   on drafting-kissing-tumbling or a dense settling suspension.

7. **Volume-averaged fluid equations.** The one coupling ingredient CFDEM has and FeatFloWer
   does not: alpha in the inertia, viscous and pressure terms and (optionally) `d(alpha)/dt` in
   continuity (section 12). Relevant for dense cases such as the Ergun twin.

## 11. Possible next steps

- (done, section 12) Diff `cfdemSolverPiso` and `cfdemSolverIB` against OpenFOAM-6 `pisoFoam`.
- Look at OpenFOAM's own `DPMFoam` / `MPPICFoam` (`src/lagrangian/intermediate`) as a third
  reference.
- (done, `CFDEM_BUILD_NOTES.md` section 6) Build CFDEM and run twoSpheresGlowinskiMPI.
- Plan the drafting-kissing-tumbling comparison: twoSpheresGlowinskiMPI against pe + FeatFloWer.
- (section 13.4) Fix the pe `tvel` bug and repeat a frictional DKT run.
- Seed-and-flood classification for FeatFloWer, following `IBVoidFraction::buildLabelHashSet`
  (roadmap item 6), keeping pe's per-DOF query as the reference.

---

## 12. Solver diff against OpenFOAM-6 `pisoFoam`, and what FeatFloWer already has

Compared: `applications/solvers/cfdemSolverPiso/cfdemSolverPiso.C` and
`applications/solvers/cfdemSolverIB/cfdemSolverIB.C` against
`OpenFOAM-6/applications/solvers/incompressible/pisoFoam/{pisoFoam.C,UEqn.H,pEqn.H}`. With
`CFDEMWMPROJECTVERSION=6`, `OFversion.H` defines `version60` and through it `version50`,
`version40` and `version30`, so the `version30` branches below are the active ones **[V]**.

### 12.1 `cfdemSolverPiso` [V]

| term | `pisoFoam` | `cfdemSolverPiso` |
|---|---|---|
| unknowns | U, phi | U is the interstitial velocity; `phi = alpha_f * phiByVoidfraction` is the superficial flux |
| inertia | `ddt(U) + div(phi, U)` | `ddt(alpha, U) - Sp(ddt(alpha), U) + div(phi, U) - Sp(div(phi), U)`, i.e. `alpha dU/dt + (alpha U).grad U` (continuity subtracted) |
| viscous | `turbulence->divDevReff(U)` | commented out; replaced by `divVoidfractionTau`: `-laplacian(alpha nuEff, U) - div(alpha nuEff dev2(grad(U)^T))` (`cfdemCloud.C:863-870`); `turbulence->correct()` still runs on the unweighted U |
| drag | none | `-Sp(Ksl/rho, U)` on the matrix (so Ksl is inside `UEqn.A()` and hence `rUA`) plus `Ksl/rho Us` in the predictor, in the flux (`rUAf Ksl/rho phiS`) and in the velocity correction |
| pressure gradient | `-grad p` | model A: `-alpha grad p`; models B, Bfull: `-grad p` |
| pressure equation | `laplacian(rAU, p) = div(phiHbyA)` | `laplacian(rUA alpha, p)` (model A: `rUA alpha^2`) `= div(alpha_f phi) + ddtVoidfraction()` |
| flux construction | `fvc::flux(HbyA)` with `constrainHbyA`, `adjustPhi`, `constrainPressure`, MRF | OpenFOAM-2.x style `interpolate(U) & Sf + ddtCorr`; no `adjustPhi`, no MRF; `constrainPressure` through `cP/cfdTools/fixedFluxPressureHandling.H` |
| time step | adaptive possible | fixed (section 3) |

`ddtVoidfraction()` is **off by default**: without `useDDTvoidfraction a|b` in
`couplingProperties` it returns zero (`cfdemCloud.C:115, 340-355, 881-901`). Option `a` uses
`div(Us (1 - alpha))`, option `b` `fvc::ddt(alpha)`. Of the tutorials only `voidfractionTest` sets
it (`b`); ErgunTestMPI and settlingTestMPI run without it. In addition `alpha.oldTime()` is set
to `alpha` for the first two coupling steps to suppress a volume source (`cfdemCloud.C:747-751`).
So by default the volume-averaged continuity `d(alpha)/dt + div(alpha U) = 0` is not enforced for
moving particles.

### 12.2 `cfdemSolverIB` [V]

- Momentum and PISO are plain `pisoFoam` in OpenFOAM-2.x style (`adjustPhi` kept): no alpha, no
  drag term. The pressure equation adds `ddtVoidfraction()`, which the IB path never computes
  (`calcDdtVoidfraction` is only called from `cfdemCloud::evolve`, and `cfdemCloudIB::evolve`
  replaces it), so the term is zero.
- `mesh.update()` refines the mesh on `interFace` before `evolve`.
- After PISO, `calcVelocityCorrection` (`cfdemCloudIB.C:277-310`) blends
  `U = (1 - alpha) u_p + alpha U` in covered cells, solves `lap(phiIB) = div U + ddt(alpha)`,
  then sets `U -= grad phiIB` and `p += phiIB/dt`.
- **The face flux `phi` is not corrected** (`calcVelocityCorrection` receives `p`, `U`, `phiIB`
  and `alpha`, not `phi`), so the next step convects with the pre-correction flux while `U` is
  the corrected field.
- The in-code question "do we have to account for rho here?" (:303) is answered by units:
  OpenFOAM's incompressible `p` is kinematic (m^2/s^2), `phiIB` has units m^2/s, so
  `phiIB/dt` is already kinematic and no `rho` is needed **[I]**.
- The particle force is computed in `evolve` from the fields at the end of the previous step,
  so it lags by one step.

### 12.3 Against FeatFloWer and pe (FeatFloWer commit `51e3f6f8`)

| ingredient | CFDEM | FeatFloWer + pe |
|---|---|---|
| particle-side drag | `F = Ksl (uf - v_p)` re-evaluated every DEM step (explicit, optional Crank-Nicolson); DEM step about 1e-5 s | `elSemiImplicitVelocity`: `u_{n+1} = (u_n + dt/m (B u_f + F_other)) / (1 + dt B/m)`, backward Euler in the drag, unconditionally stable, in every PE sub-step (`pe/core/collisionsystem/ELSemiImplicitDrag.h:51`) |
| fluid-side drag | `-Sp(Ksl/rho, U) + Ksl/rho Us`, also inside the pressure-velocity coupling | `ELDragCoupling = semi_implicit`: `theta dt B` on the fine-level Q2 velocity diagonal plus old-time defect term (`source/src_quadLS/QuadSc_def.f90:2418, 2517`; `docs/md_docs/el_semi_implicit_drag_note.md`) |
| exchange frequency | every `couplingInterval` DEM steps; the CFD may sub-step, hence the time interpolation of alpha, Us, Ksl | every fluid step; PE sub-steps (`substeps_`, 10 validated); no interpolation needed |
| void fraction in the fluid equations | model A or B in inertia, viscous and pressure terms; `d(alpha)/dt` in continuity optional and off by default | none **[V]**: the momentum RHS gets the feedback force (`EL_APPLY_FLUID_FEEDBACK_SOURCE`, `el_fields.f90:86-102`) and, semi-implicitly, `drag_B_source` on the diagonal (`QuadSc_def.f90:2418, 2517`); mass, convection, diffusion, pressure gradient and the pressure equation (`Matdef_General_LinScalar`) carry no `epsilon_f`. `deps_f_dt = (eps - eps_old)/dt` is computed (`el_transfer.f90:476`) but only written to output and restart files. `epsilon_f` enters the drag/lift closures, the momentum audits and output. The fluid solves `div u = 0` with a feedback force |
| particle to grid transfer | divided, bigParticle, trilinear, Gauss, IB | `deen_poly` or Gaussian kernel with width 2.5 d_p, Shepard renormalisation at walls, `epsilon_f >= 0.4` |
| lubrication | none | yes: `HardContactEulerLagrange::applyELLubrication` and `applyELWallLubrication` (pe `24295f5`, 2026-07-26), Kroupa 2016 pairwise with slip correction, enabled by `lubricationEnabled_`/`lubricationCutoff_`; validated in `kroupa_shear`, `kroupa_couette`, `v4_pressure_drop`. The runtime `LubricationStage` of the other two solvers is a separate implementation |

Consequences:

- Items 1 and 2 of section 10 are already implemented in pe + FeatFloWer, the particle side in a
  more robust form than CFDEM's.
- The coupling ingredient CFDEM has and FeatFloWer lacks is the volume-averaged fluid operator,
  confirmed in the assembly. FeatFloWer's `el_methods_inventory.md` described the governing model
  as volume-averaged Navier-Stokes; it was corrected on 2026-10-09 (with the other outdated
  entries: lubrication, restitution, drag-update wording, validation statuses). For the dilute
  campaigns run so far (phi up to 0.2) the effect is probably small; for a dense bed (the Ergun
  twin, model A in CFDEM) it is not.
- pe + FeatFloWer has pairwise lubrication on the E-L path; CFDEM has none.

---

## 13. Resolved-particle classification: pe `1f60291` against CFDEM IB

Added 2026-10-14. pe as pinned in FeatFloWer `feature/dns-validation` (`2bb4e5e6`, `libs/pe` at
`1f60291`, pe PRs #43 and #44 on top of `11ec5d3`). Both sides have to answer the same question
for the resolved coupling: which mesh entities lie inside which particle. In FeatFloWer the FBM
asks pe for every Q2 DOF; in CFDEM `engineSearchIB` and `IBVoidFraction` work per particle.

### 13.1 What pe PRs #43 and #44 added [V]

Paths relative to `FeatFloWer/libs/pe/` unless they name FeatFloWer.

- **Spatial index refresh** (`8ea90af`): `findContacts()` files bodies in the hash grid before
  the solver integrates their positions, so afterwards the cell assignment is one step old. The
  27-cell point query could then miss a body whose AABB minimum sits just below a cell boundary:
  its interior was classified as fluid after a motion of 0.035 % of a diameter. The update
  phase is now the public `HashGrids::refreshSpatialIndex()` (`pe/core/detection/coarse/HashGrids.h:1327`),
  called by `findContacts()` itself and exposed as `refresh_spatial_index_()`
  (`src/interface/sim_setup.cpp:116, 493`). FeatFloWer calls it after the pe step and before the
  classification (`source/src_fbm/fbm_main.f90:2037`, FeatFloWer `dc82d7fb`).
- **Overlap ownership by minimum system id** (`8ea90af`): a point inside several bodies used to get
  the first body found, which depends on traversal order; the accelerated and the exhaustive query
  disagreed on 21 of 42 sampled points inside two overlapping spheres. Both now take the minimum
  system id.
- **All owners** (`ea383df`): `pointOwners` / `pointOwnersAccelerated`
  (`src/interface/object_queries.cpp:720, 735`) return every body containing a point, ids
  ascending, with the total count separate from the filled prefix. FeatFloWer keeps the minimum id
  as the canonical owner and stores DOFs inside two or more bodies in a CSR table
  (`source/src_fbm/fbm_ownership.f90`, FeatFloWer `190a5b6a`). One shape dispatch,
  `bodyContainsPoint()` (`object_queries.cpp:546`), serves all four queries.
- **Same solid flag on both paths** (`b079b59`): the accelerated query wrote `bytes[0] + 1`
  instead of 1 (wrong from system id 2^56 on; no caller affected).
- **Tests** (`f8ae0bf`, `b23da85`, `a88c9d1`): `tests/interface/pe_fbm_query_stress.cpp`
  (25 serial stages: mono- and polydisperse, six rotated shapes before and after motion, meshes
  with and without DistanceMap, overlaps, random shapes, the adversarial construction per shape
  with and without refresh) and `pe_fbm_query_stress_mpi.cpp` (2 and 4 ranks: shadow copies, a
  body crossing the cut between steps, migration, all shapes straddling the cut). Every stage
  asserts that the grid is active. Runs in CI.
- **Layer-2 gate** (`3280e69`, `8f823c4`; FeatFloWer `66dde3db`): `src/interface/fbm_gate_probe.cpp`
  builds bodies that fill a whole cell span, so that a stale index would be detected, and
  FeatFloWer's `applications/q2p1_hashgrid_test` compares the accelerated against the exhaustive
  query on every Q2 DOF of a real partitioned mesh.

### 13.2 Comparison [V unless marked]

CFDEM paths relative to `cP/`.

| | pe + FeatFloWer | CFDEM IB |
|---|---|---|
| shapes | sphere, capsule, box, ellipsoid, cylinder, triangle mesh (with or without DistanceMap) | spheres only: `pointInParticle` returns `|x - c|^2 / r^2 - 1` (`sM/voidFractionModel/voidFractionModel/voidFractionModel.C:199-211`) |
| search | per DOF: hash-grid candidates, then `bodyContainsPoint`; index refreshed after motion | per particle: one seed cell, the centre cell via `meshSearch`, or else the first of `(zSplit-1)*xySplit + 2` = 114 surface points found on this rank (`sM/locateModel/engineSearchIB/engineSearchIB.C:68-72, 170-204`); then a recursive flood fill over `cellCells` that continues while a cell is at least partly covered (`sM/voidFractionModel/IBVoidFraction/IBVoidFraction.C:292-358`) |
| cost | O(N_DOF) per classification | O(covered cells) per particle. This is item 6 of FeatFloWer's `fbm_acceleration_roadmap.md` (seed and flood), already done in CFDEM |
| state between steps | hash grid, now refreshed | none: locate and flood fill are rebuilt each coupling step, so there is no stale-index class of error |
| particle on several ranks | each rank queries its own DOFs; shadow copies and migration tested at 2 and 4 ranks | one seed per rank; `cellCells` does not cross processor boundaries, so a piece of the particle on a rank that is not connected to the seed cell is missed **[I]** (possible for a non-convex rank domain) |
| overlapping particles | canonical owner = minimum system id, plus the multi-owner table | alpha reduced by each particle and clipped at 0 (`IBVoidFraction.C:355`); `setParticleVelocity` blends `U = (1 - alpha) u_p + alpha U` per particle in loop order (`derived/cfdemCloudIB/cfdemCloudIB.C:313-342`), so a cell inside two particles is blended twice and the last particle dominates: the order dependence pe removed in `8ea90af` |
| partial cells | per DOF (FeatFloWer: alpha from the DOF flags) | fraction from 8 centre-to-vertex segments, each weighted 0.125 (`IBVoidFraction.C:154, 330`), which assumes hexahedra |
| verification | stress tests in CI, Layer-2 gate on a real mesh | no tests of locate or void fraction; tutorials only (`etc/testTutorials.sh`) |

### 13.3 Overall standing (update of 12.3)

- **pe + FeatFloWer ahead:** non-spherical and mesh bodies in the resolved coupling; a
  classification that is tested serially and in parallel; deterministic overlap ownership;
  pairwise lubrication; backward-Euler drag on the particle side; the rigid-body velocity as a
  constraint inside the FEM solve instead of a projection step after it (section 6).
- **CFDEM ahead:** the volume-averaged fluid operator for unresolved dense beds (12.1); mesh
  refinement around the particles (`dynamicRefineFvMesh`); classification cost that scales with
  coverage. The refinement is what makes the Glowinski tutorial cheap: 4 ranks, 76 s for the full
  drafting-kissing-tumbling sequence to t = 0.35 s (`CFDEM_BUILD_NOTES.md` 6.4).
- **Same:** the exchange pattern (global arrays summed with `MPI_Allreduce`, section 4).

### 13.4 Lead from the DKT runs: contact friction [I]

FeatFloWer's DKT campaign (`docs/md_docs/dns_validation_datasheet.md`, rows `dkt_offset`,
`dkt16_offset`, `dkt_nofric_long`) found the kissing pair locked at a tilt of about 4 deg in exact
contact with pe's HCAF material `mu_s / mu_d = 0.1 / 0.05`, at D/h = 8 and 16 alike. Only the
frictionless run completed the tumble. The CFDEM tutorial uses Hertz with tangential history and
**friction coefficient 0.5** (`tutorials/cfdemSolverIB/twoSpheresGlowinskiMPI/DEM/in.liggghts_run:26`)
and tumbles: the pair rolls apart, with contact lost at t = 0.273 s. The setups differ
(dimensionless D/h = 8 on 109 ranks against the dimensional Glowinski case with soft contact),
so this is no direct comparison. Still, friction by itself does not lock a rolling pair.

A candidate on the pe side is the tangential-velocity bug in `src/core/contact/Contact.cpp:83, 148`:
`tvel = trans(n) * (rvel - n * nvel)` is always 0, so the static coefficient is always selected.
The bug itself is confirmed, and the semi-implicit solver uses the selected value (RUNBOOK quirk
6.21); that it causes the locking is not verified. Test: fix it (`tvel = (rvel - n * nvel).length()`) and repeat a
frictional DKT run; in parallel, check whether the hard-contact friction cone can hold a sticking
pair at a tilt at all.
