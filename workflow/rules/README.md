# Sub-workflows

## How the sub-workflows are imported into the master Snakefile

The five `*.c.smk` files in this directory are the stages of noHiC. Each one is a
complete, self-contained Snakemake workflow, and each is imported by
[`../Snakefile`](../Snakefile) using Snakemake's `module` / `use rule *` syntax:

```python
module asm_wf:
    snakefile: _smk("asm")        # imports the Snakefile workflow/rules/nohic-asm.c.smk
    config:    CFG["asm"]         # takes the "asm:" section of config/nohic.yaml
use rule * from asm_wf as asm_*
```

After being imported into the master [`Snakefile`](../Snakefile), **rule names get a stage
prefix.** For example, `Scaffolding` (from `nohic-asm`) becomes `asm_Scaffolding`, and
`QUAST` (from `nohic-eval`) becomes `eval_QUAST`.

`../Snakefile` finds these `*.c.smk` files through `workflow.basedir`, so **they must stay
in this directory under these exact names**.

Each rule writes a `.log` file next to its outputs and echoes the exact command it ran, so
a log file is a reproducible record of the call.

---

## `nohic-refpick.c.smk` rules and outputs

| Rule | Tool | Output |
|---|---|---|
| `kmer_counting` | KMC3 | K-mer count file for the target genome (`{prefix}.kff`) |
| `haplotype_sampling` | `vg haplotypes` | Personalized graph for the target genome (`{prefix}.gbz`) |
| `synref_extracting` | `vg paths` | The synref for your target genome (`{prefix}.synref.fa`) **[main output]** |

When `patch_synref: "yes"`, four more rules are executed to close the gaps in the
generated synref using sequence from a donor genome:

| Rule | Tool | Output |
|---|---|---|
| `synref_decomposing` | `Asm_Decomposing.sh` (helper script included in the environment) | The synref split into contigs at gap positions (`{prefix}.synref.ctgs.fa`) |
| `synref_ctg_mapping` | minimap2 | SAM file with alignments between the synref contigs and the donor genome (`{prefix}.synref_mapping.sam`) (temporary) |
| `convert_sam_to_bam` | `samtools view` | BAM file with alignments between the synref contigs and the donor genome (`{prefix}.synref_mapping.bam`) (temporary) |
| `synref_patching` | GPatch | The patched synref (`{prefix}.synref.patched.fasta`) **[main output]** |

Logs: `KMC3.log`, `vg_haplotype.log`, `synref_extracting.log`, `synref_patching.log`.

## `nohic-refpolish.c.smk` rules and outputs

| Rule | Tool | Output |
|---|---|---|
| `read_to_synref_mapping` | minimap2 + `samtools sort` | Sorted BAM file with alignments between the reads of the target genome and a reference genome (either the synref or a real genome) (temporary) |
| `bam_index` | `samtools index` | `.bam_index.done` |
| `hypo_polish` *(`polish_tool: hypo`)* | HyPo | The reference genome polished with the target long reads using HyPo (`{prefix}.hypo.fasta`) **[main output]** |
| `bam_to_sam` + `racon_polish` *(`polish_tool: racon`)* | `samtools view`, Racon | The reference genome polished with the target long reads using Racon (`{prefix}.racon.fasta`) **[main output]** |

All rules log to a single file, `reference_polishing.log`.

## `nohic-clean.c.smk` rules and outputs

**`1_adapter_check/`**

| Rule | Tool | Output |
|---|---|---|
| `adapter_prep` | seqkit | Adapter sequences without headers (`adapter_seqs.txt`) |
| `adapter_check` | grep, `seqkit locate` | Files with the number of adapter matches and the adapter coordinates in the target contigs, if any (`{sample}.adapter_match_number.txt` and `{sample}.adapter_positions.bed`, respectively) **[main output]** |
| `adapter_free` | — | `adapter.done`, or **fails the workflow** if any adapter was found |

**`2_contamination_check/`**

| Rule | Tool | Output |
|---|---|---|
| `kraken2` | Kraken2 | Kraken2 taxonomic classification results and report (`{sample}.kr` and `{sample}.report`, respectively) |
| `taxonkit_db` | wget + tar | Downloads the NCBI taxdump into `$HOME/.taxonkit/`; marker file `Resources/taxonkit_db.done` |
| `taxonkit` | `taxonkit lineage` | TaxonKit lineage output (`{sample}.lineage`) |
| `contaminant_ctgs_identification` | grep/cut/sort | Identified contaminant contigs (`{sample}.contaminant_ctgs.txt`) **[main output]** |

**`3_organellar_DNA_check/`** (only when `org_ctg_identification: "yes"`)

| Rule | Tool | Output |
|---|---|---|
| `make_blast_db` | makeblastdb | `blast_db.done` |
| `organellar_blast` | blastn | Raw BLASTn results between the target contigs and the reference organellar DNA sequences (`{sample}.blast.tsv`) |
| `filter_blast_results` | `filter_blast.py` (helper script included in the environment) | Filtered BLASTn results (`{sample}.blast.filtered.tsv`) |
| `list_org_ctgs` | cut/sort | Identified contigs originating from organelles (`{sample}.org_ctgs.txt`) **[main output]** |

**`4_assembly_decontamination/`**

| Rule | Tool | Output |
|---|---|---|
| `create_final_cont_ctg_list` | cat/sort | Final list of contigs to be removed (`{sample}.final_cont_ctg_names.txt`) |
| `decontamination` | `seqkit grep -v` | Decontaminated contig file (`{sample}.pure.fa`) **[main output]** |

`{sample}` is the basename of `contig_assembly` with `.fa`/`.fasta`/`.fna` stripped.

## `nohic-asm.c.smk` rules and outputs

Each correction step in this stage is optional.

| Directory | Rule | Tool | Main output |
|---|---|---|---|
| `1_CRAQ/` | `chimeric_contig_breaking` | CRAQ | Contigs corrected by CRAQ (`runAQI_out/out_correct.fa`) |
| | `rename_craq_contigs` | mv | Renamed contig file of this step (`{prefix}.craq.fa`) |
| `2_Inspector/` | `inspector` | `inspector.py` | Inspector report (`summary_statistics`) |
| | `inspector_correct` | `inspector-correct.py` | Contigs corrected by Inspector (`contig_corrected.fa`) |
| | `rename_inspector_contigs` | mv | Renamed contig file of this step (`{…}.inspector.fa`) |
| `3_RagTag_correct/` | `RagTag_correct` | `ragtag.py correct` | Contigs corrected by RagTag (`ragtag.correct.fasta`) |
| | `rename_rt_corr_contigs` | mv | Renamed contig file of this step (`{…}.rt_corr.fa`) |
| `4_Scaffolding/` | `Scaffolding` | `ragtag.py scaffold` | Scaffolded contigs (`ragtag.scaffold.fasta`) |
| | `rename_scaffolds` | mv | Renamed scaffold file of this step (`{…}.scf.fa`) |
| `5_Gap_closing/` | `fastq_to_fasta` | `seqkit fq2fa` | Long reads in FASTA format (`reads.fa`) (temporary) |
| | `gap_closing` | TGS-GapCloser | Scaffolds with gaps filled (`{…}.scf.tgs.scaff_seqs`) |
| | `rename_gap_closed_scaffold` | mv | Renamed scaffold file of this step (`{…}.scf.tgs.fa`) |

## `nohic-eval.slurm.c.smk` rules and outputs

| Directory | Rule | Tool | Main output |
|---|---|---|---|
| `1_Contiguity_metrics/` | `GFAstats` *or* `QUAST` | gfastats / QUAST | A file containing contiguity metrics (`assembly_contiguity_metrics.GFAstats.tsv` or the QUAST report `report.*`) |
| | `scaffold_length_calculations` | bioawk | A file containing scaffold lengths (`scaffold_lengths.tsv`) |
| `2_Gene_space_completeness/` | `busco` *or* `compleasm` | BUSCO / compleasm | A completeness report (`summary.txt` for compleasm or `{busco_out_prefix}/short_summary.specific.*.txt` for BUSCO) |
| `3_CRAQ/` | `craq_based_evaluation` | CRAQ | A CRAQ report containing the R- and S-AQI metrics (`runAQI_out/out_final.Report`) |
| `4_Inspector/` | `inspector_based_evaluation` | `inspector.py` | An Inspector report containing the QV (`summary_statistics`) |
| `5_Visualization/` | `assembly_to_reference_mapping` | minimap2 | Alignments between the target and reference assemblies (`query_to_reference.paf`) |
| | `dot_plot_generation` | `paf2dotplot.R` (helper script included in the environment) | Dot plot showing the alignments between the target and reference assemblies (`query_to_reference.paf.png` and `query_to_reference.paf.pdf`) |
