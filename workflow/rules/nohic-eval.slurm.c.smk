from pathlib import Path

configfile: "nohic-eval.slurm.yaml"

def opt(key, default=None, cast=None):
    value = config.get(key, None)
    if value is None or (isinstance(value, str) and value.strip() == ""):
        return default
    return cast(value) if cast else value

#--------------------------- PARAMS ----------------------------#
ENV_PATH = config["nohic_env_path"]
COMPLEASM_ENV = str(Path(ENV_PATH).parent / "compleasm")
shell.prefix(f"source {ENV_PATH}/bin/activate; ")
ASM = config["assembly"]
READS = opt("reads", "")
OUT_DIR = config["out_dir"]
# Contiguity evaluation
CONTIGUITY_THREADS = opt("contiguity_threads", 1, int)
CONTIGUITY_OUTDIR = f"{OUT_DIR}/1_Contiguity_metrics"
CONTIGUITY_TOOL = str(config["contiguity_evaluation_tool"]).strip().lower()

# Gene space completeness evaluation
GENE_TOOL = str(config["gene_space_compl_eval_tool"]).strip().lower()
GENE_OUT_DIR = f"{OUT_DIR}/2_Gene_space_completeness"
GENE_THREADS = opt("gene_space_compl_eval_threads", 1, int)
LINEAGE = str(opt("lineage", "")).strip().lower()
ODB = str(opt("odb", "")).strip().lower()

# if BUSCO is used for gene space completeness evaluation
BUSCO_DB = LINEAGE + "_" + ODB
BUSCO_OUT_PREFIX = opt("busco_out_prefix", "")
BUSCO_LINEAGE_DIR = f"{GENE_OUT_DIR}/busco_downloads/lineages/{BUSCO_DB}"

# CRAQ
RUN_CRAQ = str(config["run_craq"]).strip().lower()
COV = opt("sequencing_coverage", 1, int)
PLATFORM = str(opt("sequencing_platform", "")).strip().lower()
CRAQ_THREADS = opt("craq_threads", 1, int)
CRAQ_OUT_DIR = f"{OUT_DIR}/3_CRAQ"
# Inspector
RUN_INSPECTOR = str(config["run_inspector"]).strip().lower()
INSPECTOR_THREADS = opt("inspector_threads", 1, int)
INSPECTOR_OUT_DIR = f"{OUT_DIR}/4_Inspector"
# Visualization
RUN_VIZ = str(config["run_viz"]).strip().lower()
REF = opt("reference_genome", "")
MM2_PRESET = opt("minimap2_preset", "")
VIZ_THREADS = opt("viz_threads", 1, int)
VIZ_OUT_DIR = f"{OUT_DIR}/5_Visualization"

#----------------------- SLURM SETTINGS ------------------------#

USE_SLURM = str(config.get("use_slurm", "no")).strip().lower() in {"yes", "y", "true", "1", "on"}
_SLURM_CFG = config.get("slurm") or {}
_SLURM_DEFAULT = _SLURM_CFG.get("default") or {}
_SLURM_RULES = _SLURM_CFG.get("rules") or {}


def _memory_to_mb(memory):
    """Convert a memory setting given in MB or GB into MB.

    Accepted forms: 32000, "32000", "32000M", "32000MB", "32G", "32GB"
    (case insensitive). A plain number is read as MB.
    """
    value = str(memory).strip().upper().replace(" ", "")
    if value.endswith("B"):            # "32GB" -> "32G", "32000MB" -> "32000M"
        value = value[:-1]
    if value.endswith("G"):
        return int(round(float(value[:-1]) * 1000))
    if value.endswith("M"):
        return int(round(float(value[:-1])))
    return int(round(float(value)))


def _walltime_to_minutes(wall_time):
    """Convert a wall time setting into minutes.

    Accepted forms: 120, "120", "120M" (minutes), "4H", "2D"
    (case insensitive). A plain number is read as minutes.
    """
    value = str(wall_time).strip().upper().replace(" ", "")
    if value.endswith("D"):
        return int(round(float(value[:-1]) * 24 * 60))
    if value.endswith("H"):
        return int(round(float(value[:-1]) * 60))
    if value.endswith("M"):
        return int(round(float(value[:-1])))
    return int(round(float(value)))


def cluster_resources(rule_name):
    """Memory, partition, account and wall time for a queued rule.

    Returns an empty dict when "use_slurm" is not enabled, which leaves the
    rules unconstrained for local execution.
    """
    if not USE_SLURM:
        return {}

    settings = dict(_SLURM_DEFAULT)
    # An empty per-rule field falls back to the value given in "default".
    for key, value in (_SLURM_RULES.get(rule_name) or {}).items():
        if str(value).strip():
            settings[key] = value

    resources = {"mpi": ""}
    if str(settings.get("memory", "")).strip():
        resources["mem_mb"] = _memory_to_mb(settings["memory"])
    if str(settings.get("partition", "")).strip():
        resources["slurm_partition"] = str(settings["partition"]).strip()
    if str(settings.get("account", "")).strip():
        resources["slurm_account"] = str(settings["account"]).strip()
    if str(settings.get("wall_time", "")).strip():
        resources["runtime"] = _walltime_to_minutes(settings["wall_time"])

    return resources


#---------------------------- RULES ----------------------------#

localrules:
    all,
    scaffold_length_calculations,
    dot_plot_generation,
    pipeline_done,
    contiguity_skipped,
    gene_space_skipped,
    craq_skipped,
    inspector_skipped,
    viz_skipped

# set default target
rule all:
    input:
        f"{OUT_DIR}/pipeline.done"

# Contiguity metric

if CONTIGUITY_TOOL == "gfastats":
    # Target requested by "pipeline_done": the real result file, so that a rerun is
    # triggered whenever it is missing (e.g. after switching this step back on).
    CONTIGUITY_TARGET = f"{CONTIGUITY_OUTDIR}/assembly_contiguity_metrics.GFAstats.tsv"
    rule GFAstats:
        input:
            asm=ASM
        threads: CONTIGUITY_THREADS
        resources:
            **cluster_resources("GFAstats")
        output:
            cont_metrics=CONTIGUITY_TARGET,
            cont_done=touch(f"{CONTIGUITY_OUTDIR}/contiguity.done")
        log:
            f"{CONTIGUITY_OUTDIR}/contiguity.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Running gfastats..."
            echo "gfastats command:"
            set -x
            gfastats {input.asm} -j {threads} -t > {output.cont_metrics}
            ) &>> {log}
            """
elif CONTIGUITY_TOOL == "quast":
    CONTIGUITY_TARGET = f"{CONTIGUITY_OUTDIR}/contiguity.done"
    # Set sequencing platform
    if PLATFORM == "hifi" or PLATFORM == "clr" or PLATFORM == "corrected_clr":
        QUAST_SEQ_PLATFORM="--pacbio"
    elif PLATFORM == "ont" or PLATFORM == "corrected_ont":
        QUAST_SEQ_PLATFORM="--nanopore"
    else:
        raise WorkflowError("ERROR: Invalid sequencing platform. Please put in clr, hifi, ont, corrected_clr, or corrected_ont!")
    # Run QUAST
    rule QUAST:
        input:
            asm=ASM,
            ref_genome=REF,
            reads=READS
        params:
            platform=QUAST_SEQ_PLATFORM,
            out_dir=CONTIGUITY_OUTDIR
        threads: CONTIGUITY_THREADS
        resources:
            **cluster_resources("QUAST")
        output:
            cont_done=touch(f"{CONTIGUITY_OUTDIR}/contiguity.done")
        log:
            f"{CONTIGUITY_OUTDIR}/contiguity.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Running QUAST..."
            echo "QUAST command:"
            set -x
            quast {input.asm} -r {input.ref_genome} {params.platform} {input.reads} --plots-format svg -t {threads} -o {params.out_dir}
            ) &>> {log}
            """
elif CONTIGUITY_TOOL == "no":
    print("Contiguity evaluation skipped")
    CONTIGUITY_TARGET = f"{CONTIGUITY_OUTDIR}/contiguity.done"
    rule contiguity_skipped:
        output:
            cont_done=touch(f"{CONTIGUITY_OUTDIR}/contiguity.done")
else:
    raise WorkflowError("ERROR: Please set the value of contiguity_evaluation_tool to 'gfastats', 'quast', or 'no'!")

# Calculate scaffold lengths
rule scaffold_length_calculations:
    input:
        asm=ASM
    output:
        len_file=f"{CONTIGUITY_OUTDIR}/scaffold_lengths.tsv",
        scf_len_done=touch(f"{CONTIGUITY_OUTDIR}/scf_len.done")
    log:
        f"{CONTIGUITY_OUTDIR}/scf_len.log"
    shell:
        r"""
        set -euo pipefail
        (
        echo "Calculating scaffold lengths..."
        echo "bioawk command:"
        set -x
        bioawk -c fastx '{{print $name, length($seq)}}' < {input.asm} | sort -n -r -k2 > {output.len_file}
        ) &>> {log}
        """

# Gene space completeness evaluations

if GENE_TOOL == "busco":
    rule busco:
        input:
            asm=ASM
        params:
            db=BUSCO_DB,
            out_dir=GENE_OUT_DIR,
            prefix=BUSCO_OUT_PREFIX,
            lineage=BUSCO_LINEAGE_DIR
        threads: GENE_THREADS
        resources:
            **cluster_resources("busco")
        output:
            busco_done=touch(f"{GENE_OUT_DIR}/gene.done")
        log:
            f"{GENE_OUT_DIR}/BUSCO.log"
        shell:
            r"""
            set -euo pipefail
            mkdir -p {params.out_dir}
            (
            echo "Downloading the BUSCO lineage dataset..."
            echo "BUSCO commands:"
            set -x
            busco --download {params.db} --download_path {params.out_dir}/busco_downloads
            busco -i {input.asm} -m genome --cpu {threads} -l {params.lineage} --out_path {params.out_dir} -o {params.prefix} --skip_bbtools
            ) &>> {log}
            """
elif GENE_TOOL == "compleasm":
    rule compleasm:
        input:
            asm=ASM
        params:
            compleasm_lineage=LINEAGE,
            compleasm_odb=ODB,
            out_dir=GENE_OUT_DIR,
            env_path=COMPLEASM_ENV
        threads: GENE_THREADS
        resources:
            **cluster_resources("compleasm")
        output:
            compleasm_done=touch(f"{GENE_OUT_DIR}/gene.done")
        log:
            f"{GENE_OUT_DIR}/compleasm.log"
        shell:
            r"""
            set -euo pipefail
            mkdir -p {params.out_dir}/compleasm_DB
            source {params.env_path}/bin/activate
            (
            echo "Running compleasm..."
            echo "compleasm commands:"
            set -x
            compleasm download -L {params.out_dir}/compleasm_DB --odb {params.compleasm_odb} {params.compleasm_lineage}
            compleasm run -a {input.asm} -t {threads} -l {params.compleasm_lineage} --odb {params.compleasm_odb} \
                          -L {params.out_dir}/compleasm_DB -o {params.out_dir}
            ) &>> {log}
            """

elif GENE_TOOL == "no":
    print("Gene space completeness evaluation skipped")
    rule gene_space_skipped:
        output:
            gene_done=touch(f"{GENE_OUT_DIR}/gene.done")
else:
    raise WorkflowError("ERROR: Please set the value of gene_space_compl_eval_tool to 'busco', 'compleasm', or 'no'!")

# CRAQ
if RUN_CRAQ == "yes":

    # set sequencing platform
    if PLATFORM == "hifi":
        CRAQ_MAP = "map-hifi"
    elif PLATFORM == "clr" or PLATFORM == "corrected_clr":
        CRAQ_MAP = "map-pb"
    elif PLATFORM == "ont" or PLATFORM == "corrected_ont":
        CRAQ_MAP = "map-ont"
    else:
        raise WorkflowError("ERROR: Invalid sequencing platform. Please put in clr, hifi, ont, corrected_clr, or corrected_ont!")

    rule craq_based_evaluation:
        input:
            asm=ASM,
            reads=READS
        params:
            coverage=COV,
            craq_map=CRAQ_MAP,
            craq_out_dir=CRAQ_OUT_DIR
        threads: CRAQ_THREADS
        resources:
            **cluster_resources("craq_based_evaluation")
        output:
            craq_done=touch(f"{CRAQ_OUT_DIR}/craq.done")
        log:
            f"{CRAQ_OUT_DIR}/CRAQ_based_evaluation.log"
        shell:
            # CRAQ needs a non-existing output directory, but that directory also holds
            # the log file. The log is therefore written to a temporary file and moved
            # back in place on exit, so that it survives the "rm -rf" below.
            r"""
            set -euo pipefail
            tmp_log=$(mktemp)
            chmod 644 "$tmp_log"
            trap 'mkdir -p {params.craq_out_dir}; mv -f "$tmp_log" "{log}"' EXIT
            rm -rf {params.craq_out_dir}
            (
            echo "Running CRAQ..."
            echo "CRAQ command:"
            set -x
            craq --genome {input.asm} --sms_input {input.reads} --sms_coverage {params.coverage} --break F \
                --map {params.craq_map} --thread {threads} --output_dir {params.craq_out_dir}
            ) &>> "$tmp_log"
            """

elif RUN_CRAQ == "no":
    print("CRAQ skipped")
    rule craq_skipped:
        output:
            craq_done=touch(f"{CRAQ_OUT_DIR}/craq.done")
else:
    raise WorkflowError("ERROR: Please set the value of run_craq to either 'yes' or 'no'!")

# Inspector
if RUN_INSPECTOR == "yes":
    # set sequencing platform
    if PLATFORM == "hifi":
        INSPECTOR_DATATYPE="hifi"
    elif PLATFORM == "clr" or PLATFORM == "corrected_clr":
        INSPECTOR_DATATYPE="clr"
    elif PLATFORM == "ont" or PLATFORM == "corrected_ont":
        INSPECTOR_DATATYPE="nanopore"
    else:
        raise WorkflowError("ERROR: Invalid sequencing platform. Please put in clr, hifi, ont, corrected_clr, or corrected_ont")

    rule inspector_based_evaluation:
        input:
            asm=ASM,
            reads=READS
        params:
            inspector_out_dir=INSPECTOR_OUT_DIR,
            datatype=INSPECTOR_DATATYPE
        threads: INSPECTOR_THREADS
        resources:
            **cluster_resources("inspector_based_evaluation")
        output:
            inspector_done=touch(f"{INSPECTOR_OUT_DIR}/inspector.done")
        log:
            f"{INSPECTOR_OUT_DIR}/inspector_based_evaluation.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Running Inspector..."
            echo "Inspector command:"
            set -x
            inspector.py -c {input.asm} -r {input.reads} -o {params.inspector_out_dir} -t {threads} --datatype {params.datatype}
            ) &>> {log}
            """
elif RUN_INSPECTOR == "no":
    print("Inspector skipped")
    rule inspector_skipped:
        output:
            inspector_done=touch(f"{INSPECTOR_OUT_DIR}/inspector.done")
else:
    raise WorkflowError("ERROR: Please set the value of run_inspector to either 'yes' or 'no'!")

# Dot plot visualization
if RUN_VIZ == "yes":
    rule assembly_to_reference_mapping:
        input:
            asm=ASM,
            ref_genome=REF
        params:
            mapping_preset=MM2_PRESET
        threads: VIZ_THREADS
        resources:
            **cluster_resources("assembly_to_reference_mapping")
        output:
            mapping_out=f"{VIZ_OUT_DIR}/query_to_reference.paf"
        log:
            f"{VIZ_OUT_DIR}/assembly_to_reference_mapping.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Mapping the assembly to the reference genome..."
            echo "minimap2 command:"
            set -x
            minimap2 -t {threads} -cx {params.mapping_preset} {input.ref_genome} {input.asm} > {output.mapping_out}
            ) &>> {log}
            """
    rule dot_plot_generation:
        input:
            mapping_out=f"{VIZ_OUT_DIR}/query_to_reference.paf"
        params:
            viz_out_dir=VIZ_OUT_DIR
        output:
            viz_done=touch(f"{VIZ_OUT_DIR}/viz.done")
        log:
            f"{VIZ_OUT_DIR}/dot_plot_generation.log"
        shell:
            r"""
            set -euo pipefail
            paf_abs=$(realpath {input.mapping_out})
            log_abs=$(realpath {log})
            cd {params.viz_out_dir}
            (
            echo "Generating the dot plot..."
            echo "paf2dotplot command:"
            set -x
            paf2dotplot.R -f -b "$paf_abs"
            ) &>> "$log_abs"
            """
elif RUN_VIZ == "no":
    print("Dot plot visualization skipped")
    rule viz_skipped:
        output:
            viz_done=touch(f"{VIZ_OUT_DIR}/viz.done")
else:
    raise WorkflowError("ERROR: Please set the value of run_viz to either 'yes' or 'no'!")

# set final target
rule pipeline_done:
    input:
        contiguity=CONTIGUITY_TARGET,
        scf_len=f"{CONTIGUITY_OUTDIR}/scf_len.done",
        gene=f"{GENE_OUT_DIR}/gene.done",
        craq=f"{CRAQ_OUT_DIR}/craq.done",
        inspector=f"{INSPECTOR_OUT_DIR}/inspector.done",
        viz=f"{VIZ_OUT_DIR}/viz.done"
    output:
        pipeline_done=touch(f"{OUT_DIR}/pipeline.done")
