# Configuration

Everything the workflow needs is in one file: [`nohic.yaml`](nohic.yaml). It is handed to
`workflow/Snakefile`, which splits it into the five sub-workflow configs.

## Conventions used throughout the config file

You should follow the following conventions while editing the config file.

- **Switches** take `"yes"` / `"no"` to turn on/off an option or a computational task.
- **A `[chained]` key** in an assembly stage is filled in automatically from the stage before it or from the `global:` key. Leave them as `""`. You should only fill in one of these keys if you want to use a different input file. Your manually provided inputs will always win the defaults.
- We highly recommend using **absolute paths** when fill your inputs.

---

## `stages:` — which sub-workflows to run

| Key | Sub-workflow | Purpose |
|---|---|---|
| `refpick` | `nohic-refpick.c.smk` | build the synthetic reference |
| `refpolish` | `nohic-refpolish.c.smk` | polish it |
| `clean` | `nohic-clean.c.smk` | adapter check + decontamination |
| `asm` | `nohic-asm.c.smk` | correction / scaffolding / gap closing |
| `eval` | `nohic-eval.slurm.c.smk` | evaluation |

A stage set to `"yes"` must have a section of its own further down the file. Removing the
whole `stages:` block is allowed and means "run nothing" (every switch defaults to `no`).

## `global:` — values shared by several stages

| Key | Copied into | Notes |
|---|---|---|
| `nohic_env_path` | all five stages | Path to the Python venv holding the tools. **Every enabled stage must end up with the same value** — `shell.prefix` is global in Snakemake, so the last one parsed would otherwise be used by every job. The workflow aborts if they differ. |
| `reads` | `refpick.seq_file`, `refpolish.reads`, `asm.reads`, `eval.reads` | Error-corrected long reads (FASTQ, may be gzipped). |
| `sequencing_platform` | `asm`, `eval` | One of `clr`, `hifi`, `ont`, `corrected_clr`, `corrected_ont`. Decides the minimap2/CRAQ/Inspector/TGS-GapCloser presets. |
| `sequencing_coverage` | `asm`, `eval` | Integer; passed to CRAQ as `--sms_coverage`. |

---

## 1. `refpick:` — synthetic reference construction

| Key | Type | Description |
|---|---|---|
| `seq_file` | path | *[chained]* Reads for k-mer counting; defaults to `global: reads`. |
| `kmer_length` | int | KMC `-k`. `29` works well for HiFi. |
| `memory` | int | KMC `-m`, in GB. |
| `kmc_mode` | `fq`\|`fm` | `fq` for FASTQ input, `fm` for FASTA. |
| `prefix` | string | Basename for all outputs of this stage. |
| `kmc_out_dir` | path | Output directory of the stage. Must be unique across stages. |
| `kmc_threads` | int | KMC threads. |
| `gbz` | path | Pangenome graph in GBZ format. |
| `hapl` | path | Matching `.hapl` haplotype index (from `vg haplotypes -H`). |
| `vg_threads` | int | Threads for `vg haplotypes` and `vg paths`. |
| `patch_synref` | yes/no | Patch the synthetic reference against a donor genome with GPatch. |
| `donor_genome` | path | **Required when `patch_synref: "yes"`.** Assembled genome of a close relative. |
| `patch_threads` | int | Threads for minimap2/samtools during patching. |

**Result:** `{kmc_out_dir}/{prefix}.synref.patched.fasta` when patching is on, otherwise
`{kmc_out_dir}/{prefix}.synref.fa`. That file is what `refpolish` and `asm` chain from.

## 2. `refpolish:` — reference polishing

| Key | Type | Description |
|---|---|---|
| `synref` | path | *[chained]* Synthetic reference from `refpick`. |
| `reads` | path | *[global]* Reads used for polishing. |
| `mapping_preset` | string | minimap2 preset: `map-pb`, `map-hifi`, `map-ont`, `map-iclr`. |
| `threads` | int | Threads for minimap2, samtools and the polisher. |
| `polish_tool` | `hypo`\|`racon` | Which polisher to use. |
| `coverage` | int | HyPo `-c`. HyPo only. |
| `genome_size` | string | HyPo `-s`, e.g. `"720m"`. **Required when `polish_tool: "hypo"`.** |
| `out_dir` | path | Output directory of the stage. |
| `prefix` | string | Basename of the polished reference. |

**Result:** `{out_dir}/{prefix}.hypo.fasta` or `{out_dir}/{prefix}.racon.fasta`.

## 3. `clean:` — adapter screening and decontamination

| Key | Type | Description |
|---|---|---|
| `contig_assembly` | path | The contig assembly to clean (e.g. hifiasm output). Its basename, minus `.fa`/`.fasta`/`.fna`, becomes the sample name used in every output file of this stage. |
| `out_dir` | path | Output directory of the stage. |
| `adapters` | path | FASTA of adapter sequences to screen for. |
| `adapter_detection_thread` | int | Threads for `seqkit locate`. |
| `kraken2_db` | path | Kraken2 database directory. |
| `kraken2_thread` | int | Kraken2 threads. |
| `kraken2_memory_mapping` | yes/no | Use `--memory-mapping` (keeps the database on disk instead of loading it into RAM). Point `kraken2_db` at `/dev/shm/...` when this is `"yes"`. |
| `taxonomic_group` | string | The clade to **keep**, e.g. `Viridiplantae`. Contigs whose Kraken2 lineage does not contain this string are treated as contaminants. |
| `org_ctg_identification` | yes/no | Also remove organellar (mitochondrial/plastid) contigs via BLAST. |
| `reference_organellar_sequences` | path | **Required when `org_ctg_identification: "yes"`.** FASTA of reference organellar sequences; used as the BLAST database. |
| `blastn_thread` | int | BLASTn threads. |

**Result:** `{out_dir}/4_assembly_decontamination/{sample}.pure.fa`.

> The adapter check is a hard gate: if any adapter is found the workflow stops and points
> you at `1_adapter_check/{sample}.adapter_positions.bed`.
>
> The TaxonKit rule downloads the NCBI taxdump into `$HOME/.taxonkit/` on first use and
> leaves a marker at `Resources/taxonkit_db.done` in the working directory.

## 4. `asm:` — correction, scaffolding and gap closing

| Key | Type | Description |
|---|---|---|
| `contigs` | path | *[chained]* Decontaminated contigs from `clean`. |
| `reference_genome` | path | *[chained]* Polished reference from `refpolish` (or from `refpick` if `refpolish` is off). |
| `reads` | path | *[global]* Required as soon as any of CRAQ / Inspector / RagTag correct / gap closing is on. |
| `out_dir` | path | Output directory of the stage. |
| `out_prefix` | string | Basename of the outputs. |
| `run_craq` | yes/no | CRAQ-based chimeric contig breaking (`1_CRAQ/`). |
| `craq_threads` | int | CRAQ threads. |
| `ignore_het` | yes/no | `"yes"` lowers the clipped-read threshold from 0.75 to 0.55 — use it for highly heterozygous genomes. |
| `run_inspector` | yes/no | Inspector-based misassembly detection and correction (`2_Inspector/`). |
| `inspector_threads` | int | Inspector threads. |
| `run_ragtag_correct` | yes/no | Reference-guided contig correction with RagTag (`3_RagTag_correct/`). |
| `ragtag_threads` | int | Threads for RagTag correct **and** RagTag scaffold. |
| `preset` | string | RagTag correct aggressiveness — see the table below. |
| `run_gap_closing` | yes/no | TGS-GapCloser on the scaffolds (`5_Gap_closing/`). |
| `gap_closing_threads` | int | Threads for `seqkit fq2fa` and TGS-GapCloser. |

RagTag correct presets:

| `preset` | Behaviour |
|---|---|
| `draft` | minimap2 aligner, no extra filters — fastest, least invasive. |
| `luck` | `-v 45000 --remove-small` (default). |
| `standard` | nucmer aligner (`--maxmatch -l 100 -c 500`), `-v 45000 --remove-small`. |
| `aggressive` | as `standard` plus `-d 50000`. |
| `raw` | nucmer aligner, **no read validation** (reads are not passed to RagTag). |

Note that RagTag correct only accepts `hifi`, `ont`, `corrected_clr` or `corrected_ont`
as sequencing platform; raw `clr` is not supported by that step.

**Result:** scaffolding always runs. The final file name accumulates a suffix per enabled
step — `{out_prefix}[.craq][.inspector][.rt_corr].scf[.tgs].fa` — and lands in
`5_Gap_closing/` when gap closing is on, otherwise in `4_Scaffolding/`.

## 5. `eval:` — assembly evaluation

| Key | Type | Description |
|---|---|---|
| `assembly` | path | *[chained]* Final assembly from `asm`. |
| `reference_genome` | path | *[chained]* Reference to compare against. Required when QUAST or the dot plot is enabled. |
| `reads` | path | *[global]* Required when QUAST, CRAQ or Inspector is enabled. |
| `out_dir` | path | Output directory of the stage. |
| `contiguity_evaluation_tool` | `gfastats`\|`quast`\|`no` | Contiguity metrics (`1_Contiguity_metrics/`). |
| `contiguity_threads` | int | Threads for that tool. |
| `gene_space_compl_eval_tool` | `compleasm`\|`busco`\|`no` | Gene-space completeness (`2_Gene_space_completeness/`). |
| `gene_space_compl_eval_threads` | int | Threads for that tool. |
| `lineage` | string | BUSCO/compleasm lineage, e.g. `poales`. |
| `odb` | string | OrthoDB release, e.g. `odb12`. |
| `busco_out_prefix` | string | BUSCO run name. BUSCO only. |
| `run_craq` | yes/no | CRAQ in evaluation mode (`--break F`, `3_CRAQ/`). |
| `craq_threads` | int | CRAQ threads. |
| `run_inspector` | yes/no | Inspector QV/misassembly report (`4_Inspector/`). |
| `inspector_threads` | int | Inspector threads. |
| `run_viz` | yes/no | Assembly-vs-reference dot plot (`5_Visualization/`). |
| `minimap2_preset` | string | minimap2 preset for the dot plot mapping, e.g. `asm5`. |
| `viz_threads` | int | minimap2 threads. |

`compleasm` is run from a **sibling** environment of `nohic_env_path`: if the venv is
`/path/envs/noHiC`, compleasm is expected at `/path/envs/compleasm`. BUSCO runs from the
main environment.

**Result:** `{out_dir}/pipeline.done` once every enabled check has finished.

### `eval.use_slurm` and `eval.slurm:` — cluster settings

Only the evaluation stage submits jobs. `use_slurm: "yes"` attaches SLURM resources to
its heavy rules; you still have to start Snakemake with the SLURM executor
(`--workflow-profile profiles/slurm`, or `--executor slurm --jobs N`).

```yaml
  use_slurm: "yes"
  slurm:
    default:
      memory: "250G"        # 32000, "32000M", "32G", ...   "" = cluster default
      partition: "bcf"      # "" lets the SLURM site default decide
      account: "bcf"        # "" if your cluster does not use accounts
      wall_time: "24h"      # 120, "4h", "2d";              "" = partition default
    rules:
      GFAstats: {memory: "5G", partition: "idle", account: "", wall_time: ""}
      QUAST: {...}
      busco: {...}
      compleasm: {...}
      craq_based_evaluation: {...}
      inspector_based_evaluation: {...}
      assembly_to_reference_mapping: {...}
```

Rule names under `slurm.rules` are the **unprefixed** names as written in
`nohic-eval.slurm.c.smk`. An empty per-rule field falls back to `default`. Rules not
listed use `default` entirely.

---

## Minimal examples

**Only clean an existing assembly:**

```yaml
stages: {refpick: "no", refpolish: "no", clean: "yes", asm: "no", eval: "no"}
```

**Skip reference construction and use a published genome:** switch `refpick` and
`refpolish` off and fill the chained keys by hand —

```yaml
stages: {refpick: "no", refpolish: "no", clean: "yes", asm: "yes", eval: "yes"}
asm:
  reference_genome: "GCA_033546955.1_genomic.fa"    # no longer chained
eval:
  reference_genome: "GCA_033546955.1_genomic.fa"
```

**Evaluate an assembly you already have:**

```yaml
stages: {refpick: "no", refpolish: "no", clean: "no", asm: "no", eval: "yes"}
eval:
  assembly: "my_assembly.fa"
  reference_genome: "reference.fa"
```
