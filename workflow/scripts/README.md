# Helper scripts

noHiC calls two helper scripts that are **not** shipped in this repository. They are
expected to be executable and on `$PATH` inside the environment given by
`nohic_env_path` (the sub-workflows activate it through `shell.prefix`, so anything in
`{nohic_env_path}/bin/` is found automatically):

| Script | Used by | Called as |
|---|---|---|
| `Asm_Decomposing.sh` | `nohic-refpick.c.smk`, rule `synref_decomposing` | `Asm_Decomposing.sh <synref.fa> <synref.ctgs.fa>` — splits the synthetic reference into contigs at its gaps, so the pieces can be mapped to the donor genome before patching. |
| `filter_blast.py` | `nohic-clean.c.smk`, rule `filter_blast_results` | `filter_blast.py <blast.tsv> > <blast.filtered.tsv>` — keeps the BLAST hits that identify a contig as organellar. Input is the 13-column tabular format `qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore qcovs`. |

If you would rather version these scripts together with the workflow, drop them in this
directory and reference them from a rule via `workflow.basedir`:

```python
FILTER_BLAST = os.path.join(workflow.basedir, "scripts", "filter_blast.py")
```

`nohic-clean.c.smk` already contains that line, commented out, for exactly this purpose.
Note that `workflow.basedir` is the directory of the **top-level** Snakefile
(`workflow/`), not of the included rules file — hence the `scripts/` component in the
path above.

Beyond these two, every tool the workflow uses is a normal command-line program that must
be installed in the same environment; see the requirements table in the
[top-level README](../../README.md#requirements).
