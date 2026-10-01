# Union of Containers: SC26 poster artifact

Scripts, Spack environments, and run logs behind the SC26 research poster
*Union of Containers: Layered Software Stacks with Cross-Container Dependency Reuse for HPC*
(Parmanand Sinha, University of Chicago Research Computing Center).

This repository contains only what is necessary to validate or re-run the numbers on the poster. It is not the complete research workspace.

## Contents

| Path | What it is |
|---|---|
| `envs/` | `spack.yaml` and `spack.lock` for the CPU provider, the specialized layers (AMReX sm_70, sm_80, sm_90; heFFTe sm_80) and the two monolithic comparators. `_container_packages.yaml` declares the base-image externals. |
| `scripts/` | The Slurm jobs that produced each result, plus `r5r6_extract.py`. Site paths and accounts are parameterized (see `site.env.example`). |
| `apps/` | `cuda_smoke.cu`, the vector-add GPU check. |
| `evidence/logs/` | Small job logs, verbatim. |
| `evidence/excerpts/` | Excerpts of the large build logs (provenance, install times, file counts). `FULL_LOGS.sha256` lists the hashes of the complete logs, which are attached to the release. |
| `verify/` | Scripts that recompute poster numbers from the files in this repository. |

## Check the numbers without a cluster

```
python3 verify/reuse_from_locks.py         # 19/20 reused per AMReX layer, 20/21 for heFFTe
python3 verify/startup_medians.py          # +26 ms startup for the second tree
python3 scripts/r5r6_extract.py 20514681   # A100 benchmark parity: 0.112 s in all three arms
```

## Poster claim to evidence

| Poster claim | Evidence | Produced by |
|---|---|---|
| E4S `cuda80` image: 1,826,534 entries; unpacking it hit *Disk quota exceeded* at 69% | `logs/ch-compose-19818878.out` | Charliecloud unpack attempt |
| Provider: 36 buildable + 4 external packages | `envs/provider-cpu/spack.lock`; `verify/reuse_from_locks.py` | `e4s_provider_build.sbatch` (job 19747042) |
| 1 of 20 buildable packages compiled per AMReX layer (95.0%); heFFTe 20 of 21 (95.2%) | `envs/specialized-*/spack.lock`; `verify/reuse_from_locks.py` | `e4s_specialized_build`, `r3_sm70`, `r3b_sm90`, `r2b_heffte` |
| Build time, Anvil sm_80: 1,019 s monolithic vs 564 s layered (1.8x) | `excerpts/r1-monolithic-20502921` (install timer); `excerpts/specialized-19747874` (whole job, START to DONE; AMReX alone 8 m 44 s) | `r1_monolithic`, `e4s_specialized_build` |
| Build time, Anvil sm_90: 857 s vs 309 s (2.8x; 2.1x without the monolith's extra FFTW) | `excerpts/r1b-mono90-20513324`, `excerpts/r3b-sm90-20513323` (install timer, same day) | `r1b_mono90`, `r3b_sm90` |
| Files: 10,772 monolithic = 9,360 dependency + 1,407 AMReX + 5 tree files (`sbang`, `.spack-db`) | `excerpts/r1-monolithic-20502921`, `logs/r1-prefixes-20502921.txt` | `r1_monolithic` |
| Specialized layer: 1,412 files at sm_70, sm_80 and sm_90 | `excerpts/r3-sm70-*`, `excerpts/specialized-*`, `excerpts/r3b-sm90-*` | layer builds above |
| GPU run, Apptainer, A100 sm_80: PASS | `logs/gpu-compose-19806294.out` | `e4s_gpu_compose` |
| Cross-tree RPATH under Charliecloud | `logs/ch-compose2-19831461.out` | `ch_compose2` |
| GPU run, Charliecloud, A100 sm_80: PASS | `logs/ch-cuda-fn-19831573.out` | `ch_cuda_functional` |
| Benchmark parity, A100: 0.112 s layered = monolithic = E4S-native | `logs/r5r6-a100-20514681.out`, `logs/r5r6-a100-20516623.out` | `r5_build`, `r5c_mono80_build`, `r5d_native80_build`, `r5r6_a100_run` |
| Benchmark parity, H100: 0.0768 s vs 0.0761 s | `logs/r5r6-h100-20534450.out` | `r5b_sm90_build`, `r5r6_sm90_run` |
| Startup: +26 ms warm (+8%) | `logs/r4-startup-20509657-{1..5}.out`; `verify/startup_medians.py` | `r4_startup` |
| One provider shared by two containers at once (7 of 14 samples) | `logs/r6-overlap-20542283.out`, `r6-A2-*`, `r6-B2-*` | `r6_overlap` |
| GPFS readdir 678 ms cold vs 153 ms warm (4.4x) | `logs/m6-squash-19840923.out` (`ls -R` lines) | `m6_squashfuse` |

In `ch-compose2-19831461.out`, the one `not found` is `libmpi.so.12`: MPI is a base-image external and the minimal Charliecloud rootfs used for that check does not include it. Every library from the trees resolves.

The `squashfs` lines in the M6 log are not a measurement: `mksquashfs` was not available on the
compute nodes, so that mount was empty. Only the GPFS and SSD lines are used.

## Pinned inputs

| Input | Version |
|---|---|
| Spack | v1.2.1, commit `2f80bed` |
| spack-packages | `e4s-26.06.1`, commit `c9c7cdc5` |
| Base image | `e4s-cuda-26.06-cuda80.sif` (Ubuntu 24.04, gcc 13.3.0, CUDA 12.9.1, MPICH 4.3.2, Python 3.12.12); sha256 prefix `a1c0d4ac6ac100da` |
| Canonical install roots | `/tmp/e4s-provider-cpu`, `/tmp/e4s-specialized-<app>-<arch>` |
| Linking | `shared_linking: {type: rpath, bind: false}` |

## Rerunning on a cluster

1. Fetch the base image and check its sha256 prefix. Check out Spack and spack-packages at the commits above under `$UOC_ROOT/spack-v1.2.1` and `$UOC_ROOT/spack-packages-e4s-26.06.1`.
2. Copy the environments to where the scripts expect them: `mkdir -p $UOC_ROOT/configuration && cp -r envs $UOC_ROOT/configuration/e4s-26.06`.
3. `cp scripts/site.env.example scripts/site.env`, edit it, then `source scripts/site.env`.
4. Submit from the repository root with your allocation, in order: `e4s_provider_build`, then the specialized and monolithic builds, then the GPU and benchmark jobs. For example, `sbatch -A <account> scripts/e4s_provider_build.sbatch`.

Partition names in the `#SBATCH` headers are Anvil's; override them with `-p`. Concretize inside the container, not on a login node: the host OS enters the package hash, and hashes computed outside the container will not match the provider's.

## Not yet included

- `mfbench.cu` and its `CMakeLists.txt` (the AMReX MultiFab benchmark behind the parity results).
- Midway3 logs for the 13 vs 5 min build pair, the Midway3 reuse count, and the V100 run.
- The pairwise `diff` of the sm_70, sm_80, and sm_90 trees behind the 4-file result.
- The `cuobjdump` output showing the E4S image's `libkokkoscore.so` carries sm_80 cubins and no PTX.

## Acknowledgments

Supported by the Better Scientific Software Fellowship Program. This work used Anvil at Purdue University through allocation CIS261295 from the Advanced Cyberinfrastructure Coordination Ecosystem: Services & Support (ACCESS) program. It also used resources provided by the University of Chicago Research Computing Center.

## License

BSD 3-Clause; see `LICENSE`.
