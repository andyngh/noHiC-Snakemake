configfile: "nohic-refpolish.yaml"

def opt(key, default=None, cast=None):
    value = config.get(key, None)
    if value is None or (isinstance(value, str) and value.strip() == ""):
        return default
    return cast(value) if cast else value

#--------------------------- PARAMS ----------------------------#
ENV_PATH = config["nohic_env_path"]
shell.prefix(f"source {ENV_PATH}/bin/activate; ")
READS = config["reads"]
SYNREF = config["synref"]
MAP_PRESET = str(config["mapping_preset"]).strip().lower()
THREADS = int(config["threads"])
POLISH_TOOL = str(config["polish_tool"]).strip().lower()
OUT_DIR = config["out_dir"]
PREFIX = OUT_DIR + "/" + config["prefix"]
# For hypo
COV = opt("coverage", 1, int)
GENOME_SIZE = opt("genome_size", "")

#---------------------------- RULES ----------------------------#

if POLISH_TOOL == "hypo":
    if not GENOME_SIZE:
        raise WorkflowError("ERROR: polish_tool is 'hypo' but 'genome_size' is empty in the config!")
    FINAL_TARGET=f"{PREFIX}.hypo.fasta"
elif POLISH_TOOL == "racon":
    FINAL_TARGET=f"{PREFIX}.racon.fasta"
else:
    raise WorkflowError("ERROR: invalid choice of polishing tool. Please choose either hypo or racon!")

rule all:
    input:
        FINAL_TARGET

rule read_to_synref_mapping:
    input:
        read_file=READS,
        synref=SYNREF
    params:
        preset=MAP_PRESET
    threads: THREADS
    output:
        bam_file=temp(f"{PREFIX}.mapping.sorted.bam")
    log:
        f"{OUT_DIR}/reference_polishing.log"
    shell:
        r"""
        set -euo pipefail
        (
        echo "Mapping reads to reference genome..."
        echo "minimap2 command:"
        set -x
        minimap2 -ax {params.preset} -t {threads} {input.synref} {input.read_file} | samtools sort -@ {threads} -o {output.bam_file} -
        ) &>> {log}
        """
rule bam_index:
    input:
        bam_file=f"{PREFIX}.mapping.sorted.bam"
    threads: THREADS
    output:
        idx_compl=touch(f"{PREFIX}.bam_index.done")
    log:
        f"{OUT_DIR}/reference_polishing.log"
    shell:
        r"""
        set -euo pipefail
        (
        echo "Indexing BAM file..."
        echo "samtools command:"
        set -x
        samtools index -c -@ {threads} {input.bam_file}
        ) &>> {log}
        """
if POLISH_TOOL == "hypo":
    rule hypo_polish:
        input:
            idx_compl=f"{PREFIX}.bam_index.done",
            read_file=READS,
            synref=SYNREF,
            bam_file=f"{PREFIX}.mapping.sorted.bam"
        params:
            cov=COV,
            synref_size=GENOME_SIZE
        threads: THREADS
        output:
            polished_synref_hypo=f"{PREFIX}.hypo.fasta"
        log:
            f"{OUT_DIR}/reference_polishing.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "hypo selected for polishing reference genome"
            echo "hypo command:"
            set -x
            hypo -r {input.read_file} -d {input.synref} -b {input.bam_file} -s {params.synref_size} -c {params.cov} -o {output.polished_synref_hypo} -k ccs -t {threads}
            ) &>> {log}
            """
elif POLISH_TOOL == "racon":
    rule bam_to_sam:
        input:
            idx_compl=f"{PREFIX}.bam_index.done",
            bam_file=f"{PREFIX}.mapping.sorted.bam"
        threads: THREADS
        output:
            sam_file=temp(f"{PREFIX}.mapping.sorted.sam")
        log:
            f"{OUT_DIR}/reference_polishing.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Racon selected for polishing reference genome"
            echo "Converting BAM to SAM..."
            echo "samtools command:"
            set -x
            samtools view -h -@ {threads} {input.bam_file} > {output.sam_file}
            ) &>> {log}
            """
    rule racon_polish:
        input:
            sam_file=f"{PREFIX}.mapping.sorted.sam",
            read_file=READS,
            synref=SYNREF
        threads: THREADS
        output:
            polished_synref_racon=f"{PREFIX}.racon.fasta"
        log:
            f"{OUT_DIR}/reference_polishing.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Racon command:"
            set -x
            racon -t {threads} {input.read_file} {input.sam_file} {input.synref} > {output.polished_synref_racon}
            ) &>> {log}
            """
else:
    raise WorkflowError("ERROR: invalid choice of polishing tool. Please choose either hypo or racon!")
