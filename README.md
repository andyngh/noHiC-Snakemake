# Snakemake workflow: `noHiC`

<p align="center">
  <img src="logo/noHiC_logo1.png" alt="noHiC logo" width="360">
</p>

[![Snakemake](https://img.shields.io/badge/snakemake-≥8.0.0-brightgreen.svg)](https://snakemake.github.io)
[![Tests](https://github.com/andyngh/noHiC-Snakemake/actions/workflows/main.yaml/badge.svg?branch=main)](https://github.com/andyngh/noHiC-Snakemake/actions?query=branch%3Amain+workflow%3ATests)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**noHiC** is a reference-guided contig scaffolding and evaluation workflow for long-read
data (PacBio HiFi/CLR, ONT). It builds a *synthetic reference genome* (synref) from a
pangenome graph by sampling the haplotype that best matches the k-mer content of the
sample's own reads, polishes that reference with the same reads, and uses it to correct
and scaffold the contigs.

The workflow consists of five sub-workflows that can be switched on and off
independently, all driven by a single configuration file:

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
- [Executing noHiC using SLURM](#executing-nohic-using-slurm)
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
│   ├── default/config.yaml            # Picked up automatically; points to config/nohic.yaml
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

Download and unpack the conda environments for noHiC:

```bash
# Create directories for the required environments
mkdir -p /path/to/noHiC-Snakemake/workflow/envs/noHiC
mkdir -p /path/to/noHiC-Snakemake/workflow/envs/compleasm

# Download the environments
wget https://zenodo.org/records/22880706/files/noHiC.tar.gz
wget https://zenodo.org/records/22880706/files/compleasm.tar.gz

# Decompress the environments
tar -xzf noHiC.tar.gz -C /path/to/noHiC-Snakemake/workflow/envs/noHiC
tar -xzf compleasm.tar.gz -C /path/to/noHiC-Snakemake/workflow/envs/compleasm

# Unpack the environments
source /path/to/noHiC-Snakemake/workflow/envs/noHiC/bin/activate
conda-unpack
source /path/to/noHiC-Snakemake/workflow/envs/noHiC/bin/deactivate
source /path/to/noHiC-Snakemake/workflow/envs/compleasm/bin/activate
conda-unpack
source /path/to/noHiC-Snakemake/workflow/envs/compleasm/bin/deactivate
conda activate snakemake
```

After running these commands, copy the path `/path/to/noHiC-Snakemake/workflow/envs/noHiC` into
the `nohic_env_path` key of `noHiC-Snakemake/config/nohic.yaml`.

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

Before running the pipeline, edit the config file (`/path/to/noHiC-Snakemake/config/nohic.yaml`)
as shown below. Detailed descriptions of the keys in the config file can be found in
[`config/README.md`](config/README.md).

```yaml
# --- 1. Choose the stages to run --------------------------------------------#
# Fill in "yes" or "no".
stages:
  refpick:   "yes"     # Build (and patch) a synref
  refpolish: "yes"     # Polish a synref or a real reference genome
  clean:     "yes"     # Check contigs for adapters and remove contaminant contigs
  asm:       "yes"     # Contig correction, scaffolding, and gap closing
  eval:      "yes"     # Assembly evaluation

# --- 2. Set the global parameters -------------------------------------------#
global:
  nohic_env_path: "/path/to/noHiC-Snakemake/envs/noHiC"      # Path to the downloaded noHiC environment
  reads: "/path/to/CAMA-C-2-hifi_reads.ALL.trimmed.fastq.gz" # Path to the FASTQ file containing the HiFi reads of CAMA-C-2
  sequencing_platform: "hifi"
  sequencing_coverage: 69

# --- 3. Synref generation from a pangenome graph (nohic-refpick) ------------#
refpick:
  seq_file: ""                      # [chained] Takes the FASTQ file from "global: reads:" by default
  kmer_length: 29                   # Set the k-mer length (bp) (int)
  memory: 30                        # KMC memory in GB (int)
  kmc_mode: "fq"                    # Fill in "fq" if seq_file is a FASTQ file or "fm" if it is a FASTA file
  prefix: "CAMA-C-2"                # Set the output prefix
  kmc_out_dir: "CAMA-C-2.refpick"   # Name the output directory
  kmc_threads: 20                   # Set the number of threads for KMC-based k-mer counting (int)
  gbz: "/path/to/arabidopsis_pgMC.full.gbz"    # Path to a pangenome graph in GBZ format
  hapl: "/path/to/arabidopsis_pgMC.full.hapl"  # Path to the haplotype information (.hapl) file of the pangenome graph
  vg_threads: 20                    # Set the number of threads for haplotype sampling and synref generation (int)
  patch_synref: "no"                # We will not patch the synref in this tutorial
  donor_genome: ""
  patch_threads:

# --- 4. Reference polishing (nohic-refpolish) -------------------------------#
refpolish:
  synref: ""                        # [chained] Takes the synref generated by nohic-refpick by default
  mapping_preset: "map-hifi"        # Fill in "map-pb" / "map-hifi" / "map-ont" / "map-iclr"
  threads: 20                       # Set the number of threads (int)
  polish_tool: "hypo"               # Fill in "hypo" or "racon"
  coverage: 69                      # Fill in the sequencing coverage if polish_tool: "hypo"
  genome_size: "135m"               # Fill in the estimated genome size if polish_tool: "hypo" (e.g., "720m", "1g")
  out_dir: "CAMA-C-2.refpolish"     # Name the output directory
  prefix: "CAMA-C-2.synref"         # Set the output prefix

# --- 5. Contig assembly cleaning (nohic-clean) ------------------------------#
clean:
  contig_assembly: "/path/to/CAMA-C-2.asm.bp.p_ctg.fa"  # Path to the target contig assembly to decontaminate
  out_dir: "CAMA-C-2.clean"            # Set the name of the output directory
  adapters: "/path/to/PacBio_adapters.fa"  # Path to a FASTA file containing adapter sequences
  adapter_detection_thread: 10         # Set the number of threads for the adapter check (int)
  kraken2_db: "/path/to/pluspfp16_k2_db"   # Fill in /dev/shm if you can copy the k2d files to this directory and set kraken2_memory_mapping: "yes"
  kraken2_thread: 20                   # Set the number of threads for Kraken2-based taxonomic classification of contigs (int)
  kraken2_memory_mapping: "no"         # Fill in "yes" to use memory-mapping mode or "no" to turn this mode off
  taxonomic_group: "Viridiplantae"     # Fill in the target taxonomic group whose contigs should be kept
  org_ctg_identification: "yes"        # Fill in "yes" to remove cp- and mtDNA contigs or "no" to keep organellar DNA in the assembly
  reference_organellar_sequences: "/path/to/mt.cl.fasta"  # Path to a FASTA file containing reference cp- and mtDNA sequences
  blastn_thread: 20                    # Set the number of threads for BLASTn-based organellar contig removal (int)

# --- 6. Reference-guided contig correction and scaffolding (nohic-asm) ------#
asm:
  contigs: ""                     # [chained] Takes the decontaminated contigs from nohic-clean by default
  reference_genome: ""            # [chained] Takes the polished synref from nohic-refpolish by default
  out_dir: "CAMA-C-2.asm"         # Name the output directory
  out_prefix: "CAMA-C-2"          # Set the output prefix
  run_craq: "yes"                 # Fill in "yes" to enable CRAQ-based chimeric contig breaking or "no" to turn this step off
  craq_threads: 15                # Note: use 5-6 fewer threads for this step than for the other steps of nohic-asm
  ignore_het: "no"                # Fill in "yes" to set CRAQ's minimum clip rate to 0.55
  run_inspector: "yes"            # Fill in "yes" to enable Inspector-based contig correction or "no" to turn this step off
  inspector_threads: 20           # Fill in the number of threads for Inspector (int)
  run_ragtag_correct: "yes"       # Fill in "yes" to enable reference-guided contig correction by RagTag or "no" to turn this step off
  ragtag_threads: 20              # Fill in the number of threads for RagTag-based correction and scaffolding (int)
  preset: "luck"                  # Choose a RagTag correction preset: "draft" / "luck" / "standard" / "aggressive" / "raw" (default: "luck")
  run_gap_closing: "yes"          # Fill in "yes" to enable gap closing or "no" to turn this step off
  gap_closing_threads: 20         # Fill in the number of threads for gap closing (int)

# --- 7. Assembly evaluation (nohic-eval) ------------------------------------#
# We use the public assembly of CAMA-C-2 as the reference genome to evaluate our newly scaffolded assembly.
eval:
  assembly: ""                    # [chained] Takes the final assembly from nohic-asm by default
  reference_genome: "/path/to/GCA_946406975.1_CAMA-C-2.PacbioHiFiAssembly_genomic.ed.SELECTED.fa"
  out_dir: "CAMA-C-2.eval"        # Name the output directory
  contiguity_evaluation_tool: "quast"       # Choose the tool for contiguity evaluation ("gfastats", "quast", or "no" to turn this step off)
  contiguity_threads: 20                    # Set the number of threads for contiguity evaluation (int)
  gene_space_compl_eval_tool: "compleasm"   # Choose the tool for gene-space completeness evaluation ("compleasm", "busco", or "no" to turn this step off)
  gene_space_compl_eval_threads: 20         # Set the number of threads for gene-space completeness evaluation (int)
  lineage: "brassicales"          # Set the BUSCO lineage
  odb: "odb12"                    # Set the version of BUSCO's OrthoDB
  busco_out_prefix: ""            # Set the output prefix (only used with busco)
  run_craq: "yes"                 # Fill in "yes" to calculate the S- and R-AQI with CRAQ or "no" to turn this step off
  craq_threads: 15                # Note: use 5-6 fewer threads for this step than for the other steps of nohic-eval
  run_inspector: "yes"            # Fill in "yes" to calculate the QV with Inspector or "no" to turn this step off
  inspector_threads: 20           # Fill in the number of threads for Inspector (int)
  run_viz: "yes"                  # Fill in "yes" to draw a dot plot of the mappings between the target and reference genomes or "no" to turn this step off
  minimap2_preset: "asm5"         # Set the minimap2 preset ("asm5", "asm10", or "asm20")
  viz_threads: 20                 # Fill in the number of threads for dot plot generation (int)

  # SLURM settings for nohic-eval.
  # They only apply to the steps of this stage.
  # Since the evaluation steps of nohic-eval are independent, they are sent to different nodes and executed in parallel.
  use_slurm: "yes"                # Fill in "no" if you don't want to use SLURM
  slurm:
    default:
      memory: "250G"                  # Set your memory requirement for SLURM jobs (e.g., "32000M" or "32G")
      partition: "<your_partition>"   # Set your SLURM partition. Leave it empty ("") to let the SLURM site default decide
      account: "<your_account>"       # Set your SLURM account. Use "" if your cluster does not use accounts
      wall_time: "24h"                # Set your wall time for each evaluation step (e.g., "4h", "2d"; "" = partition default)
    # The SLURM settings above apply to all evaluation steps. If you want different settings for particular steps, use the keys below.
    rules:
      GFAstats:
        memory: ""
        partition: ""
        account: ""
        wall_time: ""
      QUAST:
        memory: ""
        partition: ""
        account: ""
        wall_time: ""
      busco:
        memory: ""
        partition: ""
        account: ""
        wall_time: ""
      compleasm:
        memory: ""
        partition: ""
        account: ""
        wall_time: ""
      craq_based_evaluation:
        memory: ""
        partition: ""
        account: ""
        wall_time: ""
      inspector_based_evaluation:
        memory: ""
        partition: ""
        account: ""
        wall_time: ""
      assembly_to_reference_mapping:
        memory: ""
        partition: ""
        account: ""
        wall_time: ""
```

After editing the config file, execute the noHiC pipeline as follows:

```bash
snakemake -s /path/to/noHiC-Snakemake/workflow/Snakefile \
          --configfile /path/to/noHiC-Snakemake/config/nohic.yaml \
          --cores <thread_num>
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

# Note: the memory and number of threads set in this sbatch script are used for nohic-refpick, -refpolish, -clean, and -asm.
# nohic-eval submits its jobs to different nodes with the resource requirements set in the nohic.yaml file.

# Change to your working directory containing the example A. thaliana input files (not the noHiC-Snakemake directory)
cd /path/to/your/working/directory
# Run the pipeline
snakemake --snakefile /path/to/noHiC-Snakemake/workflow/Snakefile \
          --configfile /path/to/noHiC-Snakemake/config/nohic.yaml \
          --rerun-incomplete --executor slurm --jobs 5 --local-cores ${SLURM_CPUS_PER_TASK}
```

## Outputs

Each stage writes into its own directory, named in the config file. The main output
files in each directory are listed below. See
[`workflow/rules/README.md`](workflow/rules/README.md) for detailed lists of the outputs
of each assembly stage.

- `CAMA-C-2.refpick/CAMA-C-2.synref.fa` — the synref of CAMA-C-2
- `CAMA-C-2.refpolish/CAMA-C-2.synref.hypo.fasta` — the polished synref
- `CAMA-C-2.clean/4_assembly_decontamination/CAMA-C-2.asm.bp.p_ctg.pure.fa` — the clean CAMA-C-2 contigs
- `CAMA-C-2.asm/5_Gap_closing/CAMA-C-2.craq.inspector.rt_corr.scf.tgs.fa` — the final assembly (located in `CAMA-C-2.asm/4_Scaffolding/` if gap closing is turned off)
- `CAMA-C-2.eval/1_Contiguity_metrics/report.tsv` — QUAST contiguity metrics of the final assembly
- `CAMA-C-2.eval/2_Gene_space_completeness/summary.txt` — the main compleasm output for gene-space completeness
- `CAMA-C-2.eval/3_CRAQ/runAQI_out/out_final.Report` — contains the R- and S-AQI (regional and structural assembly quality indices)
- `CAMA-C-2.eval/4_Inspector/summary_statistics` — contains the QV
- `CAMA-C-2.eval/5_Visualization/query_to_reference.paf.png` — the generated dot plot

The name of the final assembly reflects which `nohic-asm` steps were run: the prefix
gains `.craq`, `.inspector`, and `.rt_corr` for each enabled correction step, then
`.scf`, and finally `.tgs` if gap closing was run.

Every rule writes a `.log` file next to its outputs, containing the exact command line
that was executed.

## How the stages of noHiC are wired together

The `stages` key in the config file contains a switch for each sub-workflow. You can run
all stages or select one or several of them.

```yaml
# Fill in "yes"/"no" to turn a stage on/off.
stages:
  refpick:   "yes"
  refpolish: "yes"
  clean:     "yes"
  asm:       "yes"
  eval:      "yes"
```

The master workflow (`workflow/Snakefile`) performs four tasks:

1. **Fills in global values for the stages that need them.**

   In `config/nohic.yaml`, the keys under `global:` (`nohic_env_path`, `reads`,
   `sequencing_platform`, and `sequencing_coverage`) are copied into every stage that
   needs them. A value written inside a stage section always wins; a key that is left
   empty or missing takes the global value.

   For example, the `seq_file:` key of `refpick:` takes the value of the `reads:` key of
   `global:` by default. You can fill in the path to a different file (e.g., a FASTA file
   containing the contigs of your target genome) in `seq_file:`. That FASTA file will
   then be used by `nohic-refpick` instead of the FASTQ file given in `reads:`.

2. **Chains the stages.**

   When a stage input is left empty, it is filled with the main output of the preceding
   stage as follows:

   ```
   refpick ──(synref)──► refpolish ──(polished synref)──┬──────────────────────────┐
                                                        │                          │
                                                        ▼                          ▼
   clean ──(decontaminated contigs)───────────────────► asm ──(final assembly)──► eval
   ```

   - The `synref:` key of `refpolish` takes the result of `refpick` (the patched or unpatched synref).
   - The `contigs:` key of `asm` takes the result of `clean` (i.e., the decontaminated contig assembly).
   - The `assembly:` key of `eval` takes the scaffolded assembly from `asm`.
   - The `reference_genome:` key of `asm` and `eval` takes the synref from `refpolish`, or the result of `refpick` if `refpolish` is off.

   Chaining only happens from a stage that is **switched on** (set to `"yes"`). If you
   switch a stage off (set it to `"no"`), you must fill in its downstream input manually.
   For example, if you don't want to draw a dot plot between the polished synref (from
   `refpolish`) and your scaffolded assembly, you can fill in the `reference_genome:` key
   of `eval` with the path to your own reference genome. noHiC will then use that
   reference genome to generate the dot plot.

3. **Validates the config before anything runs.**

   If there are errors in the config file (e.g., missing required inputs), you get one
   readable message instead of an error deep inside a sub-workflow. The workflow checks
   that every required key of the enabled stages is present, that all stages use the same
   `nohic_env_path`, and that no two stages write into the same output directory.

4. **Imports each enabled sub-workflow as a module to be executed.**

   The computational tasks of the selected assembly stages are provided with the
   essential inputs from the config file and executed.

## Executing noHiC using SLURM

Only the **evaluation** stage (`nohic-eval`) is set up for SLURM submission. Every rule of
the other four stages is registered as a *local rule* by the master workflow. This means
that `refpick`, `refpolish`, `clean`, and `asm` treat the node to which the `.sbatch`
script containing the `snakemake` command is submitted as the local node. Only the
computational jobs of `eval` are submitted to multiple different nodes to be run in
parallel.

You can enable SLURM in `config/nohic.yaml` as follows:

```yaml
eval:
  use_slurm: "yes"
  slurm:
    default:
      memory: "250G"
      partition: "<your_partition>"
      account: "<your_account>"
      wall_time: "24h"
    # To change the resource requirements for specific steps, do as follows; an empty field falls back to "default"
    rules:
      GFAstats:
        memory: "5G"
        partition: "<your_different_partition>"
        account:
        wall_time: "1h"
      # ...
```

## Troubleshooting

| Message | Cause |
|---|---|
| `Workflow defines configfile nohic.yaml but it is not present` | No config file was supplied. Pass `--configfile config/nohic.yaml` or keep the default profile. |
| `the workflow stage: X is not mentioned in the config file` | A stage is set to `"yes"` in `stages:` but has no section of its own. |
| `the key X needs to be in the global section` | A stage left a key empty and there is no `global:` value to take. |
| `the following keys are missing from the config file` | Keys normally filled in by an earlier stage have to be given by hand when that stage is off. |
| `all stages have to use the same 'nohic_env_path'` | `shell.prefix` is global in Snakemake, so all enabled stages must use one environment. |
| `every stage needs its own output directory` | Two stages share an `out_dir` and would overwrite each other's marker files. |
| `Your contigs contain adapters!` | `clean` stopped on purpose. Check `1_adapter_check/*.adapter_positions.bed` and trim the adapters before continuing. |
| CRAQ fails immediately | CRAQ requires a **non-existent** output directory. The rule removes it first, so do not run two CRAQ rules into the same path concurrently. |

## Authors

- Andy Nguyen-Hoang

## References

> Nguyen-Hoang A., Arslan K., Kopalli V., Windpassinger S., Perovic D., Stahl A., Golicz A. (2026). NoHiC: A Pipeline for Plant Contig Scaffolding Using Personalized References from Pangenome Graphs. *bioRxiv*. DOI: https://doi.org/10.64898/2026.03.17.712436

Tool references are listed per sub-workflow in
[`workflow/rules/README.md`](workflow/rules/README.md).

## License

MIT — see [LICENSE](LICENSE).
