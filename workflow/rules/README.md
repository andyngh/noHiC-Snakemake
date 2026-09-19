# Sub-workflows

The five `*.c.smk` files in this directory are the stages of noHiC. Each one is a
complete, self-contained Snakemake workflow with its own `rule all`, and each is imported
by [`../Snakefile`](../Snakefile) with Snakemake's `module` / `use rule *` syntax:

```python
module asm_wf:
    snakefile: _smk("asm")        # -> workflow/rules/nohic-asm.c.smk
    config:    CFG["asm"]         # the "asm:" section of config/nohic.yaml
use rule * from asm_wf as asm_*
```

Two consequences of that import are worth remembering:

- **Rule names get a stage prefix.** `Scaffolding` becomes `asm_Scaffolding`, `QUAST`
  becomes `eval_QUAST`. Use the prefixed names on the command line.
- **The `configfile:` line at the top of each file is ignored.** Snakemake's module
  mechanism sets `skip_configfile`, so `nohic-asm.yaml` and friends do not need to exist;
  the config comes from the corresponding section of `config/nohic.yaml`. Those lines are
  only used if you run a sub-workflow standalone, e.g.
  `snakemake -s workflow/rules/nohic-asm.c.smk --configfile my-asm.yaml`.

`../Snakefile` finds these files through `workflow.basedir`, so **they must stay in this
directory under these exact names**.

Each rule writes a `.log` next to its outputs and echoes the exact command it ran
(`set -x`), so a log file is a reproducible record of the call. Stages use `touch()`
marker files (`*.done`) to sequence steps whose real outputs are directories or are
optional.

---

## `nohic-refpick.c.smk` — synthetic reference construction

Builds a reference tailored to the sample by sampling the pangenome graph with the
sample's own k-mer spectrum, instead of using a fixed published genome.

| Rule | Tool | Output |
|---|---|---|
| `kmer_counting` | KMC3 | `{prefix}.kff` k-mer counts, `kmc.done` |
| `haplotype_sampling` | `vg haplotypes` | `{prefix}.gbz` — one haplotype sampled to match the k-mer set |
| `synref_extracting` | `vg paths --extract-fasta --paths-by recombination` | `{prefix}.synref.fa` |

When `patch_synref: "yes"`, four more rules close the gaps in that synthetic reference
against a donor genome:

| Rule | Tool | Output |
|---|---|---|
| `synref_decomposing` | `Asm_Decomposing.sh` | `{prefix}.synref.ctgs.fa` |
| `synref_ctg_mapping` | minimap2 `-a -x asm10` | `{prefix}.synref_mapping.sam` (temporary) |
| `convert_sam_to_bam` | samtools view | `{prefix}.synref_mapping.bam` (temporary) |
| `synref_patching` | GPatch | `{prefix}.synref.patched.fasta` |

Logs: `KMC3.log`, `vg_haplotype.log`, `synref_extracting.log`, `synref_patching.log`.

## `nohic-refpolish.c.smk` — reference polishing

Polishes the synthetic reference with the same reads, which removes the errors inherited
from graph traversal before the reference is used for scaffolding.

| Rule | Tool | Output |
|---|---|---|
| `read_to_synref_mapping` | minimap2 + `samtools sort` | sorted BAM (temporary) |
| `bam_index` | `samtools index -c` | `.bam_index.done` |
| `hypo_polish` *(polish_tool: hypo)* | HyPo | `{prefix}.hypo.fasta` |
| `bam_to_sam` + `racon_polish` *(polish_tool: racon)* | samtools view, Racon | `{prefix}.racon.fasta` |

All rules log to one file, `reference_polishing.log`.

## `nohic-clean.c.smk` — adapter screening and decontamination

Runs on the **contig assembly**, independently of the reference branch. Output
subdirectories are numbered in execution order.

**`1_adapter_check/`**

| Rule | Tool | Output |
|---|---|---|
| `adapter_prep` | seqkit | `adapter_seqs.txt` — adapter sequences without headers |
| `adapter_check` | `grep -c`, `seqkit locate --bed` | `{sample}.adapter_match_number.txt`, `{sample}.adapter_positions.bed` |
| `adapter_free` | — | `adapter.done`, or **fails the workflow** if any adapter was found |

**`2_contamination_check/`**

| Rule | Tool | Output |
|---|---|---|
| `kraken2` | Kraken2 | `{sample}.kr`, `{sample}.report` |
| `taxonkit_db` | wget + tar | downloads the NCBI taxdump into `$HOME/.taxonkit/`; marker `Resources/taxonkit_db.done` |
| `taxonkit` | `taxonkit lineage` | `{sample}.lineage` |
| `contaminant_ctgs_identification` | grep/cut/sort | `{sample}.contaminant_ctgs.txt` — contigs whose lineage lacks `taxonomic_group` |

**`3_organellar_DNA_check/`** (only when `org_ctg_identification: "yes"`)

| Rule | Tool | Output |
|---|---|---|
| `make_blast_db` | makeblastdb | `blast_db.done` |
| `organellar_blast` | blastn (tabular, with `qcovs`) | `{sample}.blast.tsv` |
| `filter_blast_results` | `filter_blast.py` | `{sample}.blast.filtered.tsv` |
| `list_org_ctgs` | cut/sort | `{sample}.org_ctgs.txt` |

When it is `"no"`, `create_empty_blast_results` writes an empty contig list instead, so
the downstream rules are unchanged.

**`4_assembly_decontamination/`**

| Rule | Tool | Output |
|---|---|---|
| `create_final_cont_ctg_list` | cat/sort | `{sample}.final_cont_ctg_names.txt` |
| `decontamination` | `seqkit grep -v` | **`{sample}.pure.fa`** — the stage result |

`{sample}` is the basename of `contig_assembly` with `.fa`/`.fasta`/`.fna` stripped.

## `nohic-asm.c.smk` — correction, scaffolding, gap closing

Each correction step is optional and, when switched off, is replaced by a `*_skipped`
rule that only touches the marker file — so the dependency chain stays intact and the
input of the next step automatically falls back to the previous one.

| Directory | Rule | Tool | Output |
|---|---|---|---|
| `1_CRAQ/` | `chimeric_contig_breaking` | CRAQ (`--break T`) | `runAQI_out/out_correct.fa` |
| | `rename_craq_contigs` | mv | `{prefix}.craq.fa` |
| `2_Inspector/` | `inspector` | `inspector.py` | Inspector report |
| | `inspector_correct` | `inspector-correct.py` | `contig_corrected.fa` |
| | `rename_inspector_contigs` | mv | `{…}.inspector.fa` |
| `3_RagTag_correct/` | `RagTag_correct` | `ragtag.py correct` | `ragtag.correct.fasta` |
| | `rename_rt_corr_contigs` | mv | `{…}.rt_corr.fa` |
| `4_Scaffolding/` | `Scaffolding` | `ragtag.py scaffold -C -r -g 2` | `ragtag.scaffold.fasta` |
| | `rename_scaffolds` | mv | `{…}.scf.fa` |
| `5_Gap_closing/` | `fastq_to_fasta` | `seqkit fq2fa` | `reads.fa` (temporary) |
| | `gap_closing` | TGS-GapCloser | `{…}.scf.tgs.scaff_seqs` |
| | `rename_gap_closed_scaffold` | mv | `{…}.scf.tgs.fa` |
| | `pipeline_done` | touch | `pipeline.done` |

Platform-dependent settings are derived from `sequencing_platform`: CRAQ gets
`map-hifi`/`map-pb`/`map-ont`, Inspector gets `hifi`/`clr`/`nanopore` plus the matching
correction datatype, TGS-GapCloser gets `pb` or `ont`. CRAQ's clipped-read threshold is
0.75, or 0.55 with `ignore_het: "yes"`.

Two implementation details that are easy to trip over:

- CRAQ insists on a **non-existing** output directory, so the rule deletes it first. The
  log is written to a temporary file and moved back in place by an `EXIT` trap so it
  survives that deletion.
- TGS-GapCloser writes into the current working directory, so the rule resolves every
  path (including the log) with `realpath` before `cd`-ing into the output directory.

## `nohic-eval.slurm.c.smk` — evaluation

The only stage that can submit cluster jobs. Its `cluster_resources()` helper translates
the `eval.slurm` config block into Snakemake `resources` (`mem_mb`, `slurm_partition`,
`slurm_account`, `runtime`), accepting `"32G"`/`"32000M"`/`32000` for memory and
`"2d"`/`"4h"`/`120` for wall time. With `use_slurm: "no"` it returns an empty dict and
the rules are unconstrained.

| Directory | Rule | Tool | Output |
|---|---|---|---|
| `1_Contiguity_metrics/` | `GFAstats` *or* `QUAST` | gfastats / QUAST | `assembly_contiguity_metrics.GFAstats.tsv` / QUAST report |
| | `scaffold_length_calculations` | bioawk | `scaffold_lengths.tsv` |
| `2_Gene_space_completeness/` | `busco` *or* `compleasm` | BUSCO / compleasm | lineage download + completeness report |
| `3_CRAQ/` | `craq_based_evaluation` | CRAQ (`--break F`) | CRAQ report |
| `4_Inspector/` | `inspector_based_evaluation` | `inspector.py` | Inspector report |
| `5_Visualization/` | `assembly_to_reference_mapping` | minimap2 `-cx {preset}` | `query_to_reference.paf` |
| | `dot_plot_generation` | `paf2dotplot.R` | dot plot |
| | `pipeline_done` | touch | `pipeline.done` |

Each of the four optional checks has a matching `*_skipped` rule, so `pipeline_done` can
always depend on all of them.

`localrules` in this file, and the corresponding list in `../Snakefile`, keep the cheap
rules (`scaffold_length_calculations`, `dot_plot_generation`, `pipeline_done` and the
`*_skipped` markers) on the submitting machine instead of queueing them.

---

## Running a single sub-workflow

Every file still works on its own, with a config that has that stage's keys at the top
level (no `asm:` wrapper) plus `nohic_env_path` and any global values it needs:

```bash
snakemake -s workflow/rules/nohic-asm.c.smk --configfile my-asm.yaml --cores 50
```

Nothing is chained in that mode — all inputs must be given explicitly.
