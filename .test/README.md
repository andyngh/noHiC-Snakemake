# Smoke test

This directory lets continuous integration check that the workflow still parses, that the
five sub-workflows still import cleanly as modules, and that the stage chaining still
produces a complete job graph — without any data or bioinformatics tools being installed.

```bash
cd .test
bash setup.sh
snakemake --snakefile ../workflow/Snakefile \
          --configfile config/nohic.yaml \
          --workflow-profile none \
          --dry-run --cores 2
```

`setup.sh` creates empty placeholder files for every input named in
[`config/nohic.yaml`](config/nohic.yaml). The run is always a dry run, so nothing is ever
read or executed. A successful run builds 44 jobs with all five stages enabled and every
optional step switched on.

`--workflow-profile none` is needed because the working directory is `.test/`, where the
repository's `profiles/default` does not apply — the config file is passed explicitly
instead.

This is a structural test only. It cannot tell you whether CRAQ, RagTag, or compleasm
behave correctly; for that, you need a real (small) dataset and the full environment.
