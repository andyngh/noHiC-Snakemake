# Snakemake workflow: `noHiC`

[![Snakemake](https://img.shields.io/badge/snakemake-≥8.0.0-brightgreen.svg)](https://snakemake.github.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**noHiC** is a reference-guided genome assembly and evaluation workflow for long-read
data (PacBio HiFi/CLR, ONT) that does **not** require Hi-C data. Instead of chromatin
contact information, it builds a *synthetic reference* from a pangenome graph by
sampling the haplotype that best matches the k-mer content of the sample's own reads,
polishes that reference with the same reads, and uses it to correct and scaffold the
contigs.

The workflow is made of five sub-workflows that can be switched on and off
independently, all driven from a single configuration file:

| # | Stage       | Sub-workflow                  | What it does |
|---|-------------|-------------------------------|--------------|
| 1 | `refpick`   | `nohic-refpick.c.smk`         | Builds a synthetic reference: KMC3 k-mer counting → `vg haplotypes` sampling → `vg paths` FASTA extraction, optionally patched against a donor genome with GPatch |
| 2 | `refpolish` | `nohic-refpolish.c.smk`       | Polishes the synthetic reference with the sample's reads using HyPo or Racon |
| 3 | `clean`     | `nohic-clean.c.smk`           | Adapter screening, Kraken2/TaxonKit decontamination and organellar-contig removal from the contig assembly |
| 4 | `asm`       | `nohic-asm.c.smk`             | Contig correction (CRAQ, Inspector, RagTag correct), reference-guided scaffolding (RagTag scaffold) and gap closing (TGS-GapCloser) |
| 5 | `eval`      | `nohic-eval.slurm.c.smk`      | Contiguity (gfastats/QUAST), gene-space completeness (BUSCO/compleasm), CRAQ and Inspector QV metrics, and an assembly-vs-reference dot plot |

The stages are chained automatically: `refpick` → `refpolish` → `asm`, `clean` → `asm`,
and `asm` → `eval`. Any stage you switch off simply means its input has to be given by
hand in the config.

---

## Contents

- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [How the stages are wired together](#how-the-stages-are-wired-together)
- [Running on a cluster](#running-on-a-cluster)
- [Output](#output)
- [Troubleshooting](#troubleshooting)
- [Authors](#authors)
- [References](#references)

---

## Repository layout

```
noHiC-Snakemake/
├── config/
│   ├── nohic.yaml                     # the single config file for the whole workflow
│   └── README.md                      # reference for every configuration key
├── profiles/
│   ├── default/config.yaml            # picked up automatically; points at config/nohic.yaml
│   ├── slurm/config.yaml              # cluster profile for the evaluation stage
│   └── README.md
├── workflow/
│   ├── Snakefile                      # master workflow (the former nohic.smk)
│   ├── rules/
│   │   ├── nohic-refpick.c.smk
│   │   ├── nohic-refpolish.c.smk
│   │   ├── nohic-clean.c.smk
│   │   ├── nohic-asm.c.smk
│   │   ├── nohic-eval.slurm.c.smk
│   │   └── README.md                  # what each sub-workflow does, rule by rule
│   └── scripts/README.md              # helper scripts the workflow expects on $PATH
├── .github/workflows/                 # continuous integration
├── LICENSE
└── README.md
```

This is the [standard Snakemake repository
layout](https://snakemake.readthedocs.io/en/stable/snakefiles/deployment.html#distribution-and-reproducibility).
`workflow/Snakefile` locates its sub-workflows through `workflow.basedir`, so the five
`*.c.smk` files **must stay in `workflow/rules/`** — but the workflow itself can be
started from any working directory.

## Requirements

- **Snakemake ≥ 8.0** (the master workflow declares `min_version("8.0")` and uses the
  `module` / `use rule` syntax).
- **One Python virtual environment containing every tool used by the enabled stages.**
  noHiC does not use per-rule conda environments. Each sub-workflow calls
  `shell.prefix(f"source {nohic_env_path}/bin/activate; ")`, so every rule runs inside
  that one environment. Because `shell.prefix` is global in Snakemake, **all enabled
  stages must point at the same `nohic_env_path`** — the master workflow checks this and
  aborts with a clear message if they differ.

  Tools expected in that environment, by stage:

  | Stage | Tools |
  |-------|-------|
  | `refpick` | `kmc`, `vg`, `minimap2`, `samtools`, `GPatch`, `Asm_Decomposing.sh` |
  | `refpolish` | `minimap2`, `samtools`, `hypo` and/or `racon` |
  | `clean` | `seqkit`, `kraken2`, `taxonkit`, `blastn`, `makeblastdb`, `filter_blast.py`, `wget`, `tar` |
  | `asm` | `craq`, `inspector.py`, `inspector-correct.py`, `ragtag.py`, `seqkit`, `tgsgapcloser` |
  | `eval` | `gfastats` and/or `quast`, `busco` or `compleasm`, `craq`, `inspector.py`, `minimap2`, `bioawk`, `paf2dotplot.R` |

  `compleasm` is the one exception: the eval stage activates it from a **sibling**
  environment, `<parent of nohic_env_path>/compleasm`. If `nohic_env_path` is
  `/path/envs/noHiC`, compleasm is expected at `/path/envs/compleasm`.

- **Reference data** you provide yourself: the pangenome graph (`.gbz` + `.hapl`), an
  optional donor genome for patching, a Kraken2 database, an adapter FASTA and (for
  organellar screening) a FASTA of reference mitochondrial/chloroplast sequences.

## Quick start

```bash
git clone https://github.com/<owner>/noHiC-Snakemake.git
cd noHiC-Snakemake

# 1. edit the configuration
$EDITOR config/nohic.yaml

# 2. dry run - shows the full job graph without executing anything
snakemake -n --cores 50

# 3. run
snakemake --cores 50
```

`profiles/default/config.yaml` is picked up automatically by Snakemake and supplies
`--configfile config/nohic.yaml`, so you do not have to pass it every time. If you
disable workflow profiles (`--workflow-profile none`) or run from somewhere else, pass
it explicitly:

```bash
snakemake --configfile config/nohic.yaml --cores 50
```

> **Note.** The master workflow contains the line `configfile: "nohic.yaml"`, which
> Snakemake resolves **relative to the working directory**. That file does not exist at
> the repository root, which is harmless *as long as a config file is supplied on the
> command line* (directly or through a profile) — Snakemake then uses the one you gave.
> Running `snakemake` with no config file at all therefore fails with
> `Workflow defines configfile nohic.yaml but it is not present`. Always keep the
> `--configfile` flag, or the default profile that provides it.

All relative paths inside `config/nohic.yaml` (reads, contigs, output directories, the
pangenome graph, …) are resolved against the **working directory**, not against the
repository. Either use absolute paths, or run Snakemake from the directory that holds
your data with `--snakefile /path/to/noHiC-Snakemake/workflow/Snakefile`.

### Useful invocations

```bash
# run a single stage (rules are prefixed with the stage name)
snakemake --cores 50 --until refpick_synref_extracting

# see why something will be re-run
snakemake -n -r --cores 1

# a DAG picture of the whole thing
snakemake --dag --cores 1 | dot -Tsvg > dag.svg
```

## How the stages are wired together

`stages:` in the config switches each sub-workflow on or off:

```yaml
stages:
  refpick:   "yes"
  refpolish: "yes"
  clean:     "yes"
  asm:       "yes"
  eval:      "yes"
```

The master workflow then does four things:

1. **Fills global values in.** Keys under `global:` (`nohic_env_path`, `reads`,
   `sequencing_platform`, `sequencing_coverage`) are copied into every stage that needs
   them. A value written inside a stage section always wins; a key left empty or missing
   takes the global one.

2. **Chains the stages.** Where a stage input is left empty, it is filled with the
   output of the stage before:

   ```
   refpick  ──(synthetic reference)──►  refpolish ──┐
                                                    ├──►  asm  ──(final assembly)──►  eval
   clean  ──(decontaminated contigs)─────────────---┘
   ```

   - `refpolish.synref`      ← `refpick` result (patched or unpatched, per `patch_synref`)
   - `asm.contigs`           ← `clean` result (`{sample}.pure.fa`)
   - `asm.reference_genome`  ← `refpolish` result, or `refpick` result if `refpolish` is off
   - `eval.assembly`         ← `asm` result
   - `eval.reference_genome` ← `refpolish` result, or `refpick` result if `refpolish` is off

   Chaining only happens from a stage that is switched **on**. Switch a stage off and you
   must fill its downstream input in by hand.

3. **Validates the config before anything runs**, so you get one readable message instead
   of an error deep inside a sub-workflow. It checks that every required key for the
   enabled stages is present, that all stages agree on one `nohic_env_path`, and that no
   two stages write into the same output directory (they would overwrite each other's
   `pipeline.done` markers).

4. **Imports each enabled sub-workflow as a module** and prefixes its rules with the
   stage name (`refpick_kmer_counting`, `asm_Scaffolding`, `eval_QUAST`, …). Use those
   prefixed names with `--until`, `--omit-from`, `--allowed-rules` and friends.

## Running on a cluster

Only the **evaluation** stage is set up for SLURM submission. Every rule of the other
four stages is registered as a *local rule* by the master workflow, so they keep running
on the machine that runs Snakemake even when an executor is active.

Enable it in `config/nohic.yaml`:

```yaml
eval:
  use_slurm: "yes"
  slurm:
    default:
      memory: "250G"
      partition: "bcf"
      account: "bcf"
      wall_time: "24h"
    rules:
      GFAstats:
        memory: "5G"
        partition: "idle"
      # ... per-rule overrides; an empty field falls back to "default"
```

and run with the SLURM executor:

```bash
pip install snakemake-executor-plugin-slurm
snakemake --workflow-profile profiles/slurm --jobs 20
# equivalently: snakemake --executor slurm --jobs 20 --configfile config/nohic.yaml
```

Memory accepts `32000`, `"32000M"`, `"32G"`; wall time accepts `120`, `"4h"`, `"2d"`.
Leave a field empty (`""`) to let the cluster default decide. With `use_slurm: "no"` the
eval rules run locally like everything else.

The lightweight eval rules (`scaffold_length_calculations`, `dot_plot_generation`,
`pipeline_done` and all the `*_skipped` markers) always stay local — they are not worth a
job submission.

## Output

Each stage writes into its own directory, named in the config. With the shipped example
settings:

```
SB14122.refpick/     synthetic reference   → SB14122.synref.fa / SB14122.synref.patched.fasta
SB14122.refpolish/   polished reference    → SB14122.synref.patched.hypo.fasta
SB14122.clean/       1_adapter_check/ 2_contamination_check/ 3_organellar_DNA_check/
                     4_assembly_decontamination/ → *.pure.fa
SB14122.asm/         1_CRAQ/ 2_Inspector/ 3_RagTag_correct/ 4_Scaffolding/ 5_Gap_closing/
                     → final assembly, e.g. SB14122.craq.inspector.rt_corr.scf.tgs.fa
SB14122.eval/        1_Contiguity_metrics/ 2_Gene_space_completeness/ 3_CRAQ/
                     4_Inspector/ 5_Visualization/ + pipeline.done
```

The name of the final assembly reflects which steps ran: the prefix picks up `.craq`,
`.inspector`, `.rt_corr` for each enabled correction step, then `.scf`, then `.tgs` if
gap closing ran. Every rule writes a `.log` file next to its outputs, containing the exact
command line that was executed.

`workflow/rules/README.md` documents each sub-workflow rule by rule, and
`config/README.md` explains every configuration key.

## Troubleshooting

| Message | Cause |
|---|---|
| `Workflow defines configfile nohic.yaml but it is not present` | No config file was supplied. Pass `--configfile config/nohic.yaml` or keep the default profile. |
| `the workflow stage: X is not mentioned in the config file` | A stage is `"yes"` in `stages:` but has no section of its own. |
| `the key X needs to be in the global section` | A stage left a key empty and there is no `global:` value to take. |
| `the following keys are missing from the config file` | Keys normally filled in by an earlier stage have to be given by hand when that stage is off. |
| `all stages have to use the same 'nohic_env_path'` | `shell.prefix` is global in Snakemake; one environment for all enabled stages. |
| `every stage needs its own output directory` | Two stages share an `out_dir` and would overwrite each other's marker files. |
| `Your contigs contain adapters!` | `clean` stopped on purpose. See `1_adapter_check/*.adapter_positions.bed` and trim before continuing. |
| CRAQ fails immediately | CRAQ requires a **non-existing** output directory; the rule removes it first, so do not run two CRAQ rules into the same path concurrently. |

## Authors

- Andy Nguyen Hoang

## References

> Köster, J., Mölder, F., Jablonski, K. P., Letcher, B., Hall, M. B., Tomkins-Tinch, C. H., Sochat, V., Forster, J., Lee, S., Twardziok, S. O., Kanitz, A., Wilm, A., Holtgrewe, M., Rahmann, S., & Nahnsen, S. _Sustainable data analysis with Snakemake_. F1000Research, 10:33, **2021**. https://doi.org/10.12688/f1000research.29032.2

Tool references are listed per sub-workflow in
[`workflow/rules/README.md`](workflow/rules/README.md).

## License

MIT — see [LICENSE](LICENSE).
