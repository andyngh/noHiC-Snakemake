# Configuration

## Conventions for parsing command-line (CI) arguments

Follow these conventions when parsing the CI arguments:

- **Switch arguments** take `"yes"` / `"no"` to turn an option or a computational task on/off.
- **`[chained]` arguments** in an assembly stage are filled in automatically from the preceding stage or from the `[global]` section. Leave them as `""`. Only fill in one of these arguments if you want to use a different input file; your manually provided inputs always take precedence over the defaults.
- **`[Required]` arguments** must be filled in manually.
- We highly recommend **using absolute paths** when filling in your inputs.
- You must **use distinct output directory names** for the five assembly stages of the workflow (`refpick`, `refpolish`, `clean`, `asm`, and `eval`).

---

## Section 1. `[stages]` - Choose which sub-workflows to run

| Config keys | CI arguments | Main tasks |
|---|---|---|
| `refpick` | `run_refpick` | Build (and patch) the synref using the provided pangenome graph (default: yes). |
| `refpolish` | `run_refpolish` | Polish the synref or a real reference genome (default: yes). |
| `clean` | `run_clean` | Decontaminate the target contig assembly (default: yes). |
| `asm` | `run_asm` | Correct and scaffold the target contig assembly (default: yes). |
| `eval` | `run_eval` | Check the quality of the final assembly (default: yes). |

A stage set to `"yes"` **must** have its own `[Required]` arguments filled in.

## Section 2. `[global]` - Inputs shared by several stages

| Config keys | CI arguments | Notes |
|---|---|---|
| `nohic_env_path` | `env` | Path to the downloaded noHiC environment containing the tools (automatically filled in by `setup.sh`). |
| `reads` | `reads` | *[Required]* Path to your error-corrected long reads (`.fastq`, may be gzipped). |
| `sequencing_platform` | `platform` | Your sequencing platform. Fill in one of the following values: `clr`, `hifi`, `ont`, `corrected_clr`, `corrected_ont` (default: hifi). |
| `sequencing_coverage` | `cov` | The estimated sequencing coverage (int). Default: 10. |
| `prefix` | `prefix` | *[Required]* Fill in your output prefix. |

---

## Section 3. `[refpick]` - Building the synref for your target genome

| Config keys | CI arguments | Description |
|---|---|---|
| `seq_file` | `pk_seq` | *[chained]* Reads for k-mer counting; defaults to `global: reads`. You can also fill in the path to a FASTA file containing the contigs of your target genome. |
| `kmer_length` | `pk_k` | K-mer length (bp) for KMC-based k-mer counting (default: 29). |
| `memory` | `pk_mem` | Memory (in GB) for KMC-based k-mer counting (default: 32). |
| `kmc_mode` | `pk_kmc_mode` | Depends on `seq_file`. Fill in `"fq"` for FASTQ input or `"fm"` for FASTA input (default: fq). |
| `prefix` | `pk_prefix` | *[chained]* Set outputs' prefix. Take "global: prefix" by default. |
| `kmc_out_dir` | `pk_out` | Output directory of the `nohic-refpick` stage. Must be unique across stages (default: Refpick.outdir). |
| `kmc_threads` | `pk_kmc_t` | Number of threads for KMC (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake |
| `gbz` | `pk_gbz` | *[Required]* Path to a pangenome graph in GBZ format. |
| `hapl` | `pk_hapl` | *[Required]* Path to the `.hapl` index of your pangenome graph. |
| `vg_threads` | `pk_vg_t` | Number of threads for the haplotype sampling and synref extraction steps (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake |
| `patch_synref` | `pk_patch` | Fill in `"yes"` or `"no"`. Patches the synref using sequence from a donor genome (default: no). |
| `donor_genome` | `pk_donor` | **Required when `patch_synref=yes`.** Path to a high-quality donor genome for synref patching (ideally a gapless genome). |
| `patch_threads` | `pk_patch_t` | Number of threads for synref patching (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake |

## Section 4. `[refpolish]` - Polishing your reference genome

| Config keys | CI arguments | Description |
|---|---|---|
| `synref` | `pl_ref` | *[chained]* Takes the synref from `nohic-refpick` by default. You can also fill in the path to your own reference genome. |
| `mapping_preset` | `pl_preset` | minimap2 preset used to map the reads of your target genome to the reference. Values can be `map-pb`, `map-hifi`, `map-ont`, or `map-iclr` (default: map-hifi). |
| `threads` | `pl_t` | Number of threads for `nohic-refpolish` (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake |
| `polish_tool` | `pl_tool` | The polishing tool to use. Fill in either `"hypo"` or `"racon"` (default: `"hypo"`). |
| `coverage` | `pl_cov` | *[chained]* The estimated coverage of the reads on the reference genome. Used when `polish_tool: "hypo"`. By default, take sequencing coverage from "global: sequencing_coverage". |
| `genome_size` | `pl_gsize` | *[Required]* The estimated reference genome size (e.g., `"720m"`, `"1g"`). Required when `polish_tool: "hypo"`. |
| `out_dir` | `pl_out` | Output directory of the `nohic-refpolish` stage (default: Refpolish.outdir). |
| `prefix` | `pl_prefix` | *[chained]* Basename of the polished reference. Take "global: prefix" by default. |

## Section 5. `[clean]` - Decontaminating your target contig assembly

| Config keys | CI arguments | Description |
|---|---|---|
| `contig_assembly` | `cl_ctg` | *[Required]* Path to the target contig assembly to clean. Its basename (i.e., without `.fa`/`.fasta`/`.fna`) becomes the sample name used in every output file of this stage. |
| `out_dir` | `cl_out` | Output directory of the `nohic-clean` stage (default: Clean.outdir). |
| `adapters` | `cl_adapters` | *[Required]* Path to a FASTA file containing the adapter sequences to screen for. |
| `adapter_detection_thread` | `cl_adapter_t` | Number of threads for the adapter detection step (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |
| `kraken2_db` | `cl_k2db` | *[Required]* Path to a downloaded Kraken2 database directory. Fill in `/dev/shm` if `kraken2_memory_mapping: "yes"`; in this case, the downloaded Kraken2 database files (`*.k2d`) must be in `/dev/shm`. |
| `kraken2_thread` | `cl_k2_t` | Number of threads for Kraken2 (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |
| `kraken2_memory_mapping` | `cl_k2_mmap` | Fill in `"yes"` to use Kraken2's memory-mapping mode or `"no"` to turn this mode off (default: no). |
| `taxonomic_group` | `cl_taxon` | The clade to **keep**. Contigs whose Kraken2 lineage does not contain this string are treated as contaminants. (default: Viridiplantae). |
| `org_ctg_identification` | `cl_org` | Fill in `"yes"` to remove organellar (mitochondrial/plastid) contigs via BLASTn or `"no"` to turn this step off (default: no). |
| `reference_organellar_sequences` | `cl_org_ref` | **Required when `cl_org=yes`**. Path to a FASTA file containing the reference organellar sequences used as the BLAST database. |
| `blastn_thread` | `cl_blast_t` | Number of threads for BLASTn (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |

> [!NOTE]
> The adapter check is a hard gate: if any adapter is found in your contigs, the workflow
> stops and points you to `1_adapter_check/{sample}.adapter_positions.bed`.

## Section 6. `[asm]` - Target contig correction, scaffolding, and gap closing

| Config keys | CI arguments | Description |
|---|---|---|
| `contigs` | `as_ctg` | *[chained]* Takes the decontaminated contigs from `nohic-clean` by default. |
| `reference_genome` | `as_ref` | *[chained]* Takes the polished synref from `nohic-refpolish` (or the synref from `nohic-refpick` if `nohic-refpolish` is off) by default. You can also specify the path to a real reference genome here. |
| `out_dir` | `as_out` | Output directory of the `nohic-asm` stage (default: Asm.outdir). |
| `out_prefix` | `as_prefix` | *[chained]* Basename of the outputs.  Take "global: prefix" by default. |
| `run_craq` | `as_craq` | Fill in `"yes"` to turn on CRAQ-based chimeric contig breaking or `"no"` to turn this step off (default: yes). |
| `craq_threads` | `as_craq_t` | Number of threads for CRAQ; should be 5–6 lower than for the other steps (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |
| `ignore_het` | `as_ignore_het` | Filling in `"yes"` lowers the CRAQ clipped-read threshold from 0.75 to 0.55. Use it when your contigs contain many heterozygous misjoins. Fill in `"no"` to use the default value (0.75) (default: no). |
| `run_inspector` | `as_inspector` | Fill in `"yes"` to turn on Inspector-based misassembly detection and correction or `"no"` to turn this step off (default: yes). |
| `inspector_threads` | `as_inspector_t` | Number of threads for Inspector (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |
| `run_ragtag_correct` | `as_ragtag` | Fill in `"yes"` to turn on reference-guided contig correction with `RagTag correct` or `"no"` to turn this step off (default: yes). |
| `ragtag_threads` | `as_ragtag_t` | Number of threads for `RagTag correct` and `RagTag scaffold` (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |
| `preset` | `as_preset` | Aggressiveness of `RagTag correct`. See the table below (default: `"luck"`). |
| `run_gap_closing` | `as_gapclose` | Fill in `"yes"` to turn on TGS-GapCloser or `"no"` to turn this step off (default: yes). |
| `gap_closing_threads` | `as_gapclose_t` | Number of threads for gap closing (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |

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

## Section 7. `[eval]` - Final assembly QC

| Config keys | CI arguments | Description |
|---|---|---|
| `assembly` | `ev_asm` | *[chained]* Takes the final assembly from `nohic-asm` by default. |
| `reference_genome` | `ev_ref` | *[chained]* Takes the synref from `nohic-refpick` or `nohic-refpolish` by default. You can also fill in the path to a real reference genome to compare against. Required when QUAST or the dot plot visualization is enabled. |
| `out_dir` | `ev_out` | Output directory of the `nohic-eval` stage (default: Eval.outdir). |
| `contiguity_evaluation_tool` | `ev_contig_tool` | The tool used to calculate contiguity metrics. Fill in `"gfastats"`, `"quast"`, or `"no"` (to turn this step off). Use `"gfastats"` when you don't need the NGA50 and auNGA values. Default: quast. |
| `contiguity_threads` | `ev_contig_t` | Number of threads for the contiguity metric calculations (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |
| `gene_space_compl_eval_tool` | `ev_gene_tool` | The tool used to evaluate gene-space completeness. Fill in `"compleasm"` (recommended), `"busco"`, or `"no"` (to turn this step off). Default: compleasm. |
| `gene_space_compl_eval_threads` | `ev_gene_t` | Number of threads for the gene-space completeness evaluation (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |
| `lineage` | `ev_lineage` | The BUSCO/compleasm lineage, e.g., `"poales"`, `"embryophyta"`, ... (default: `eukaryota`). |
| `odb` | `ev_odb` | The OrthoDB release (default: `"odb12"`). |
| `busco_out_prefix` | `ev_busco_prefix` | *[chained]* Output prefix for BUSCO. Used when `gene_space_compl_eval_tool: "busco"`. Take "global: prefix" by default. |
| `run_craq` | `ev_craq` | Fill in `"yes"` to turn on CRAQ-based evaluation (to obtain the R- and S-AQI values) or `"no"` to turn this step off (default: yes). |
| `craq_threads` | `ev_craq_t` | Number of threads for CRAQ; should be 5–6 lower than for the other steps (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |
| `run_inspector` | `ev_inspector` | Fill in `"yes"` to obtain the Inspector QV and misassembly report or `"no"` to turn this step off (default: yes). |
| `inspector_threads` | `ev_inspector_t` | Number of threads for Inspector (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |
| `run_viz` | `ev_viz` | Fill in `"yes"` to draw a dot plot of the target assembly against the reference or `"no"` to turn this step off (default: yes). |
| `minimap2_preset` | `ev_mm2_preset` | minimap2 preset for the dot plot mapping (default: `asm5`). |
| `viz_threads` | `ev_viz_t` | Number of threads for the dot plot visualization (default: 1). This argument is filled automatically via the `--cores` or `----local-cores` arguments of snakemake. |

> [!NOTE]
> `compleasm` is run from a **sibling** environment of `nohic_env_path`: if the environment
> is `/path/to/noHiC-Snakemake/workflow/envs/noHiC`, compleasm is expected at
> `/path/to/noHiC-Snakemake/workflow/envs/compleasm`. BUSCO runs from the main noHiC environment.

## Using SLURM in `nohic-eval`

Only the evaluation stage submits jobs. `use_slurm: "yes"` attaches SLURM resources to its
heavy rules. Use the following CI arguments for SLURM setting.

| CI arguments | Defaults | Descriptions |
|---|---|---|
| `ev_slurm` | no | Fill in "yes" or "no" to use SLURM. |
| `slurm_mem` | 250G | Set the memory requirement for SLURM jobs (e.g., "32000M" or "32G"). |
| `slurm_partition` | '' | Set the SLURM partition. Leave it empty ("") to let the SLURM site default decide. |
| `slurm_account` | '' | Set the SLURM account. "" if your cluster does not use accounts. |
| `slurm_time` | 24h | Set the wall time for each evaluation step (e.g., "4h", "2d"; "" = partition default). |

The above settings are for every steps of `nohic-eval`. You can also set the resource requirements specifically for a step. Check the help message for details.

```bash
snakemake -s /path/to/noHiC-Snakemake/workflow/Snakefile --config help=yes
```
