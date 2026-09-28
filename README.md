# Snakemake workflow: `noHiC`

<p align="center">
  <img src="logo/noHiC_logo1.png" alt="noHiC logo" width="360">
</p>

[![Snakemake](https://img.shields.io/badge/snakemake-≥8.0.0-brightgreen.svg)](https://snakemake.github.io)
[![Tests](https://github.com/andyngh/noHiC-Snakemake/actions/workflows/main.yaml/badge.svg?branch=main)](https://github.com/andyngh/noHiC-Snakemake/actions?query=branch%3Amain+workflow%3ATests)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**noHiC** is a reference-guided contig scaffolding and evaluation workflow for error-corrected long-read
data (PacBio or ONT). It builds a *synthetic reference genome* (synref) from a
pangenome graph by sampling the haplotype that best matches the k-mer content of the
sample's own reads, polishes that reference with the same reads, and uses it to correct
and scaffold the contigs.

The workflow consists of five sub-workflows that can be switched on and off
independently:

| # | Stage       | Sub-workflow             | Computational tasks |
|---|-------------|--------------------------|---------------------|
| 1 | `refpick`   | `nohic-refpick.c.smk`    | Builds the best-fit reference for a target genome (synref) and optionally patches its gaps using sequence from a high-quality donor genome. |
| 2 | `refpolish` | `nohic-refpolish.c.smk`  | Polishes the synref or a real reference genome with the sample's reads using HyPo or Racon. |
| 3 | `clean`     | `nohic-clean.c.smk`      | Screens the contig assembly for adapters, decontaminates it using Kraken2/TaxonKit, and optionally removes organellar contigs. |
| 4 | `asm`       | `nohic-asm.c.smk`        | Corrects the contigs (CRAQ, Inspector, and RagTag correct), performs reference-guided scaffolding (RagTag scaffold), and closes gaps (TGS-GapCloser). |
| 5 | `eval`      | `nohic-eval.slurm.c.smk` | Assesses the scaffolded assembly in terms of contiguity, gene-space completeness, and structural correctness (based on QV, AQIs, and a dot plot). |

---

## Contents

- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Tutorial](#tutorial)
- [Outputs](#outputs)
- [How the stages of noHiC are wired together](#how-the-stages-of-nohic-are-wired-together)
- [Troubleshooting](#troubleshooting)
- [Authors](#authors)
- [References](#references)
- [License](#license)

---

## Repository layout

```
noHiC-Snakemake/
├── config/
│   ├── nohic.yaml                     # Config file for the whole noHiC workflow
│   └── README.md                      # Explanation of every configuration key
├── profiles/
│   ├── default/config.yaml            
│   ├── slurm/config.yaml              # Cluster profile for the evaluation stage (nohic-eval)
│   └── README.md
├── workflow/
│  ├── Snakefile                      # The noHiC workflow to be run
│  ├── rules/                         # Directory containing noHiC's sub-workflows
│      ├── nohic-refpick.c.smk
│      ├── nohic-refpolish.c.smk
│      ├── nohic-clean.c.smk
│      ├── nohic-asm.c.smk
│      ├── nohic-eval.slurm.c.smk
│      └── README.md                  # Explanation of each sub-workflow
│   
├── .test/                             # Smoke test (dry run) used by continuous integration
├── .github/workflows/                 # GitHub Actions workflows
├── logo/noHiC_logo1.png
├── .snakemake-workflow-catalog.yml
├── LICENSE
└── README.md
```

`workflow/Snakefile` locates its sub-workflows through `workflow.basedir`, so the five
`*.c.smk` files **must stay in `workflow/rules/`**, but the workflow itself can be
started from any working directory.

## Requirements

Install Snakemake (>= 8.0.0), snakemake-executor-plugin-slurm, and conda-pack as follows:

```bash
conda create -n snakemake -c bioconda -c conda-forge snakemake snakemake-executor-plugin-slurm conda-pack
```

Clone this repository:

```bash
git clone https://github.com/andyngh/noHiC-Snakemake.git
```

Set up conda environments for noHiC:

```bash
# Change to the noHiC-Snakemake directory
cd /path/to/noHiC-Snakemake
# Activate the "snakemake" environment
conda activate snakemake
# Set up the conda environments
chmod +x ./setup.sh
./setup.sh
```

## Tutorial

In this tutorial, we use the example files from the previous
[noHiC](https://github.com/andyngh/noHiC/tree/main/example) repository. The target genome
to scaffold is *A. thaliana* CAMA-C-2.

### Preparing the HiFi reads

To prepare the HiFi reads for this tutorial, install
[SRA Toolkit](https://anaconda.org/channels/bioconda/packages/sra-tools/overview) and
download the prebuilt binary of [TGSFilter](https://github.com/HuiyangYu/TGSFilter/releases/tag/v1.10).
Then run the following commands:

```bash
prefetch --max-size 200G ERR10084604
fastq-dump --origfmt ./ERR10084604
tgsfilter -i ERR10084604.fastq -o CAMA-C-2-hifi_reads.ALL.trimmed.fastq.gz -x hifi -t 24
```

### Downloading the Kraken2 database

In this tutorial, we use the `PlusPFP-16` database (16 GB). If you have more memory
(e.g., > 250 GB), you can download the `core_nt` database
[here](https://benlangmead.github.io/aws-indexes/k2).

```bash
wget https://genome-idx.s3.amazonaws.com/kraken/k2_pluspfp_16_GB_20260626.tar.gz
tar -xzf k2_pluspfp_16_GB_20260626.tar.gz
```

> [!NOTE]
> If you want to set `kraken2_memory_mapping: "yes"` in the config file, check the
> instructions in the previous
> [noHiC](https://github.com/andyngh/noHiC/tree/main#32-nohic-cleansh-contaminant-contig-removal)
> repository.

### Executing the noHiC workflow

```bash
conda activate snakemake
# Change to your working directory containing the example A. thaliana input files (not the noHiC-Snakemake directory)
cd /path/to/your/working/directory
```

noHiC can be executed by parsing inputs via command-line arguments. Detailed descriptions of the command-line arguments can be found in
[`config/README.md`](config/README.md). Alternatively, you can check the available arguments using the help message.

```bash
snakemake -s /path/to/noHiC-Snakemake/workflow/Snakefile --config help=yes
```

The pipeline can be executed as follows (**All required arguments have been filled in**).

>[!NOTE]
>If you use ONT reads, you can check [this repo](https://github.com/Clipman-Lab/ONT_NCBI_contamination) for ONT adapter sequences.

```bash
# Assuming that you have all inputs in the current working directory
snakemake --snakefile /path/to/noHiC-Snakemake/workflow/Snakefile \
         --config reads=CAMA-C-2-hifi_reads.ALL.trimmed.fastq.gz cov=69 prefix=CAMA-C-2 platform=hifi \
                  pk_gbz=arabidopsis_pgMC.full.gbz pk_hapl=arabidopsis_pgMC.full.hapl \
                  pl_gsize=135m \
                  cl_ctg=CAMA-C-2.asm.bp.p_ctg.fa cl_adapters=PacBio_adapters.fa \
                  cl_k2db=/path/to/pluspfp16_k2_db cl_org=yes cl_org_ref=mt.cl.fasta \
                  ev_ref=GCA_946406975.1_CAMA-C-2.PacbioHiFiAssembly_genomic.ed.SELECTED.fa \
                  ev_lineage=brassicales \
                  pk_out=CAMA-C-2.refpick pl_out=CAMA-C-2.refpolish cl_out=CAMA-C-2.clean \
                  as_out=CAMA-C-2.asm ev_out=CAMA-C-2.eval \
          --rerun-incomplete --cores 20
```

If you want to use SLURM to run the steps of `nohic-eval` in parallel by submitting the
jobs to different nodes, prepare an `.sbatch` script as follows:

```bash
#!/bin/bash
#SBATCH --mem=<memory>
#SBATCH --cpus-per-task=<thread_num>
#SBATCH --partition=<partition>
#SBATCH --mail-type=ALL
#SBATCH --mail-user=<email>

# Note: the memory and number of threads set in this sbatch script are used for
#       nohic-refpick, -refpolish, -clean, and -asm.
# nohic-eval submits its jobs to different nodes with the resource requirements set via the command-line arguments.

# Change to your working directory containing the
#  example A. thaliana input files (not the noHiC-Snakemake directory)
cd /path/to/your/working/directory
# Run the pipeline

snakemake --snakefile /path/to/noHiC-Snakemake/workflow/Snakefile \
         --config reads=CAMA-C-2-hifi_reads.ALL.trimmed.fastq.gz cov=69 prefix=CAMA-C-2 platform=hifi \
                  pk_gbz=arabidopsis_pgMC.full.gbz pk_hapl=arabidopsis_pgMC.full.hapl \
                  pl_gsize=135m \
                  cl_ctg=CAMA-C-2.asm.bp.p_ctg.fa cl_adapters=PacBio_adapters.fa \
                  cl_k2db=/path/to/pluspfp16_k2_db cl_org=yes cl_org_ref=mt.cl.fasta \
                  ev_ref=GCA_946406975.1_CAMA-C-2.PacbioHiFiAssembly_genomic.ed.SELECTED.fa \
                  ev_lineage=brassicales \
                  ev_slurm=yes slurm_partition=<your_partition> \
                  slurm_account=<your_account> slurm_mem=<memory_requirement> \
                  pk_out=CAMA-C-2.refpick pl_out=CAMA-C-2.refpolish \
                  cl_out=CAMA-C-2.clean as_out=CAMA-C-2.asm ev_out=CAMA-C-2.eval \
          --rerun-incomplete --executor slurm --jobs 5 --local-cores ${SLURM_CPUS_PER_TASK}
```

## Outputs

Each stage of noHiC writes into its own directory, with names given via the command-line arguments. The main output
files in each directory are listed below. See
[`workflow/rules/README.md`](workflow/rules/README.md) for detailed lists of the outputs
of each assembly stage.

- `CAMA-C-2.refpick/CAMA-C-2.synref.fa` (the synref of CAMA-C-2)
- `CAMA-C-2.refpolish/CAMA-C-2.hypo.fasta` (the polished synref)
- `CAMA-C-2.clean/4_assembly_decontamination/CAMA-C-2.asm.bp.p_ctg.pure.fa` (the clean CAMA-C-2 contigs)
- `CAMA-C-2.asm/5_Gap_closing/CAMA-C-2.craq.inspector.rt_corr.scf.tgs.fa` (the final assembly. It can be located in `CAMA-C-2.asm/4_Scaffolding/` if gap closing is turned off.)
- `CAMA-C-2.eval/1_Contiguity_metrics/report.tsv` (QUAST contiguity metrics of the final assembly)
- `CAMA-C-2.eval/2_Gene_space_completeness/summary.txt` (the main compleasm output for gene-space completeness)
- `CAMA-C-2.eval/3_CRAQ/runAQI_out/out_final.Report` (contains the R- and S-AQI, i.e., regional and structural assembly quality indices)
- `CAMA-C-2.eval/4_Inspector/summary_statistics` (contains the QV)
- `CAMA-C-2.eval/5_Visualization/query_to_reference.paf.png` (the generated dot plot)

Every rule writes a `.log` file next to its outputs, containing the exact command line
that was executed.

## How the stages of noHiC are wired together

The `[stages]` command-line section contains a switch for each sub-workflow. You can run
all stages or select one or several of them.

The master workflow (`workflow/Snakefile`) performs four tasks:

1. **Fills in global values for the stages that need them.**

   The command-line arguments under `[global]` (`env`, `reads`,
   `platform`, `cov`, and `prefix`) are copied into every stage that
   needs them. A value written inside a stage section always wins; a key that is left
   empty or missing takes the global value.

2. **Chains the stages.**

   When a stage input is left empty, it is filled with the main output of the preceding
   stage as follows:

   ```
   refpick ──(synref)──► refpolish ──(polished synref)──┬──────────────────────────┐
                                                        │                          │
                                                        ▼                          ▼
   clean ──(decontaminated contigs)───────────────────► asm ──(final assembly)──► eval
   ```

   - The `pl_ref` argument of `refpolish` takes the result of `refpick` (the patched or unpatched synref).
   - The `as_ctg` argument of `asm` takes the result of `clean` (i.e., the decontaminated contig assembly).
   - The `ev_asm` argument of `eval` takes the scaffolded assembly from `asm`.
   - The `as_ref` and `ev_ref` arguments of `asm` and `eval`, respectively, take the synref from `refpolish`, or the result of `refpick` if `refpolish` is off.

   Chaining only happens from a stage that is **switched on** (set to `"yes"`). If you
   switch a stage off (set it to `"no"`), you must fill in its downstream input manually.

3. **Validates the workflow configuration.**

   If there are errors in the workflow configuration (e.g., missing required inputs), you will get one
   readable message instead of an error deep inside a sub-workflow. The workflow checks
   that every required argument of the enabled stages is present, that all stages use the same
   conda environment, and that no two stages write into the same output directory.

4. **Imports each enabled sub-workflow as a module to be executed.**

   The computational tasks of the selected assembly stages are provided with the
   essential inputs from the config file and executed.

## Troubleshooting

| Message | Cause |
|---|---|
| `the key X needs to be in the global section` | A stage left a key empty and there is no `[global]` value to take. |
| `the following keys are missing from the config file` | Arguments normally filled in by an earlier stage have to be manually given when that stage is off. |
| `all stages have to use the same 'nohic_env_path'` | All enabled stages must use one environment. |
| `every stage needs its own output directory` | Two stages share an `out_dir` and would overwrite each other's marker files. |
| `Your contigs contain adapters!` | `clean` stopped on purpose. Check `1_adapter_check/*.adapter_positions.bed` and trim the adapters before continuing. |
| CRAQ fails immediately | CRAQ requires a **non-existent** output directory. The rule removes it first, so do not run two CRAQ rules into the same path concurrently. |

## Authors

- Andy Nguyen-Hoang

## References

> Nguyen-Hoang A., Arslan K., Kopalli V., Windpassinger S., Perovic D., Stahl A., Golicz A. (2026). NoHiC: A Pipeline for Plant Contig Scaffolding Using Personalized References from Pangenome Graphs. *bioRxiv*. DOI: https://doi.org/10.64898/2026.03.17.712436

Tool references are listed per sub-workflow in [the previous noHiC repo](https://github.com/andyngh/noHiC/blob/main/README.md#12-dependency-citations).

## License

MIT — see [LICENSE](LICENSE).
