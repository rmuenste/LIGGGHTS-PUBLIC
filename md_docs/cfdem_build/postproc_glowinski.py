#!/usr/bin/env python3
"""Python replacement for twoSpheresGlowinskiMPI/CFD/octave/postproc.m (no Octave here).

Usage: postproc_glowinski.py <caseDir> [outDir]

Reads DEM/post/{position,velocity}_particle_{1,2}.txt and the Octave text-format
reference data CFD/octave/coord_{pos,vel}.mat (Glowinski et al.), prints a summary
and writes pos_z_two_part_rec_glow.png / vel_z_two_part_rec_glow.png like the
Octave script (same offset: following particle shifted to start at 5 cm).
"""
import sys, os
import numpy as np


def load_octave_text(path):
    """Minimal parser for Octave's '-text' format (matrix and scalar only)."""
    out, name, typ, rows, cols, buf = {}, None, None, None, None, []
    def flush():
        if name is None:
            return
        if typ == 'scalar':
            out[name] = float(buf[0][0])
        elif typ == 'matrix':
            out[name] = np.array(buf, dtype=float).reshape(rows, cols)
    with open(path) as f:
        for line in f:
            s = line.strip()
            if s.startswith('# name:'):
                flush(); name = s.split(':', 1)[1].strip(); typ = None; buf = []
            elif s.startswith('# type:'):
                typ = s.split(':', 1)[1].strip()
            elif s.startswith('# rows:'):
                rows = int(s.split(':', 1)[1])
            elif s.startswith('# columns:'):
                cols = int(s.split(':', 1)[1])
            elif s.startswith('#') or not s:
                continue
            else:
                buf.append(s.split())
    flush()
    return out


def load_txt(path):
    return np.loadtxt(path, comments='%')


def main():
    case = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(case, 'CFD', 'octave')
    post = os.path.join(case, 'DEM', 'post')
    p1 = load_txt(os.path.join(post, 'position_particle_1.txt'))
    p2 = load_txt(os.path.join(post, 'position_particle_2.txt'))
    v1 = load_txt(os.path.join(post, 'velocity_particle_1.txt'))
    v2 = load_txt(os.path.join(post, 'velocity_particle_2.txt'))
    rp = load_octave_text(os.path.join(case, 'CFD', 'octave', 'coord_pos.mat'))
    rv = load_octave_text(os.path.join(case, 'CFD', 'octave', 'coord_vel.mat'))

    d = 0.167  # particle diameter (cm), from in.liggghts_run
    offset = 5.0 - p1[0, 3]
    print('# t  z1  z2  (z1-z2)/d  vz1  vz2  |  x1 y1  x2 y2')
    for i in range(len(p1)):
        print('%.4f %.4f %.4f %6.3f %8.3f %8.3f | %.3f %.3f %.3f %.3f' % (
            p1[i, 0], p1[i, 3], p2[i, 3], (p1[i, 3] - p2[i, 3]) / d,
            v1[i, 3], v2[i, 3], p1[i, 1], p1[i, 2], p2[i, 1], p2[i, 2]))
    sep = np.hypot(np.hypot(p1[:, 1] - p2[:, 1], p1[:, 2] - p2[:, 2]), p1[:, 3] - p2[:, 3])
    imin = int(np.argmin(sep))
    print('min centre distance %.4f cm (= %.3f d, gap %.4f cm) at t = %.4f s'
          % (sep[imin], sep[imin] / d, sep[imin] - d, p1[imin, 0]))
    cross = np.where(p1[:, 3] < p2[:, 3])[0]
    if len(cross):
        print('particle 1 (initially upper) passes below particle 2 at t = %.4f s' % p1[cross[0], 0])
    else:
        print('no overtaking (tumbling) within the simulated time')

    nl = rp['dataLen'].astype(int).ravel()
    c = rp['coord']
    print('reference (Glowinski) position, following: t=%.3f..%.3f, leading: t=%.3f..%.3f'
          % (c[0, 0], c[nl[0] - 1, 0], c[0, 2], c[nl[1] - 1, 2]))

    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        return
    fig, ax = plt.subplots(figsize=(7, 5))
    ax.plot(p1[:, 0], offset + p1[:, 3], '*-', label='following particle (sim)')
    ax.plot(p2[:, 0], offset + p2[:, 3], '+-', label='leading particle (sim)')
    ax.plot(c[:nl[0], 0], c[:nl[0], 1], 'o', mfc='none', label='following particle Glow.')
    ax.plot(c[:nl[1], 2], c[:nl[1], 3], 's', mfc='none', label='leading particle Glow.')
    ax.set_xlim(0, 0.25); ax.set_ylim(0, 6)
    ax.set_xlabel('time (s)'); ax.set_ylabel('position (cm)')
    ax.set_title('Vertical position of two particles'); ax.legend(); ax.grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(os.path.join(outdir, 'pos_z_two_part_rec_glow.png'), dpi=120)

    nl = rv['dataLen'].astype(int).ravel()
    c = rv['coord']
    fig, ax = plt.subplots(figsize=(7, 5))
    ax.plot(v1[:, 0], v1[:, 3], '*-', label='following particle (sim)')
    ax.plot(v2[:, 0], v2[:, 3], '+-', label='leading particle (sim)')
    ax.plot(c[:nl[0], 0], c[:nl[0], 1], 'o', mfc='none', label='following particle Glow.')
    ax.plot(c[:nl[1], 2], c[:nl[1], 3], 's', mfc='none', label='leading particle Glow.')
    ax.set_xlim(0, 0.25); ax.set_ylim(-20, 0)
    ax.set_xlabel('time (s)'); ax.set_ylabel('velocity (cm/s)')
    ax.set_title('Settling velocity of two particles'); ax.legend(); ax.grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(os.path.join(outdir, 'vel_z_two_part_rec_glow.png'), dpi=120)
    print('plots written to', outdir)


if __name__ == '__main__':
    main()
