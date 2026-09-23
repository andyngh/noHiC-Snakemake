configfile: "nohic-asm.yaml"

def opt(key, default=None, cast=None):
    value = config.get(key, None)
    if value is None or (isinstance(value, str) and value.strip() == ""):
        return default
    return cast(value) if cast else value

#--------------------------- PARAMS ----------------------------#
ENV_PATH = config["nohic_env_path"]
shell.prefix(f"source {ENV_PATH}/bin/activate; ")
CTG = config["contigs"]
READS = opt("reads", "")
PLATFORM = str(opt("sequencing_platform", "hifi")).strip().lower()
REF = config["reference_genome"]
# Outputs
OUT_DIR = config["out_dir"]
PREFIX = config["out_prefix"]
# CRAQ
RUN_CRAQ = str(config["run_craq"]).strip().lower()
COV = opt("sequencing_coverage", 1, int)
CRAQ_THREADS = opt("craq_threads", 1, int)
IGNORE_HET = str(opt("ignore_het", "no")).strip().lower()
CRAQ_OUT_DIR = f"{OUT_DIR}/1_CRAQ"
# Inspector
RUN_INSPECTOR = str(config["run_inspector"]).strip().lower()
INSPECTOR_THREADS = opt("inspector_threads", 1, int)
INSPECTOR_OUT_DIR = f"{OUT_DIR}/2_Inspector"
# RagTag
RUN_RT_CORRECT = str(config["run_ragtag_correct"]).strip().lower()
RT_THREADS = int(config["ragtag_threads"])
PRESET = str(opt("preset", "luck")).strip().lower()
RT_CORR_OUT_DIR = f"{OUT_DIR}/3_RagTag_correct"
RT_SCF_OUT_DIR = f"{OUT_DIR}/4_Scaffolding"
# TGSGapcloser
RUN_GAP_CLOSE = str(config["run_gap_closing"]).strip().lower()
GAP_CLOSE_THREADS = opt("gap_closing_threads", 1, int)
GAP_CLOSE_OUT_DIR = f"{OUT_DIR}/5_Gap_closing"

#---------------------------- RULES ----------------------------#

rule all:
    input:
        f"{OUT_DIR}/pipeline.done"

# CRAQ-based contig correction
if RUN_CRAQ == "yes":
    # set minimum percentage of clipped reads
    if IGNORE_HET == "yes":
        CLIP_RATE = 0.55
    else:
        CLIP_RATE = 0.75
    # set sequencing platform
    if PLATFORM == "hifi":
        CRAQ_MAP = "map-hifi"
    elif PLATFORM == "clr" or PLATFORM == "corrected_clr":
        CRAQ_MAP = "map-pb"
    elif PLATFORM == "ont" or PLATFORM == "corrected_ont":
        CRAQ_MAP = "map-ont"
    else:
        raise WorkflowError("ERROR: Invalid sequencing platform. Please put in clr, hifi, ont, corrected_clr, or corrected_ont!")

    rule chimeric_contig_breaking:
        input:
            contig_file=CTG,
            read_file=READS
        params:
            craq_map=CRAQ_MAP,
            craq_out_dir=CRAQ_OUT_DIR,
            clip_rate=CLIP_RATE,
            coverage=COV
        threads: CRAQ_THREADS
        output:
            craq_ctgs_unnamed=f"{CRAQ_OUT_DIR}/runAQI_out/out_correct.fa",
            craq_done=touch(f"{CRAQ_OUT_DIR}/craq.done")
        log:
            f"{CRAQ_OUT_DIR}/CRAQ_based_contig_correction.log"
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
            craq --genome {input.contig_file} --sms_input {input.read_file} --break T --map {params.craq_map} --output_dir {params.craq_out_dir} \
                --sms_clip_coverRate {params.clip_rate} --sms_coverage {params.coverage} --thread {threads}
            ) &>> "$tmp_log"
            """
    rule rename_craq_contigs:
        input:
            craq_done=f"{CRAQ_OUT_DIR}/craq.done",
            craq_ctgs_unnamed=f"{CRAQ_OUT_DIR}/runAQI_out/out_correct.fa"
        output:
            craq_ctgs=f"{CRAQ_OUT_DIR}/{PREFIX}.craq.fa"
        shell:
            r"""
            set -euo pipefail
            mv {input.craq_ctgs_unnamed} {output.craq_ctgs}
            """
elif RUN_CRAQ == "no":
    print("CRAQ skipped")
    rule craq_skipped:
        output:
            craq_done=touch(f"{CRAQ_OUT_DIR}/craq.done")
else:
    raise WorkflowError("ERROR: Please set the value of run_craq to either 'yes' or 'no'!")

# Inspector-based contig correction
if RUN_INSPECTOR == "yes":
    # set input contigs
    if RUN_CRAQ == "yes":
        INSPECTOR_INPUT_CTG=f"{CRAQ_OUT_DIR}/{PREFIX}.craq.fa"
        INSPECTOR_OUTPUT_PREFIX=f"{PREFIX}.craq.inspector"
    else:
        INSPECTOR_INPUT_CTG=CTG
        INSPECTOR_OUTPUT_PREFIX=f"{PREFIX}.inspector"
    # set sequencing platform
    if PLATFORM == "hifi":
        INSPECTOR_DATATYPE="hifi"
        INSPECTOR_CORR_DATATYPE="pacbio-hifi"
    elif PLATFORM == "clr":
        INSPECTOR_DATATYPE="clr"
        INSPECTOR_CORR_DATATYPE="pacbio-raw"
    elif PLATFORM == "ont":
        INSPECTOR_DATATYPE="nanopore"
        INSPECTOR_CORR_DATATYPE="nano-raw"
    elif PLATFORM == "corrected_clr":
        INSPECTOR_DATATYPE="clr"
        INSPECTOR_CORR_DATATYPE="pacbio-corr"
    elif PLATFORM == "corrected_ont":
        INSPECTOR_DATATYPE="nanopore"
        INSPECTOR_CORR_DATATYPE="nano-corr"
    else:
        raise WorkflowError("ERROR: Invalid sequencing platform. Please put in clr, hifi, ont, corrected_clr, or corrected_ont!")

    rule inspector:
        input:
            craq_done=f"{CRAQ_OUT_DIR}/craq.done",
            contig_file=INSPECTOR_INPUT_CTG,
            read_file=READS
        params:
            inspector_out_dir=INSPECTOR_OUT_DIR,
            datatype=INSPECTOR_DATATYPE
        threads: INSPECTOR_THREADS
        output:
            inspector_done=touch(f"{INSPECTOR_OUT_DIR}/inspector.done")
        log:
            f"{INSPECTOR_OUT_DIR}/Inspector_based_misassembly_identification.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Running Inspector..."
            echo "Inspector command:"
            set -x
            inspector.py -c {input.contig_file} -r {input.read_file} -o {params.inspector_out_dir} \
                         -t {threads} --datatype {params.datatype} --min_contig_length 1000
            ) &>> {log}
            """
    rule inspector_correct:
        input:
            inspector_done=f"{INSPECTOR_OUT_DIR}/inspector.done"
        params:
            datatype=INSPECTOR_CORR_DATATYPE,
            inspector_out_dir=INSPECTOR_OUT_DIR
        threads: INSPECTOR_THREADS
        output:
            inspector_ctgs_unnamed=f"{INSPECTOR_OUT_DIR}/contig_corrected.fa",
            inspector_correct_done=touch(f"{INSPECTOR_OUT_DIR}/inspector_correct.done")
        log:
            f"{INSPECTOR_OUT_DIR}/Inspector_based_contig_correction.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Running Inspector correct..."
            echo "Inspector correct command:"
            set -x
            inspector-correct.py -i {params.inspector_out_dir} --datatype {params.datatype} -t {threads} -o {params.inspector_out_dir}
            ) &>> {log}
            """
    rule rename_inspector_contigs:
        input:
            inspector_correct_done=f"{INSPECTOR_OUT_DIR}/inspector_correct.done",
            inspector_ctgs_unnamed=f"{INSPECTOR_OUT_DIR}/contig_corrected.fa"
        output:
            inspector_output_ctgs=f"{INSPECTOR_OUT_DIR}/{INSPECTOR_OUTPUT_PREFIX}.fa"
        shell:
            r"""
            set -euo pipefail
            mv {input.inspector_ctgs_unnamed} {output.inspector_output_ctgs}
            """
elif RUN_INSPECTOR == "no":
    print("Inspector skipped")
    rule inspector_skipped:
        output:
            inspector_done=touch(f"{INSPECTOR_OUT_DIR}/inspector.done"),
            inspector_correct_done=touch(f"{INSPECTOR_OUT_DIR}/inspector_correct.done")
else:
    raise WorkflowError("ERROR: Please set the value of run_inspector to either 'yes' or 'no'!")

# RagTag reference-guided contig correction
if RUN_RT_CORRECT == "yes":
    # set input contigs
    if RUN_CRAQ == "no" and RUN_INSPECTOR == "no":
        RT_CORR_INPUT_CTG = CTG
        RT_CORR_OUTPUT_PREFIX = f"{PREFIX}.rt_corr"
    elif RUN_CRAQ == "yes" and RUN_INSPECTOR == "no":
        RT_CORR_INPUT_CTG = f"{CRAQ_OUT_DIR}/{PREFIX}.craq.fa"
        RT_CORR_OUTPUT_PREFIX = f"{PREFIX}.craq.rt_corr"
    else:
        RT_CORR_INPUT_CTG = f"{INSPECTOR_OUT_DIR}/{INSPECTOR_OUTPUT_PREFIX}.fa"
        RT_CORR_OUTPUT_PREFIX = f"{INSPECTOR_OUTPUT_PREFIX}.rt_corr"
    # set sequencing platform
    if PLATFORM == "hifi" or PLATFORM == "corrected_clr" or PLATFORM == "corrected_ont":
        RT_READ_TYPE="corr"
    elif PLATFORM == "ont":
        RT_READ_TYPE="ont"
    else:
        raise WorkflowError("ERROR: Invalid sequencing platform for RagTag correct. Please put in hifi, ont, corrected_clr, or corrected_ont!")
    # set correction preset
    RT_CORR_READ_PARAMS=f"-R {READS} -T {RT_READ_TYPE}"
    if PRESET == "draft":
        RT_CORR_PRESET = ""
    elif PRESET == "luck":
        RT_CORR_PRESET = "-v 45000 --remove-small"
    elif PRESET == "standard":
        RT_CORR_PRESET = f"--aligner nucmer --nucmer-params '--maxmatch -l 100 -c 500 -t {RT_THREADS}' -v 45000 --remove-small"
    elif PRESET == "aggressive":
        RT_CORR_PRESET = f"--aligner nucmer --nucmer-params '--maxmatch -l 100 -c 500 -t {RT_THREADS}' -v 45000 --remove-small -d 50000"
    elif PRESET == "raw":
        RT_CORR_READ_PARAMS = ""
        RT_CORR_PRESET = f"--aligner nucmer --nucmer-params '--maxmatch -l 100 -c 500 -t {RT_THREADS}'"
    else:
        raise WorkflowError("ERROR: Invalid preset. Please put in draft, luck, standard, aggressive, or raw!")
    # RagTag correct
    rule RagTag_correct:
        input:
            craq_done=f"{CRAQ_OUT_DIR}/craq.done",
            inspector_correct_done=f"{INSPECTOR_OUT_DIR}/inspector_correct.done",
            ref_genome=REF,
            contig_file=RT_CORR_INPUT_CTG
        params:
            rt_out_dir=RT_CORR_OUT_DIR,
            read_params=RT_CORR_READ_PARAMS,
            rt_preset=RT_CORR_PRESET
        threads: RT_THREADS
        output:
            rt_corr_ctgs_unnamed=f"{RT_CORR_OUT_DIR}/ragtag.correct.fasta",
            rt_corr_done=touch(f"{RT_CORR_OUT_DIR}/RagTag_correct.done")
        log:
            f"{RT_CORR_OUT_DIR}/RagTag_based_contig_correction.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Running RagTag correct..."
            echo "RagTag correct command:"
            set -x
            ragtag.py correct {input.ref_genome} {input.contig_file} -o {params.rt_out_dir} -t {threads} {params.rt_preset} {params.read_params}
            ) &>> {log}
            """
    rule rename_rt_corr_contigs:
        input:
            rt_corr_done=f"{RT_CORR_OUT_DIR}/RagTag_correct.done",
            rt_corr_ctgs_unnamed=f"{RT_CORR_OUT_DIR}/ragtag.correct.fasta"
        output:
            rt_corr_ctgs=f"{RT_CORR_OUT_DIR}/{RT_CORR_OUTPUT_PREFIX}.fa"
        shell:
            r"""
            set -euo pipefail
            mv {input.rt_corr_ctgs_unnamed} {output.rt_corr_ctgs}
            """
elif RUN_RT_CORRECT == "no":
    print("RagTag correct skipped")
    rule ragtag_correct_skipped:
        output:
            rt_corr_done=touch(f"{RT_CORR_OUT_DIR}/RagTag_correct.done")
else:
    raise WorkflowError("ERROR: Please set the value of run_ragtag_correct to either 'yes' or 'no'!")

# Settings for RagTag scaffold

if RUN_CRAQ == "no" and RUN_INSPECTOR == "no" and RUN_RT_CORRECT == "no":
    RT_SCF_INPUT_CTG = CTG
    RT_SCF_OUTPUT_PREFIX = f"{PREFIX}.scf"
elif RUN_CRAQ == "yes" and RUN_INSPECTOR == "no" and RUN_RT_CORRECT == "no":
    RT_SCF_INPUT_CTG = f"{CRAQ_OUT_DIR}/{PREFIX}.craq.fa"
    RT_SCF_OUTPUT_PREFIX = f"{PREFIX}.craq.scf"
elif RUN_INSPECTOR == "yes" and RUN_RT_CORRECT == "no":
    RT_SCF_INPUT_CTG = f"{INSPECTOR_OUT_DIR}/{INSPECTOR_OUTPUT_PREFIX}.fa"
    RT_SCF_OUTPUT_PREFIX = f"{INSPECTOR_OUTPUT_PREFIX}.scf"
else:
    RT_SCF_INPUT_CTG = f"{RT_CORR_OUT_DIR}/{RT_CORR_OUTPUT_PREFIX}.fa"
    RT_SCF_OUTPUT_PREFIX = f"{RT_CORR_OUTPUT_PREFIX}.scf"

rule Scaffolding:
    input:
        craq_done=f"{CRAQ_OUT_DIR}/craq.done",
        inspector_correct_done=f"{INSPECTOR_OUT_DIR}/inspector_correct.done",
        rt_corr_done=f"{RT_CORR_OUT_DIR}/RagTag_correct.done",
        contig_file=RT_SCF_INPUT_CTG,
        ref_genome=REF
    params:
        scf_out_dir=RT_SCF_OUT_DIR
    threads: RT_THREADS
    output:
        scf_unnamed=f"{RT_SCF_OUT_DIR}/ragtag.scaffold.fasta",
        scf_done=touch(f"{RT_SCF_OUT_DIR}/RagTag_scaffold.done")
    log:
        f"{RT_SCF_OUT_DIR}/Scaffolding.log"
    shell:
        r"""
        set -euo pipefail
        (
        echo "Running RagTag scaffold..."
        echo "RagTag scaffold command:"
        set -x
        ragtag.py scaffold {input.ref_genome} {input.contig_file} -o {params.scf_out_dir} -t {threads} -C -r -g 2
        ) &>> {log}
        """
rule rename_scaffolds:
    input:
        scf_done=f"{RT_SCF_OUT_DIR}/RagTag_scaffold.done",
        scf_unnamed=f"{RT_SCF_OUT_DIR}/ragtag.scaffold.fasta"
    output:
        scf=f"{RT_SCF_OUT_DIR}/{RT_SCF_OUTPUT_PREFIX}.fa"
    shell:
        r"""
        set -euo pipefail
        sed '/^>/ s/#/_/g' {input.scf_unnamed} > {output.scf}
        """

# Gap closing
if RUN_GAP_CLOSE == "yes":
    # set sequencing platform
    if PLATFORM == "hifi" or PLATFORM == "clr" or PLATFORM == "corrected_clr":
        TGS_TYPE="pb"
    elif PLATFORM == "ont" or PLATFORM == "corrected_ont":
        TGS_TYPE="ont"
    else:
        raise WorkflowError("ERROR: Invalid sequencing platform. Please put in clr, hifi, ont, corrected_clr, or corrected_ont!")
    # set output prefix
    TGS_PREFIX=f"{RT_SCF_OUTPUT_PREFIX}.tgs"
    # final assembly of this pipeline
    FINAL_ASM=f"{GAP_CLOSE_OUT_DIR}/{TGS_PREFIX}.fa"
    # run TGSGapcloser
    rule fastq_to_fasta:
        input:
            scf_done=f"{RT_SCF_OUT_DIR}/RagTag_scaffold.done",
            read_file=READS
        threads: GAP_CLOSE_THREADS
        output:
            read_file_fasta=temp(f"{GAP_CLOSE_OUT_DIR}/reads.fa")
        shell:
            r"""
            set -euo pipefail
            seqkit fq2fa -j {threads} {input.read_file} -o {output.read_file_fasta}
            """
    rule gap_closing:
        input:
            scf=f"{RT_SCF_OUT_DIR}/{RT_SCF_OUTPUT_PREFIX}.fa",
            read_file_fasta=f"{GAP_CLOSE_OUT_DIR}/reads.fa"
        threads: GAP_CLOSE_THREADS
        params:
            tgs_out_prefix=TGS_PREFIX,
            tgs_type=TGS_TYPE,
            tgs_out_dir=GAP_CLOSE_OUT_DIR
        output:
            gap_closed_scf_unnamed=f"{GAP_CLOSE_OUT_DIR}/{TGS_PREFIX}.scaff_seqs",
            tgs_done=touch(f"{GAP_CLOSE_OUT_DIR}/TGSGapcloser.done")
        log:
            f"{GAP_CLOSE_OUT_DIR}/Gap_closing.log"
        shell:
            # TGSGapcloser writes into the working directory, so every path handed to it
            # (the log included) has to be resolved before changing into the output one.
            r"""
            set -euo pipefail
            scf_abs=$(realpath {input.scf})
            reads_abs=$(realpath {input.read_file_fasta})
            log_abs=$(realpath {log})
            cd {params.tgs_out_dir}
            (
            echo "Running TGSGapcloser..."
            echo "TGSGapcloser command:"
            set -x
            tgsgapcloser --scaff $scf_abs --reads $reads_abs --output {params.tgs_out_prefix} --minmap_arg "-x asm5 -t {threads}" \
                         --ne --tgstype {params.tgs_type} --thread {threads}
            ) &>> "$log_abs"
            """
    rule rename_gap_closed_scaffold:
        input:
            tgs_done=f"{GAP_CLOSE_OUT_DIR}/TGSGapcloser.done",
            gap_closed_scf_unnamed=f"{GAP_CLOSE_OUT_DIR}/{TGS_PREFIX}.scaff_seqs"
        output:
            gap_closed_scf=f"{GAP_CLOSE_OUT_DIR}/{TGS_PREFIX}.fa"
        shell:
            r"""
            set -euo pipefail
            mv {input.gap_closed_scf_unnamed} {output.gap_closed_scf}
            """
elif RUN_GAP_CLOSE == "no":
    print("Gap closing skipped")
    # final assembly of this pipeline
    FINAL_ASM=f"{RT_SCF_OUT_DIR}/{RT_SCF_OUTPUT_PREFIX}.fa"
    rule gap_closing_skipped:
        output:
            tgs_done=touch(f"{GAP_CLOSE_OUT_DIR}/TGSGapcloser.done")
else:
    raise WorkflowError("ERROR: Please set the value of run_gap_closing to either 'yes' or 'no'!")

# Finishing the pipeline
rule pipeline_done:
    input:
        craq_done=f"{CRAQ_OUT_DIR}/craq.done",
        inspector_correct_done=f"{INSPECTOR_OUT_DIR}/inspector_correct.done",
        inspector_done=f"{INSPECTOR_OUT_DIR}/inspector.done",
        rt_corr_done=f"{RT_CORR_OUT_DIR}/RagTag_correct.done",
        scf_done=f"{RT_SCF_OUT_DIR}/RagTag_scaffold.done",
        tgs_done=f"{GAP_CLOSE_OUT_DIR}/TGSGapcloser.done",
        final_asm=FINAL_ASM
    output:
        pipeline_done=touch(f"{OUT_DIR}/pipeline.done")
