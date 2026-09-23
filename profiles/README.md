# Workflow profiles

A [workflow profile](https://snakemake.readthedocs.io/en/stable/executing/cli.html#profiles)
is a `config.yaml` file holding default command-line arguments for this workflow. Each
subdirectory here is one profile.

| Profile | When it is used | What it does |
|---|---|---|
| [`default/`](default/config.yaml) | **Automatically**, whenever no `--workflow-profile` is given | Supplies `--configfile config/nohic.yaml` and a few safe defaults for long-running jobs |
| [`slurm/`](slurm/config.yaml) | `snakemake --workflow-profile profiles/slurm` | The same, plus the SLURM executor for the evaluation stage |

Two things to keep in mind:

- **`default/` is not merged with a profile you name explicitly.** `--workflow-profile
  profiles/slurm` *replaces* it, which is why `slurm/config.yaml` repeats the general
  settings. Use `--workflow-profile none` to switch profiles off completely — you must
  then pass `--configfile config/nohic.yaml` yourself, or the workflow aborts at the
  `configfile: "nohic.yaml"` line in `workflow/Snakefile`.
- **A workflow profile is not the place for cluster resources.** In noHiC, the memory,
  partition, account, and wall time of the queued rules are set in the `eval.slurm`
  section of `config/nohic.yaml`, and the eval sub-workflow turns them into Snakemake
  `resources`. A profile only decides *how* jobs are executed (executor, job count,
  latency), not how big they are.

## Adding a profile for your cluster

Copy `slurm/` to a clearly named directory — e.g., `profiles/slurm_uni_xyz/` for an
institutional setup — and adjust it there rather than editing the shipped profiles.
Useful keys:

```yaml
executor: slurm
jobs: 50                       # Max. number of jobs in the queue at once
cores: 50                      # Cores available to local (non-submitted) rules
default-resources:
  slurm_partition: "long"      # Applies only to rules that set no partition themselves
  runtime: 1440
latency-wait: 60
keep-going: true
```

Add a comment to every entry explaining what it is for and why the value was chosen —
your future self, and anyone porting the workflow to another cluster, will need it.

Other executors work the same way: install the matching
[executor plugin](https://snakemake.github.io/snakemake-plugin-catalog/) and set
`executor:` accordingly. Note that only the evaluation stage is submitted; the other four
stages are registered as local rules by `workflow/Snakefile` and always run on the
machine that runs Snakemake.
