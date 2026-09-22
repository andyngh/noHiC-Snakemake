# Configuration

Everything the workflow needs is in one file: [`nohic.yaml`](nohic.yaml). It is handed to
`workflow/Snakefile`, which splits it into the five sub-workflow configs.

## Conventions used throughout the config file

You should follow the following conventions while editing the config file.

- **Switches** take `"yes"` / `"no"` to turn on/off an option or a computational task.
- **A `[chained]` key** in an assembly stage is filled in automatically from the stage before it or from the `global:` key. Leave them as `""`. You should only fill in one of these keys if you want to use a different input file. Your manually provided inputs will always win the defaults.
- We highly recommend **using absolute paths** when fill your inputs.
- You must **use distinct output directory names** for the 5 assembly stages in the workflow (`refpick`, `refpolish`, `clean`, `asm`, and `eval`).

---

## Section 1: `stages` — Choose which sub-workflows to run

| Key | Sub-workflow | Main Tasks |
|---|---|---|
| `refpick` | `nohic-refpick.c.smk` | build (and patch) the synref using a provided pangenome graph |
| `refpolish` | `nohic-refpolish.c.smk` | polish it the synref or a real reference genome |
| `clean` | `nohic-clean.c.smk` | Target contig assembly decontamination |
| `asm` | `nohic-asm.c.smk` | Target contig assembly correction and scaffolding |
| `eval` | `nohic-eval.slurm.c.smk` | Final assembly quality check |

A stage set to `"yes"` **must** have a config section of its own further down the file.

## Section 2: `global:` — Inputs shared by several stages

| Key | Used by stage | Notes |
|---|---|---|
| `nohic_env_path` | all five stages | Path to the downloaded noHiC environment holding the tools. |
| `reads` | `refpick`, `refpolish`, `asm`, and `eval` | Path to your error-corrected long reads (`.fastq`, may be gzipped). |
| `sequencing_platform` | `asm` and `eval` | Set your sequencing platform by filling in one of the following values: `clr`, `hifi`, `ont`, `corrected_clr`, `corrected_ont`. |
| `sequencing_coverage` | `asm` and `eval` | Provide the estimated sequencing coverage (int). |

---

## Section 3: `nohic-refpick:` — Building the synref for your target genome

| Key | Type | Description |
|---|---|---|
| `seq_file` | path | *[chained]* Reads for k-mer counting; defaults to `global: reads`. You can also fill the path to a fasta file containing the contigs of your target genome. |
| `kmer_length` | int | Set the kmer length (bp) for KMC-based kmer counting. |
| `memory` | int | Set memory (in GB) for KMC-based kmer counting. |
| `kmc_mode` | str | Depends on the key `seq_file`. Fill in "fq" for FASTQ input and "fm" for FASTA. |
| `prefix` | str | Basename for all outputs of `nohic-refpick`. |
| `kmc_out_dir` | path | Output directory of the `nohic-refpick` stage. Must be unique across stages. |
| `kmc_threads` | int | Set KMC thread number (default: 1). |
| `gbz` | path | Path to a pangenome graph in GBZ format. |
| `hapl` | path | Path to the `.hapl` index of your pangenome graph. |
| `vg_threads` | int | Threads for haplotype sampling and synref extraction steps (default: 1). |
| `patch_synref` | str | Fill in "yes" or "no". Patch the synref using sequence from a donor genome. |
| `donor_genome` | path | **Required when `patch_synref: "yes"`.** Path to a high-quality donor genome for synref patching (ideally a gapless genome). |
| `patch_threads` | int | Threads for synref patching (default: 1). |

## Section 4. `nohic-refpolish:` — Polishing your reference genome

| Key | Type | Description |
|---|---|---|
| `synref` | path | *[chained]* takes the synref from `nohic-refpick` by default. You can put in a path to your own reference genome. |
| `mapping_preset` | str | Set minimap2 preset to map reads from your target genome to the reference. Values can be `map-pb`, `map-hifi`, `map-ont`, `map-iclr`. |
| `threads` | int | Threads number for `nohic-refpolish` (default: 1). |
| `polish_tool` | str | Choose which polishing tool to use. Fill in either "hypo" or "racon" (recommended: "hypo"). |
| `coverage` | int | Fill in the estimated coverage of the reads to the reference genome. For `polish_tool: "hypo"`. |
| `genome_size` | str | Fill in the estimated reference genome size (e.g. "720m", "1g"). Required when `polish_tool: "hypo"`. |
| `out_dir` | path | Output directory of the `nohic-refpolish` stage. |
| `prefix` | string | Set the basename of the polished reference. |

## Section 5. `nohic-clean:` — Decontamination of your target contig assembly

| Key | Type | Description |
|---|---|---|
| `contig_assembly` | path | Path to your target contig assembly to clean. Its basename (i.e., minus `.fa`/`.fasta`/`.fna`) will become the sample name used in every output file of this stage. |
| `out_dir` | path | Output directory of the `nohic-clean` stage. |
| `adapters` | path | Path to a fasta file holding adapter sequences to screen for. |
| `adapter_detection_thread` | int | Threads for adapter detection step (default: 1). |
| `kraken2_db` | path | Path to a downloaded Kraken2 database directory. Fill in `/dev/shm` if `kraken2_memory_mapping: "yes"`. In this case, the downloaded Kraken2 database (`*.k2d`) must be in `/dev/shm`. |
| `kraken2_thread` | int | Set Kraken2 threads (default: 1). |
| `kraken2_memory_mapping` | str | Use Kraken2's memory mapping mode when this is "yes". Fill in "no" to turn this mode off. |
| `taxonomic_group` | str | The clade to **keep** (e.g., `Viridiplantae`). Contigs whose Kraken2 lineage does not contain this string are treated as contaminants. |
| `org_ctg_identification` | str | Fill in "yes" to remove organellar (mitochondrial/plastid) contigs via BLASTn. Fill in "no" to turn this step off. |
| `reference_organellar_sequences` | path | Required when `org_ctg_identification: "yes"`. Path to a fasta file containing reference organellar sequences used as the BLAST database. |
| `blastn_thread` | int | Set BLASTn threads (default: 1). |

> **Note:**
> The adapter check is a hard gate: if any adapter is found in your contigs, the workflow stops and points
> you at `1_adapter_check/{sample}.adapter_positions.bed`.

## Section 6. `nohic-asm:` — Target correction, scaffolding, and gap closing

| Key | Type | Description |
|---|---|---|
| `contigs` | path | *[chained]* Takes decontaminated contigs from `nohic-clean` by default. |
| `reference_genome` | path | *[chained]* Takes polished synref from `nohic-refpolish` (or from `nohic-refpick` if `nohic-refpolish` is off) by default. You can also specify a path to a real reference genome here. |
| `out_dir` | path | Output directory of the `nohic-asm` stage. |
| `out_prefix` | str | Set basename of the outputs. |
| `run_craq` | str | Fill in "yes" to turn on CRAQ-based chimeric contig breaking. Fill in "no" to turn this step off. |
| `craq_threads` | int | Set thread number for CRAQ (should be 5-6 threads lower than other steps) (default: 1). |
| `ignore_het` | str | Fill in "yes" will lower the CRAQ clipped-read threshold from 0.75 to 0.55. Use it in the cases where your contigs contain many heterozygous misjoins. Fill in "no" to use the default value (0.75). |
| `run_inspector` | str | Fill in "yes" to turn on Inspector-based misassembly detection and correction. Fill in "no" to turn this step off. |
| `inspector_threads` | int | Set thread number for Inspector (default: 1). |
| `run_ragtag_correct` | str | Fill in "yes" to turn on reference-guided contig correction with `RagTag correct`. Fill in "no" to turn this step off. |
| `ragtag_threads` | int | Set thread number for `RagTag correct` and `RagTag scaffold` (default: 1). |
| `preset` | str | Choose `RagTag correct` aggressiveness — see the table below (default: "luck"). |
| `run_gap_closing` | str | Fill in "yes" to turn on TGS-GapCloser. Fill in "no" to turn this step off. |
| `gap_closing_threads` | int | Set thread number for gap closing (default: 1). |

RagTag correct presets:

See the detailed descriptions of the presets in our [preprint](https://doi.org/10.64898/2026.03.17.712436).

| `preset` | Behaviour | Use case |
|---|---|---|
| `draft` | Uses default settings from `RagTag correct` | When you want to get an initial assembly without much correction. |
| `luck` | Sets the window size in read-based misassembly validation to 45000 and remove short alignments (< 1000 bp) between target contigs and reference genome (default preset). | This is a balanced preset used when you want to increase the aggressiveness in contig correction but don't want to force the target genome sequence structure to follow the reference genome too much. |
| `standard` | Similar to `luck` but uses `nucmer` to align your contigs to the reference genome. | Use this preset when you have a high-quality (can be gapless, T2T) reference genome that are genetically close to your target genome because this preset strictly force the sequence structure of the target genome to follow the reference. |
| `aggressive` | Similar to `standard` but has a lower alignment merging distance of 50000 bp. | This preset is even stricter than `standard`. Use it only when you detect very-hard-to-break misjoins in your contigs. |
| `raw` | `nucmer` aligner with **no read validation**. | Use this preset when you want to break the contigs at every point showing disagreements between them and the reference genome (not recommended). |

>**Note:**
>`RagTag correct` only accepts `hifi`, `ont`, `corrected_clr` or `corrected_ont` as sequencing platform; raw `clr` is not supported by this step.

## Section 7. `nohic-eval:` — Final assembly QC

| Key | Type | Description |
|---|---|---|
| `assembly` | path | *[chained]* Takes final assembly from `nohic-asm` by default. |
| `reference_genome` | path | *[chained]* Takes synref from `nohic-refpick` or `nohic-refpolish` by default. You can also fill in a path to a real reference genome to compare against. Required when QUAST or the dot plot visualization is enabled. |
| `out_dir` | path | Output directory of the `nohic-eval` stage. |
| `contiguity_evaluation_tool` | str | Choose a tool for contiguity metric calculations. Fill in "gfastats", "quast", or "no" (to turn off this step). Use "gfastats" when you don't want to calculate the NGA50 and auNGA values.|
| `contiguity_threads` | int | Set the thread number for contiguity metric calculations (default: 1). |
| `gene_space_compl_eval_tool` | str | Choose a tool for evaluating gene-space completeness. Fill in "compleasm" (recommended), "busco", or "no" (to turn off this step). |
| `gene_space_compl_eval_threads` | int | Set the thread number for evaluating gene-space completeness (default: 1). |
| `lineage` | str | Fill in BUSCO/compleasm lineage. For examples, `"poales"`, `"embryophyta"`, `"eukaryota"`... |
| `odb` | str | Fill in OrthoDB release, e.g. "odb12". |
| `busco_out_prefix` | str | Set the output prefix for BUSCO. Used if `gene_space_compl_eval_tool: "busco"`. |
| `run_craq` | str | Fill in "yes" to turn on CRAQ-based evaluation (to obtain the R- and S-AQI values). Fill in "no" to turn this step off. |
| `craq_threads` | int | Set thread number for CRAQ (should be 5-6 threads lower than other steps) (default: 1). |
| `run_inspector` | str | Fill in "yes" to obtain Inspector QV and misassembly report. Fill in "no" to turn this step off. |
| `inspector_threads` | int | Set thread number for Inspector (default: 1). |
| `run_viz` | str | Fill in "yes" to draw an target-assembly-vs-reference dot plot. Fill in "no" to turn this step off. |
| `minimap2_preset` | str | minimap2 preset for the dot plot mapping, e.g. "asm5". |
| `viz_threads` | int | Set thread number for dot plot visualization. |

>**Note:**
>`compleasm` is run from a **sibling** environment of `nohic_env_path`: if the venv is
>`/path/to/noHiC-Snakemake/envs/noHiC`, compleasm is expected at `/path/to/noHiC-Snakemake/envs/compleasm`. BUSCO runs from the
>main noHiC environment.

## Using SLURM in `nohic-eval`

Only the evaluation stage submits jobs. `use_slurm: "yes"` attaches SLURM resources to its heavy rules.

```yaml
  use_slurm: "yes"
  slurm:
    default:
      memory: "250G"        # 32000 (in MB if you only fill in an int), "32000M", "32G", ... "" = cluster default
      partition: "<your_partition>"      # ""  = lets the SLURM site default decide
      account: "<your_account>"        # "" = your cluster does not use accounts
      wall_time: "24h"      # 120 (in minute if you only fill in an int), "4h", "2d"; "" = partition default
    rules:
      GFAstats: {memory: "5G", partition: "<your_other_partition>", account: "", wall_time: ""}
      QUAST: {...}
      busco: {...}
      compleasm: {...}
      craq_based_evaluation: {...}
      inspector_based_evaluation: {...}
      assembly_to_reference_mapping: {...}
```

Rule names under `slurm: rules:` are the unprefixed names as written in `nohic-eval.slurm.c.smk`. An empty per-rule field falls back to `default`. Rules not listed use `default` entirely.

---

