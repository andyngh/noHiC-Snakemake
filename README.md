# Snakemake workflow: `noHiC`

<p align="center">
  <img src="logo/noHiC_logo1.png" alt="noHiC logo" width="360">
</p>

[![Snakemake](https://img.shields.io/badge/snakemake-≥8.0.0-brightgreen.svg)](https://snakemake.github.io)
[![Tests](https://github.com/andyngh/noHiC-Snakemake/actions/workflows/main.yaml/badge.svg?branch=main)](https://github.com/andyngh/noHiC-Snakemake/actions?query=branch%3Amain+workflow%3ATests)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**noHiC** is a reference-guided genome assembly and evaluation workflow for long-read
data (PacBio HiFi/CLR, ONT). It builds a *synthetic reference genome* (synref) from a pangenome graph by
sampling the haplotype that best matches the k-mer content of the sample's own reads,
polishes that reference with the same reads, and uses it to correct and scaffold the
contigs.

The workflow is made of five sub-workflows that can be switched on and off
independently, all driven from a single configuration file:

| # | Stage       | Sub-workflow                  | Computational Tasks |
|---|-------------|-------------------------------|--------------|
| 1 | `refpick`   | `nohic-refpick.c.smk`         | Builds the synref and optionally patches the gaps in the generated synref using the sequence from a high-quality donor genome. |
| 2 | `refpolish` | `nohic-refpolish.c.smk`       | Polishes the synref or a real reference genome with the sample's reads using HyPo or Racon |
| 3 | `clean`     | `nohic-clean.c.smk`           | Adapter screening, Kraken2/TaxonKit-based decontamination, and optional organellar-contig removal from the contig assembly |
| 4 | `asm`       | `nohic-asm.c.smk`             | Contig correction (CRAQ, Inspector, and RagTag correct), reference-guided scaffolding (RagTag scaffold), and gap closing (TGS-GapCloser) |
| 5 | `eval`      | `nohic-eval.slurm.c.smk`      | Accesses the scaffolded assembly based on different aspects, including contiguity, gene-space completeness, and structural correctness (based on QV, AQIs, and dot plot) |

The stages are chained automatically: `refpick` → `refpolish` → `asm`, `clean` → `asm`,
and `asm` → `eval`. Any stage you switch off simply means its input has to be manually specify in the config file.

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
│   ├── nohic.yaml                     # the config file for the whole noHiC workflow
│   └── README.md                      # Explanations for every configuration key
├── profiles/
│   ├── default/config.yaml            # picked up automatically; points at config/nohic.yaml
│   ├── slurm/config.yaml              # cluster profile for the evaluation stage (nohic-eval)
│   └── README.md
├── workflow/
│   ├── Snakefile                      # The noHiC workflow to be run
│   ├── rules/                         # The directory containing noHiC's sub-workflows
│   │   ├── nohic-refpick.c.smk
│   │   ├── nohic-refpolish.c.smk
│   │   ├── nohic-clean.c.smk
│   │   ├── nohic-asm.c.smk
│   │   ├── nohic-eval.slurm.c.smk
│   │   └── README.md                  # Explanations for each sub-workflows
│   └── scripts/README.md              # helper scripts the workflow expects on $PATH
├── logo/noHiC_logo1.png               
├── .github/workflows/                 
├── LICENSE
└── README.md
```

`workflow/Snakefile` locates its sub-workflows through `workflow.basedir`, so the five
`*.c.smk` files **must stay in `workflow/rules/`**, but the workflow itself can be
started from any working directory.

## How the stages of noHiC are wired together

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

## Requirements

Install Snakemake (>= 8.0.0), snakemake-executor-plugin-slurm, and conda-pack as follows.

```bash
conda create -n snakemake -c bioconda -c conda-forge snakemake snakemake-executor-plugin-slurm conda-pack
```

Clone this repository.

```bash
git clone https://github.com/andyngh/noHiC-Snakemake.git
```

Download and unpack conda environments for noHiC.

```bash
# Create directories for the required environments

mkdir -p /path/to/noHiC-Snakemake/envs/noHiC
mkdir -p /path/to/noHiC-Snakemake/envs/compleasm

# Download the environments

wget https://zenodo.org/records/22880706/files/noHiC.tar.gz
wget https://zenodo.org/records/22880706/files/compleasm.tar.gz

# Decompress the enviroments

tar -xzf noHiC.tar.gz -C /path/to/noHiC-Snakemake/envs/noHiC
tar -xzf compleasm.tar.gz -C /path/to/noHiC-Snakemake/envs/compleasm

# Unpack the environments

source /path/to/noHiC-Snakemake/envs/noHiC/bin/activate
conda-unpack
source /path/to/noHiC-Snakemake/envs/noHiC/bin/deactivate
source /path/to/noHiC-Snakemake/envs/compleasm/bin/activate
conda-unpack
source /path/to/noHiC-Snakemake/envs/compleasm/bin/deactivate
conda activate snakemake
```

After running all commands, you can copy `/path/to/noHiC-Snakemake/envs/noHiC` to the `nohic_env_path` key of `noHiC-Snakemake/config/nohic.yaml`

## Tutorial

We will use the example files from the previous [noHiC](https://github.com/andyngh/noHiC/tree/main/example) repository for this tutorial. The target genome to scaffold is *A. thaliana* CAMA-C-2.

**HiFi Reads Preparation**

To prepare the HiFi reads for this tutorial, you will need to install [SRA Toolkit](https://anaconda.org/channels/bioconda/packages/sra-tools/overview) and download the prebuilt binary of [TGSFilter](https://github.com/HuiyangYu/TGSFilter/releases/tag/v1.10). Then, run the following commands.

```bash
prefetch --max-size 200G ERR10084604
fastq-dump --origfmt ./ERR10084604
tgsfilter -i ERR10084604.fastq -o CAMA-C-2-hifi_reads.ALL.trimmed.fastq.gz -x hifi -t 24
```

**Download Kraken2 Database**

For this tutorial, we will use the `PlusPFP-16` database (16GB). If you have more memory (e.g., > 250GB), you can download the `core_nt` database [here](https://benlangmead.github.io/aws-indexes/k2).

```bash
wget https://genome-idx.s3.amazonaws.com/kraken/k2_pluspfp_16_GB_20260626.tar.gz
tar -xzf k2_pluspfp_16_GB_20260626.tar.gz
```

>**Note:**
>Check the instruction in the previous [noHiC](https://github.com/andyngh/noHiC/tree/main#32-nohic-cleansh-contaminant-contig-removal) repository, if you want to set `kraken2_memory_mapping: "yes"` in the config file.

**Execute the noHiC Workflow**

```bash
conda activate snakemake
# Change to your working directory containing example A. thaliana input files (not the noHiC-Snakemake directory)  
cd /path/to/your/working/directory
```

Edit the config file (`path/to/noHiC-Snakemake/config/nohic.yaml`) as follows before running the pipeline.

```yaml
# --- 1. Choose the stages to run --------------------------------------------#
# Fill in "yes" or "no".
stages:
  refpick:   "yes"     # Build (and patch) a synref
  refpolish: "yes"     # Polish a synref or a real reference genome 
  clean:     "yes"     # Check the presence of adapters in contigs and contaminant contig removal
  asm:       "yes"     # Contig correction, scaffolding, and gap closing
  eval:      "yes"     # Assembly evaluation

# --- 2. Set the global parameters -------------------------------------------#
global:
  nohic_env_path: "/path/to/noHiC-Snakemake/envs/noHiC" # Path to the downloaded noHiC environment
  reads: "/path/to/CAMA-C-2-hifi_reads.ALL.trimmed.fastq.gz"    # Path to the fastq file containing HiFi reads of CAMA-C-2
  sequencing_platform: "hifi"
  sequencing_coverage: 69

# --- 3. Synref generation from a pangenome graph (nohic-refpick) ------------#
refpick:
  seq_file: ""                    # [chained] Take the fastq file from "global: reads: " by default.
  kmer_length: 29                 # set the kmer length (bp) (int)
  memory: 30                     # KMC memory in GB (int)
  kmc_mode: "fq"                  # Fill in "fq" if seq_file is a fastq file and "fm" if it is a fasta file
  prefix: "CAMA-C-2"                # Set outputs' prefix 
  kmc_out_dir: "CAMA-C-2.refpick"   # Name the output directory
  kmc_threads: 20                 # Set the thread number for KMC-based kmer counting (int)
  gbz: "/path/to/arabidopsis_pgMC.full.gbz"           # Path to a pangenome graph in GBZ format
  hapl: "/path/to/arabidopsis_pgMC.full.hapl"         # Path to the haplotype information (.hapl) file of the pangenome graph
  vg_threads: 20                  # Set the thread number for haplotype sampling and synref generation (int)
  patch_synref: "no"             # We will not patch the synref in this tutorial
  donor_genome: "" 
  patch_threads:                

# --- 4. Reference polishing (nohic-refpolish) -----------------------------------#
refpolish:
  synref: ""                      # [chained] By default, take the synref generated by nohic-refpick
  mapping_preset: "map-hifi"      # Fill in "map-pb" / "map-hifi" / "map-ont" / "map-iclr"
  threads: 20                     # Set the thread number (int)
  polish_tool: "hypo"             # Fill in "hypo" or "racon"
  coverage: 69                    # Fill in the sequencing coverage if polish_tool: "hypo"
  genome_size: "135m"             # Fill in the estimated genome size if polish_tool: "hypo" (e.g., "720m", "1g")
  out_dir: "CAMA-C-2.refpolish"     # Name the output directory
  prefix: "CAMA-C-2.synref" # Set the output prefix 

# --- 5. Contig assembly cleaning (nohic-clean) --------------------------------#
clean:
  contig_assembly: "/path/to/CAMA-C-2.asm.bp.p_ctg.fa" # Path to the target contig assembly to decontaminate 
  out_dir: "CAMA-C-2.clean"          # Set the name of the output directory 
  adapters: "/path/to/PacBio_adapters.fa"        # Path to a fasta file containing adapter sequences
  adapter_detection_thread: 10         # Set the thread number for the adapter checking step (int)
  kraken2_db: "/path/to/pluspfp16_k2_db"    # Fill in /dev/shm if you can copy the k2d files to this directory and set kraken2_memory_mapping: "yes"
  kraken2_thread: 20                   # Set the thread number for Kraken2-based contig taxonomic classification (int)
  kraken2_memory_mapping: "no"         # Fill in "yes" if you want to use memory mapping mode or "no" to turn this mode off.
  taxonomic_group: "Viridiplantae"     # Fill in the target taxonomic group from which contigs should be collected
  org_ctg_identification: "yes"        # Fill in "yes" to remove cp- and mtDNA contigs or "no" to include organellar DNA in the assembly 
  reference_organellar_sequences: "/path/to/mt.cl.fasta" # Path to a fasta file containing reference cp- and mtDNA sequences
  blastn_thread: 20                    # Set the thread number for BLASTn-based organellar contig removal.

# --- 6. Reference-guided contig correction and scaffolding (nohic-asm) -----------------------#
asm:
  contigs: ""                     # [chained] By default, take decontaminated contigs from nohic-clean
  reference_genome: ""            # [chained] By default, take the polished synref from nohic-refpolish
  out_dir: "CAMA-C-2.asm"           # Name the output directory
  out_prefix: "CAMA-C-2" # Set the output prefix
  run_craq: "yes"                 # Fill in "yes" to enable CRAQ-based chimeric contig breaking or "no" to turn this step off.
  craq_threads: 15                # Note: the number for this step should be 5-6 fewer threads compared to other steps of nohic-asm. 
  ignore_het: "no"                # Fill in "yes" to set the CRAQ's minimum clip rate to 0.55 
  run_inspector: "yes"            # Fill in "yes" to enable Inspector-based contig correction or "no" to turn this step off.
  inspector_threads: 20           # Fill in the thread number for Inspector (int)
  run_ragtag_correct: "yes"       # Fill in "yes" to enable reference-guided contig correction by RagTag or "no" to turn this step off.
  ragtag_threads: 20              # Fill in the thread number for RagTag-based correction and scaffolding (int)
  preset: "luck"                  # Choose RagTag-based correction preset, including "draft" / "luck" / "standard" / "aggressive" / "raw" (default: "luck")
  run_gap_closing: "yes"          # Fill in "yes" to enable gap closing or "no" to turn this step off.
  gap_closing_threads: 20         # Fill in the thread number for gap closing (int)

# --- 7. Assembly evaluation (nohic-eval) -----------------------------------------#
# We will use the public assembly of CAMA-C-2 as the reference genome to evaluate our newly-scaffolded assembly.
eval:
  assembly: ""                    # [chained] By default, take the final assembly from nohic-asm
  reference_genome: "/path/to/GCA_946406975.1_CAMA-C-2.PacbioHiFiAssembly_genomic.ed.SELECTED.fa"            
  out_dir: "CAMA-C-2.eval"          # Name the output directory
  contiguity_evaluation_tool: "quast"    # Choose the tool for contiguity evaluation ("gfastats", "quast", or "no" to turn the step off)
  contiguity_threads: 20          # Set the thread number for contiguity evaluation (int)
  gene_space_compl_eval_tool: "compleasm"   # Choose the tool for gene-space completeness evaluation ("compleasm", "busco", or "no" to turn the step off)
  gene_space_compl_eval_threads: 20 # Set the thread number for gene-space completeness evaluation (int)
  lineage: "brassicales"            # Set the BUSCO lineage
  odb: "odb12"                      # Set the version of BUSCO's OrthoDB
  busco_out_prefix: ""    # Set the output prefix (only used with busco)
  run_craq: "yes"                   # Fill in "yes" to calculate S- and R-AQI by CRAQ or "no" to turn this step off.
  craq_threads: 15        #  Note: the number for this step should be 5-6 fewer threads compared to other steps of nohic-eval. 
  run_inspector: "yes"    # Fill in "yes" to calculate QV by Inspector or "no" to turn this step off.
  inspector_threads: 20   # Fill in the thread number for Inspector (int)
  run_viz: "yes"          # Fill in "yes" to draw a dot plot showing mappings between the target and reference genome or "no" to turn this step off.
  minimap2_preset: "asm5" # Set Minimap2 preset (can be "asm5", "asm10", "asm20")
  viz_threads: 20         # Fill in the thread number for dot plot generation (int)

  # SLURM settings for nohic-eval.
  # They only apply to the steps of this stage.
  # Since the evaluation steps of nohic-eval are independent, they will be sent to different nodes to be executed in parallel.
  use_slurm: "yes" # Fill in "no" if you don't want to use SLURM
  slurm:
    default:
      memory: "250G"              # Set your own memory requirement for SLURM jobs (e.g., "32000M" or "32G")
      partition: "<your_partition>"            # Set your own SLURM partition. Leave it empty ("") to let the SLURM site default decide
      account: "<your_account>"              # Set your own SLURM account. "" if your cluster does not use accounts
      wall_time: "24h"            # Set your own wall time for each evaluation step (e.g., "4h", "2d"; "" = partition default)
    # The SLURM settings above are for all evaluation steps. If you want different settings for particular steps you can use the keys below.
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

After editing the config file, you can execute the noHiC pipeline as follows. 

```bash
snakemake -s /path/to/noHiC-Snakemake/workflow/Snakefile \                 
             --configfile path/to/noHiC-Snakemake/config/nohic.yaml \
             --cores <thread_num>
```

If you want to use SLURM to run the steps of `nohic-eval` in parallel by sending the jobs in different nodes, prepare a `.sbatch` script as follows.

```bash
#! /bin/bash
#SBATCH --mem=<memory>
#SBATCH --cpus-per-task=<thread_num>
#SBATCH --partition=<partition>
#SBATCH --mail-type=ALL
#SBATCH --mail-user=<email>

# Note that the memory and thread number set in this sbatch script will be use for nohic-refpick, -refpolish, -clean, and -asm.
# nohic-eval will send the jobs to different nodes with resource requirements set in the nohic.yaml file. 

# Change to your working directory containing example A. thaliana input files (not the noHiC-Snakemake directory)  
cd /path/to/your/working/directory
# Run the pipeline
snakemake --snakefile /path/to/noHiC-Snakemake/workflow/Snakefile \
          --configfile /path/to/noHiC-Snakemake/config/nohic.yaml \
          --rerun-incomplete --executor slurm --jobs 5 --local-cores ${SLURM_CPUS_PER_TASK}
```

## Outputs

Each stage writes into its own directory, named in the config. The main output files in each directory are as follows.

```
CAMA-C-2.refpick/CAMA-C-2.synref.fa → the synref of CAMA-C-2
CAMA-C-2.refpolish/CAMA-C-2.synref.hypo.fasta → the polished synref 
CAMA-C-2.clean/4_assembly_decontamination/CAMA-C-2.asm.bp.p_ctg.pure.fa → the clean CAMA-C-2 contigs
CAMA-C-2.asm/5_Gap_closing/CAMA-C-2.craq.inspector.rt_corr.scf.tgs.fa → final assembly (will be in CAMA-C-2.asm/4_Scaffolding if gap closing is turned off)
CAMA-C-2.eval/1_Contiguity_metrics/report.tsv → QUAST contiguity metrics of the final assembly
CAMA-C-2.eval/2_Gene_space_completeness/summary.txt → compleasm main output for gene space completeness
CAMA-C-2.eval/3_CRAQ/runAQI_out/out_final.Report → the R- and S-AQI (regional- and structural assembly quality index) can be found here
CAMA-C-2.eval/4_Inspector/summary_statistics → the QV can be found here
CAMA-C-2.eval/5_Visualization/query_to_reference.paf.png → the generated dot plot
```

The name of the final assembly reflects which `nohic-asm` steps ran: the prefix picks up `.craq`,
`.inspector`, `.rt_corr` for each enabled correction step, then `.scf`, then `.tgs` if
gap closing ran. 

Every rule writes a `.log` file next to its outputs, containing the exact
command line that was executed.

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
