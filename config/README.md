# Configuration

Everything the workflow needs is in one file: [`nohic.yaml`](nohic.yaml). It is passed to
`workflow/Snakefile`, which splits it into the five sub-workflow configs.

## Conventions used throughout the config file

Follow these conventions when editing the config file:

- **Switches** take `"yes"` / `"no"` to turn an option or a computational task on/off.
- **`[chained]` keys** in an assembly stage are filled in automatically from the preceding stage or from the `global:` section. Leave them as `""`. Only fill in one of these keys if you want to use a different input file; your manually provided inputs always take precedence over the defaults.
- We highly recommend **using absolute paths** when filling in your inputs.
- You must **use distinct output directory names** for the five assembly stages of the workflow (`refpick`, `refpolish`, `clean`, `asm`, and `eval`).

---

## Section 1. `stages:` — Choose which sub-workflows to run

| Key | Sub-workflow | Main tasks |
|---|---|---|
| `refpick` | `nohic-refpick.c.smk` | Build (and patch) the synref using the provided pangenome graph |
| `refpolish` | `nohic-refpolish.c.smk` | Polish the synref or a real reference genome |
| `clean` | `nohic-clean.c.smk` | Decontaminate the target contig assembly |
| `asm` | `nohic-asm.c.smk` | Correct and scaffold the target contig assembly |
| `eval` | `nohic-eval.slurm.c.smk` | Check the quality of the final assembly |

A stage set to `"yes"` **must** have its own config section further down in the file.

## Section 2. `global:` — Inputs shared by several stages

| Key | Used by stage | Notes |
|---|---|---|
| `nohic_env_path` | All five stages | Path to the downloaded noHiC environment containing the tools. |
| `reads` | `refpick`, `refpolish`, `asm`, and `eval` | Path to your error-corrected long reads (`.fastq`, may be gzipped). |
| `sequencing_platform` | `asm` and `eval` | Your sequencing platform. Fill in one of the following values: `clr`, `hifi`, `ont`, `corrected_clr`, `corrected_ont`. |
| `sequencing_coverage` | `asm` and `eval` | The estimated sequencing coverage (int). |

---

## Section 3. `refpick:` — Building the synref for your target genome (`nohic-refpick`)

| Key | Type | Description |
|---|---|---|
| `seq_file` | path | *[chained]* Reads for k-mer counting; defaults to `global: reads`. You can also fill in the path to a FASTA file containing the contigs of your target genome. |
| `kmer_length` | int | K-mer length (bp) for KMC-based k-mer counting. |
| `memory` | int | Memory (in GB) for KMC-based k-mer counting. |
| `kmc_mode` | str | Depends on `seq_file`. Fill in `"fq"` for FASTQ input or `"fm"` for FASTA input. |
| `prefix` | str | Basename for all outputs of `nohic-refpick`. |
| `kmc_out_dir` | path | Output directory of the `nohic-refpick` stage. Must be unique across stages. |
| `kmc_threads` | int | Number of threads for KMC (default: 1). |
| `gbz` | path | Path to a pangenome graph in GBZ format. |
| `hapl` | path | Path to the `.hapl` index of your pangenome graph. |
| `vg_threads` | int | Number of threads for the haplotype sampling and synref extraction steps (default: 1). |
| `patch_synref` | str | Fill in `"yes"` or `"no"`. Patches the synref using sequence from a donor genome. |
| `donor_genome` | path | **Required when `patch_synref: "yes"`.** Path to a high-quality donor genome for synref patching (ideally a gapless genome). |
| `patch_threads` | int | Number of threads for synref patching (default: 1). |

## Section 4. `refpolish:` — Polishing your reference genome (`nohic-refpolish`)

| Key | Type | Description |
|---|---|---|
| `synref` | path | *[chained]* Takes the synref from `nohic-refpick` by default. You can also fill in the path to your own reference genome. |
| `mapping_preset` | str | minimap2 preset used to map the reads of your target genome to the reference. Values can be `map-pb`, `map-hifi`, `map-ont`, or `map-iclr`. |
| `threads` | int | Number of threads for `nohic-refpolish` (default: 1). |
| `polish_tool` | str | The polishing tool to use. Fill in either `"hypo"` or `"racon"` (recommended: `"hypo"`). |
| `coverage` | int | The estimated coverage of the reads on the reference genome. Used when `polish_tool: "hypo"`. |
| `genome_size` | str | The estimated reference genome size (e.g., `"720m"`, `"1g"`). Required when `polish_tool: "hypo"`. |
| `out_dir` | path | Output directory of the `nohic-refpolish` stage. |
| `prefix` | str | Basename of the polished reference. |

## Section 5. `clean:` — Decontaminating your target contig assembly (`nohic-clean`)

| Key | Type | Description |
|---|---|---|
| `contig_assembly` | path | Path to the target contig assembly to clean. Its basename (i.e., without `.fa`/`.fasta`/`.fna`) becomes the sample name used in every output file of this stage. |
| `out_dir` | path | Output directory of the `nohic-clean` stage. |
| `adapters` | path | Path to a FASTA file containing the adapter sequences to screen for. |
| `adapter_detection_thread` | int | Number of threads for the adapter detection step (default: 1). |
| `kraken2_db` | path | Path to a downloaded Kraken2 database directory. Fill in `/dev/shm` if `kraken2_memory_mapping: "yes"`; in this case, the downloaded Kraken2 database files (`*.k2d`) must be in `/dev/shm`. |
| `kraken2_thread` | int | Number of threads for Kraken2 (default: 1). |
| `kraken2_memory_mapping` | str | Fill in `"yes"` to use Kraken2's memory-mapping mode or `"no"` to turn this mode off. |
| `taxonomic_group` | str | The clade to **keep** (e.g., `Viridiplantae`). Contigs whose Kraken2 lineage does not contain this string are treated as contaminants. |
| `org_ctg_identification` | str | Fill in `"yes"` to remove organellar (mitochondrial/plastid) contigs via BLASTn or `"no"` to turn this step off. |
| `reference_organellar_sequences` | path | Required when `org_ctg_identification: "yes"`. Path to a FASTA file containing the reference organellar sequences used as the BLAST database. |
| `blastn_thread` | int | Number of threads for BLASTn (default: 1). |

> [!NOTE]
> The adapter check is a hard gate: if any adapter is found in your contigs, the workflow
> stops and points you to `1_adapter_check/{sample}.adapter_positions.bed`.

## Section 6. `asm:` — Target contig correction, scaffolding, and gap closing (`nohic-asm`)

| Key | Type | Description |
|---|---|---|
| `contigs` | path | *[chained]* Takes the decontaminated contigs from `nohic-clean` by default. |
| `reference_genome` | path | *[chained]* Takes the polished synref from `nohic-refpolish` (or the synref from `nohic-refpick` if `nohic-refpolish` is off) by default. You can also specify the path to a real reference genome here. |
| `out_dir` | path | Output directory of the `nohic-asm` stage. |
| `out_prefix` | str | Basename of the outputs. |
| `run_craq` | str | Fill in `"yes"` to turn on CRAQ-based chimeric contig breaking or `"no"` to turn this step off. |
| `craq_threads` | int | Number of threads for CRAQ; should be 5–6 lower than for the other steps (default: 1). |
| `ignore_het` | str | Filling in `"yes"` lowers the CRAQ clipped-read threshold from 0.75 to 0.55. Use it when your contigs contain many heterozygous misjoins. Fill in `"no"` to use the default value (0.75). |
| `run_inspector` | str | Fill in `"yes"` to turn on Inspector-based misassembly detection and correction or `"no"` to turn this step off. |
| `inspector_threads` | int | Number of threads for Inspector (default: 1). |
| `run_ragtag_correct` | str | Fill in `"yes"` to turn on reference-guided contig correction with `RagTag correct` or `"no"` to turn this step off. |
| `ragtag_threads` | int | Number of threads for `RagTag correct` and `RagTag scaffold` (default: 1). |
| `preset` | str | Aggressiveness of `RagTag correct` — see the table below (default: `"luck"`). |
| `run_gap_closing` | str | Fill in `"yes"` to turn on TGS-GapCloser or `"no"` to turn this step off. |
| `gap_closing_threads` | int | Number of threads for gap closing (default: 1). |

### `RagTag correct` presets

See the detailed descriptions of the presets in our [preprint](https://doi.org/10.64898/2026.03.17.712436).

| `preset` | Behavior | Use case |
|---|---|---|
| `draft` | Uses the default settings of `RagTag correct`. | When you want an initial assembly without much correction. |
| `luck` | Sets the window size for read-based misassembly validation to 45000 and removes short alignments (< 1000 bp) between the target contigs and the reference genome (default preset). | A balanced preset for when you want more aggressive contig correction but don't want to force the target genome's sequence structure to follow the reference genome too closely. |
| `standard` | Similar to `luck`, but uses `nucmer` to align your contigs to the reference genome. | Use this preset when you have a high-quality (possibly gapless/T2T) reference genome that is genetically close to your target genome, because this preset strictly forces the sequence structure of the target genome to follow the reference. |
| `aggressive` | Similar to `standard`, but with a lower alignment merging distance of 50000 bp. | Even stricter than `standard`. Use it only when you detect misjoins in your contigs that are very hard to break. |
| `raw` | `nucmer` aligner with **no read validation**. | Use this preset when you want to break the contigs at every point where they disagree with the reference genome (not recommended). |

> [!NOTE]
> `RagTag correct` only accepts `hifi`, `ont`, `corrected_clr`, or `corrected_ont` as the
> sequencing platform; raw `clr` is not supported by this step.

## Section 7. `eval:` — Final assembly QC (`nohic-eval`)

| Key | Type | Description |
|---|---|---|
| `assembly` | path | *[chained]* Takes the final assembly from `nohic-asm` by default. |
| `reference_genome` | path | *[chained]* Takes the synref from `nohic-refpick` or `nohic-refpolish` by default. You can also fill in the path to a real reference genome to compare against. Required when QUAST or the dot plot visualization is enabled. |
| `out_dir` | path | Output directory of the `nohic-eval` stage. |
| `contiguity_evaluation_tool` | str | The tool used to calculate contiguity metrics. Fill in `"gfastats"`, `"quast"`, or `"no"` (to turn this step off). Use `"gfastats"` when you don't need the NGA50 and auNGA values. |
| `contiguity_threads` | int | Number of threads for the contiguity metric calculations (default: 1). |
| `gene_space_compl_eval_tool` | str | The tool used to evaluate gene-space completeness. Fill in `"compleasm"` (recommended), `"busco"`, or `"no"` (to turn this step off). |
| `gene_space_compl_eval_threads` | int | Number of threads for the gene-space completeness evaluation (default: 1). |
| `lineage` | str | The BUSCO/compleasm lineage, e.g., `"poales"`, `"embryophyta"`, `"eukaryota"`. |
| `odb` | str | The OrthoDB release, e.g., `"odb12"`. |
| `busco_out_prefix` | str | Output prefix for BUSCO. Used when `gene_space_compl_eval_tool: "busco"`. |
| `run_craq` | str | Fill in `"yes"` to turn on CRAQ-based evaluation (to obtain the R- and S-AQI values) or `"no"` to turn this step off. |
| `craq_threads` | int | Number of threads for CRAQ; should be 5–6 lower than for the other steps (default: 1). |
| `run_inspector` | str | Fill in `"yes"` to obtain the Inspector QV and misassembly report or `"no"` to turn this step off. |
| `inspector_threads` | int | Number of threads for Inspector (default: 1). |
| `run_viz` | str | Fill in `"yes"` to draw a dot plot of the target assembly against the reference or `"no"` to turn this step off. |
| `minimap2_preset` | str | minimap2 preset for the dot plot mapping, e.g., `"asm5"`. |
| `viz_threads` | int | Number of threads for the dot plot visualization. |

> [!NOTE]
> `compleasm` is run from a **sibling** environment of `nohic_env_path`: if the environment
> is `/path/to/noHiC-Snakemake/workflow/envs/noHiC`, compleasm is expected at
> `/path/to/noHiC-Snakemake/workflow/envs/compleasm`. BUSCO runs from the main noHiC environment.

## Using SLURM in `nohic-eval`

Only the evaluation stage submits jobs. `use_slurm: "yes"` attaches SLURM resources to its
heavy rules.

```yaml
eval:
  # ...
  use_slurm: "yes"
  slurm:
    default:
      memory: "250G"                  # 32000 (MB if you only fill in an int), "32000M", "32G", ...; "" = cluster default
      partition: "<your_partition>"   # "" = let the SLURM site default decide
      account: "<your_account>"       # "" = your cluster does not use accounts
      wall_time: "24h"                # 120 (minutes if you only fill in an int), "4h", "2d"; "" = partition default
    rules:
      GFAstats: {memory: "5G", partition: "<your_other_partition>", account: "", wall_time: ""}
      QUAST: {...}
      busco: {...}
      compleasm: {...}
      craq_based_evaluation: {...}
      inspector_based_evaluation: {...}
      assembly_to_reference_mapping: {...}
```

Rule names under `slurm: rules:` are the unprefixed names as written in
`nohic-eval.slurm.c.smk`. An empty per-rule field falls back to `default`. Rules that are
not listed use `default` entirely.
