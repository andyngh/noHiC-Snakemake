configfile: "nohic-refpick.yaml"

def opt(key, default=None, cast=None):
    value = config.get(key, None)
    if value is None or (isinstance(value, str) and value.strip() == ""):
        return default
    return cast(value) if cast else value

#--------------------------- PARAMS ----------------------------#

ENV_PATH = config["nohic_env_path"]
shell.prefix(f"source {ENV_PATH}/bin/activate; ")

SEQ_FILE = config["seq_file"]
KMER_LEN = int(config["kmer_length"])
MEMORY = int(config["memory"])
KMC_MODE = str(config["kmc_mode"]).strip().lower()
OUT_DIR = config["kmc_out_dir"]
PREFIX = OUT_DIR + "/" + config["prefix"]
KMC_THREADS = int(config["kmc_threads"])
GBZ = config["gbz"]
HAPL = config["hapl"]
VG_THREADS = int(config["vg_threads"])
PATCH_SYNREF = str(config["patch_synref"]).strip().lower()

PATCH_THREADS = opt("patch_threads", 1, int)
DONOR = opt("donor_genome", "")

if PATCH_SYNREF == "yes":
    if not DONOR:
        raise WorkflowError("ERROR: patch_synref is 'yes' but 'donor_genome' is empty in the config!")
    FINAL_TARGET = f"{PREFIX}.synref.patched.fasta"
elif PATCH_SYNREF == "no":
    FINAL_TARGET = f"{PREFIX}.synref.fa"
else:
    raise WorkflowError("ERROR: Please set the value of patch_synref to either 'yes' or 'no'!")

#---------------------------- RULES ----------------------------#

rule all:
    input:
        FINAL_TARGET

if KMC_MODE == "fq" or KMC_MODE == "fm":
    rule kmer_counting:
        input:
            seq_file=SEQ_FILE
        params:
            kmer_len=KMER_LEN,
            memory=MEMORY,
            kmc_mode=KMC_MODE,
            prefix=PREFIX,
            out_dir=OUT_DIR
        threads: KMC_THREADS
        output:
            kmc_compl_marker=touch(f"{OUT_DIR}/kmc.done"),
            kff=f"{PREFIX}.kff"
        log:
            f"{OUT_DIR}/KMC3.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Counting k-mers..."
            echo "KMC command:"
            set -x
            kmc -k"{params.kmer_len}" -m"{params.memory}" -okff -t"{threads}" -hp "-{params.kmc_mode}" \
                "{input.seq_file}" "{params.prefix}" "{params.out_dir}"
            ) &>> {log}
            """
else:
    raise WorkflowError("ERROR: please set the value of kmc_mode to either fq or fm!")

rule haplotype_sampling:
    input:
        kmc_compl_marker=f"{OUT_DIR}/kmc.done",
        gbz=GBZ,
        hapl=HAPL,
        kff=f"{PREFIX}.kff"
    threads: VG_THREADS
    output:
        syn_gbz=f"{PREFIX}.gbz"
    log:
        f"{OUT_DIR}/vg_haplotype.log"
    shell:
        r"""
        set -euo pipefail
        (
        echo "Sampling haplotypes from the pangenome graph..."
        echo "VG Haplotype command:"
        set -x
        vg haplotypes -t {threads} --preset default --num-haplotypes 1 \
        -i {input.hapl} -k {input.kff} -g {output.syn_gbz} {input.gbz}
        ) &>> {log}
        """

rule synref_extracting:
    input:
        syn_gbz=f"{PREFIX}.gbz"
    threads: VG_THREADS
    output:
        synref=f"{PREFIX}.synref.fa"
    log:
        f"{OUT_DIR}/synref_extracting.log"
    shell:
        r"""
        set -euo pipefail
        (
        echo "Extracting the synthetic reference..."
        echo "VG paths command:"
        set -x
        vg paths -t {threads} --extract-fasta -x {input.syn_gbz} \
        --paths-by recombination > {output.synref}
        ) &>> {log}
        """

# ---- patching branch: only defined/executed when patch_synref == "yes" ----#

if PATCH_SYNREF == "yes":

    rule synref_decomposing:
        input:
            synref=f"{PREFIX}.synref.fa"
        output:
            synref_ctgs=f"{PREFIX}.synref.ctgs.fa"
        log:
            f"{OUT_DIR}/synref_patching.log"
        shell:
            r"""
            set -euo pipefail
            echo "Synref patching: on" >> {log}
            echo "Decomposing synref to contigs..." >> {log}
            Asm_Decomposing.sh {input.synref} {output.synref_ctgs} &>> {log}
            """

    rule synref_ctg_mapping:
        input:
            synref_ctgs=f"{PREFIX}.synref.ctgs.fa",
            donor_genome=DONOR
        threads: PATCH_THREADS
        output:
            synref_sam=temp(f"{PREFIX}.synref_mapping.sam")
        log:
            f"{OUT_DIR}/synref_patching.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Mapping synref contigs to the donor genome..."
            echo "minimap2 command:"
            set -x
            minimap2 -t {threads} -a -x asm10 {input.donor_genome} {input.synref_ctgs} > {output.synref_sam}
            ) &>> {log}
            """
    rule convert_sam_to_bam:
        input:
            synref_sam=f"{PREFIX}.synref_mapping.sam"
        threads: PATCH_THREADS
        output:
            synref_bam=temp(f"{PREFIX}.synref_mapping.bam")
        log:
            f"{OUT_DIR}/synref_patching.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Converting SAM to BAM..."
            echo "samtools command:"
            set -x
            samtools view -bS -@ {threads} {input.synref_sam} > {output.synref_bam}
            ) &>> {log}
            """

    rule synref_patching:
        input:
            synref_bam=f"{PREFIX}.synref_mapping.bam",
            donor_genome=DONOR
        params:
            gpatch_prefix=f"{PREFIX}.synref"
        output:
            patch_compl_marker=touch(f"{PREFIX}.synref.patch.done"),
            patched_synref=f"{PREFIX}.synref.patched.fasta"
        log:
            f"{OUT_DIR}/synref_patching.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Patching synref..."
            echo "GPatch command:"
            set -x
            GPatch -q {input.synref_bam} -r {input.donor_genome} -x {params.gpatch_prefix}
            ) &>> {log}
            """
