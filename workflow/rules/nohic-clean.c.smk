import os
import re

configfile: "nohic-clean.cfg.yaml"

def opt(key, default=None, cast=None):
    value = config.get(key, None)
    if value is None or (isinstance(value, str) and value.strip() == ""):
        return default
    return cast(value) if cast else value

#--------------------------- PARAMS ----------------------------#

CTG_ASM = config["contig_assembly"]
SAMPLE = re.sub(r"\.(fa|fasta|fna)$", "", os.path.basename(CTG_ASM)) # take only the assembly's name
OUT_DIR = config["out_dir"]
ENV_PATH = config["nohic_env_path"]
shell.prefix(f"source {ENV_PATH}/bin/activate; ")
# Adapter check
ADAPTERS = config["adapters"]
ADAPTER_THREADS = int(config["adapter_detection_thread"])
# Decontamination
KRAKEN2_DB = config["kraken2_db"]
KRAKEN2_THREADS = int(config["kraken2_thread"])
MEMORY_MAPPING = str(config["kraken2_memory_mapping"]).strip().lower()
TAXON_GROUP = config["taxonomic_group"]
# BLAST
RUN_BLAST = str(config["org_ctg_identification"]).strip().lower()
REF_MT_CP_DNA = opt("reference_organellar_sequences", "")
BLAST_THREADS = opt("blastn_thread", 1, int)
# helper scripts shipped next to this workflow, so that it can be run from any directory
#FILTER_BLAST = os.path.join(workflow.basedir, "filter_blast.py")

#---------------------------- RULES ----------------------------#

rule all:
    input:
        pure_ctg=f"{OUT_DIR}/4_assembly_decontamination/{SAMPLE}.pure.fa"

# Adapter check

rule adapter_prep:
    input:
        adapter=ADAPTERS
    output:
        adapter_no_header=f"{OUT_DIR}/1_adapter_check/adapter_seqs.txt"
    shell:
        r"""
        set -euo pipefail
        seqkit seq -w0 {input.adapter} | sed '/^>/d' \
        | sed '/^[[:space:]]*$/d' > {output.adapter_no_header}
        """

rule adapter_check:
    input:
        adapter=ADAPTERS,
        adapter_no_header=f"{OUT_DIR}/1_adapter_check/adapter_seqs.txt",
        ctg=CTG_ASM
    output:
        adapter_content=f"{OUT_DIR}/1_adapter_check/{SAMPLE}.adapter_match_number.txt",
        adapter_positions=f"{OUT_DIR}/1_adapter_check/{SAMPLE}.adapter_positions.bed"
    threads: ADAPTER_THREADS
    shell:
        # use seqkit to remove sequence wrapping (one line for header and one line for sequences).
        # use "|| [ $? -eq 1 ]" to only allow error caused by zero match (other errors will break the workflow)
        r"""
        set -euo pipefail
        seqkit seq -w0 {input.ctg} | \
        grep -c -f {input.adapter_no_header} > {output.adapter_content} || [ $? -eq 1 ]
        seqkit locate -f {input.adapter} -i -j {threads} --bed {input.ctg} > {output.adapter_positions}
        """

rule adapter_free:
    input:
        adapter_content=f"{OUT_DIR}/1_adapter_check/{SAMPLE}.adapter_match_number.txt",
        adapter_positions=f"{OUT_DIR}/1_adapter_check/{SAMPLE}.adapter_positions.bed"
    output:
        adapter_done=f"{OUT_DIR}/1_adapter_check/adapter.done"
    log:
        f"{OUT_DIR}/1_adapter_check/adapter_check.log"
    shell:
        r"""
        set -euo pipefail
        adapt_num=$(cat {input.adapter_content})
        if [ "$adapt_num" = "0" ] && [ ! -s {input.adapter_positions} ]; then
            echo "No adapter detected in your contigs!" >> {log}
            touch {output.adapter_done}
        else
            echo "ERROR: Your contigs contain adapters! Please remove the adapter before continue." >> {log}
            echo "ERROR: Your contigs contain adapters! See {log} and {input.adapter_positions} for details." >&2
            exit 1
        fi
        """

# Contaminant contig identification

rule kraken2:
    input:
        adapter_done=f"{OUT_DIR}/1_adapter_check/adapter.done",
        ctg=CTG_ASM,
        kr_db=KRAKEN2_DB
    params:
        memory_mapping=MEMORY_MAPPING
    output:
        kr_outfile=f"{OUT_DIR}/2_contamination_check/{SAMPLE}.kr",
        kr_report=f"{OUT_DIR}/2_contamination_check/{SAMPLE}.report"
    threads: KRAKEN2_THREADS
    log:
        f"{OUT_DIR}/2_contamination_check/Kraken.log"
    shell:
        r"""
        set -euo pipefail
        echo "Running Kraken2 using the provided database..." >> {log}
        mm={params.memory_mapping}
        if [ "$mm" = "yes" ]; then
            (
            echo "Kraken2's memory mapping mode: on"
            echo "Kraken2 command:"
            set -x
            kraken2 --memory-mapping --db {input.kr_db} --threads {threads} --output {output.kr_outfile} \
                --report {output.kr_report} {input.ctg}
            ) &>> {log}
        else
            (
            echo "Kraken2's memory mapping mode: off"
            echo "Kraken2 command:"
            set -x
            kraken2 --db {input.kr_db} --threads {threads} \
                --output {output.kr_outfile} --report {output.kr_report} {input.ctg}
            ) &>> {log}
        fi
        """
rule taxonkit_db:
    output:
        # this will create a marker file showing that taxonkit db has been downloaded
        touch("Resources/taxonkit_db.done")
    log:
        f"{OUT_DIR}/2_contamination_check/Taxonkit.log"
    shell:
        r"""
        set -euo pipefail
        mkdir -p "$HOME/.taxonkit/"
        mkdir -p "Resources"
        if [ -z "$(ls -A $HOME/.taxonkit/*.dmp 2>/dev/null)" ]; then
            echo "There is no .dmp file at $HOME/.taxonkit. Downloading taxonkit database..." >> {log}
            (
            set -x
            wget -c https://ftp.ncbi.nih.gov/pub/taxonomy/taxdump.tar.gz -O "Resources/taxdump.tar.gz"
            tar -xzf "Resources/taxdump.tar.gz" -C "Resources/"
            mv Resources/*.dmp "$HOME/.taxonkit/"
            ) &>> {log}
        else
            echo "Taxonkit database has already been setup!" >> {log}
        fi
        """

rule taxonkit:
    input:
        taxonkit_database="Resources/taxonkit_db.done",
        kr_outfile=f"{OUT_DIR}/2_contamination_check/{SAMPLE}.kr"
    output:
        taxon_lineage=f"{OUT_DIR}/2_contamination_check/{SAMPLE}.lineage"
    log:
        f"{OUT_DIR}/2_contamination_check/Taxonkit.log"
    shell:
        r"""
        set -euo pipefail
        echo "Running taxonkit lineage..." >> {log}
        cut -f3 {input.kr_outfile} | taxonkit lineage > {output.taxon_lineage} 2>> {log}
        """

rule contaminant_ctgs_identification:
    input:
        kr_outfile=f"{OUT_DIR}/2_contamination_check/{SAMPLE}.kr",
        taxon_lineage=f"{OUT_DIR}/2_contamination_check/{SAMPLE}.lineage"
    output:
        contamination_ctg_list=f"{OUT_DIR}/2_contamination_check/{SAMPLE}.contaminant_ctgs.txt"
    params:
        taxon_group=TAXON_GROUP
    shell:
        r"""
        set -euo pipefail
        paste {input.kr_outfile} {input.taxon_lineage} | cut -f 1,2,3,4,6,7 | \
            {{ grep -v -e "{params.taxon_group}" || [ $? -eq 1 ]; }} \
            | cut -f2 | sort | uniq > {output.contamination_ctg_list}
        """

# Organellar contig identification

if RUN_BLAST == "yes":
    if not REF_MT_CP_DNA:
        raise WorkflowError("ERROR: org_ctg_identification is 'yes' but 'reference_organellar_sequences' is empty in the config!")

    rule make_blast_db:
        input:
            ref_organellar_seq=REF_MT_CP_DNA
        output:
            blastdb_compl_marker=touch(f"{OUT_DIR}/3_organellar_DNA_check/blast_db.done")
        log:
            f"{OUT_DIR}/3_organellar_DNA_check/blast_db.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Making BLAST database..."
            echo "makeblastdb command:"
            set -x
            makeblastdb -in {input.ref_organellar_seq} -dbtype nucl -parse_seqids
            ) &>> {log}
            """

    rule organellar_blast:
        input:
            adapter_done=f"{OUT_DIR}/1_adapter_check/adapter.done",
            ref_organellar_seq=REF_MT_CP_DNA,
            ctg=CTG_ASM,
            blastdb_compl_marker=f"{OUT_DIR}/3_organellar_DNA_check/blast_db.done"
        output:
            blast_results=f"{OUT_DIR}/3_organellar_DNA_check/{SAMPLE}.blast.tsv"
        threads: BLAST_THREADS
        log:
            f"{OUT_DIR}/3_organellar_DNA_check/blast.log"
        shell:
            r"""
            set -euo pipefail
            (
            echo "Running BLASTn to detect contigs originating from organellar DNA..."
            echo "BLASTn command:"
            set -x
            blastn -query {input.ctg} -db {input.ref_organellar_seq} \
                -outfmt "6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore qcovs" \
                -num_threads {threads} -out {output.blast_results}
            ) &>> {log}
            """

    rule filter_blast_results:
        input:
            blast_results=f"{OUT_DIR}/3_organellar_DNA_check/{SAMPLE}.blast.tsv"
        output:
            blast_results_filtered=f"{OUT_DIR}/3_organellar_DNA_check/{SAMPLE}.blast.filtered.tsv"
        shell:
            r"""
            set -euo pipefail
            filter_blast.py {input.blast_results} > {output.blast_results_filtered}
            """

    rule list_org_ctgs:
        input:
            blast_results_filtered=f"{OUT_DIR}/3_organellar_DNA_check/{SAMPLE}.blast.filtered.tsv"
        output:
            org_ctg_names=f"{OUT_DIR}/3_organellar_DNA_check/{SAMPLE}.org_ctgs.txt"
        shell:
            r"""
            set -euo pipefail
            cut -f 1 {input.blast_results_filtered} | sort | uniq > {output.org_ctg_names}
            """
elif RUN_BLAST == "no":
    print("BLASTn skipped.")
    rule create_empty_blast_results:
        output:
            org_ctg_names=touch(f"{OUT_DIR}/3_organellar_DNA_check/{SAMPLE}.org_ctgs.txt")
else:
    raise WorkflowError("ERROR: please set the value of 'org_ctg_identification' to either yes or no!")

# Assembly decontamination

rule create_final_cont_ctg_list:
    input:
        org_ctg_names=f"{OUT_DIR}/3_organellar_DNA_check/{SAMPLE}.org_ctgs.txt",
        contamination_ctg_list=f"{OUT_DIR}/2_contamination_check/{SAMPLE}.contaminant_ctgs.txt"
    output:
        final_cont_ctgs=f"{OUT_DIR}/4_assembly_decontamination/{SAMPLE}.final_cont_ctg_names.txt"
    shell:
        r"""
        set -euo pipefail
        cat {input.contamination_ctg_list} {input.org_ctg_names} \
            | sort | uniq > {output.final_cont_ctgs}
        """

rule decontamination:
    input:
        final_cont_ctgs=f"{OUT_DIR}/4_assembly_decontamination/{SAMPLE}.final_cont_ctg_names.txt",
        ctg=CTG_ASM
    output:
        pure_ctg=f"{OUT_DIR}/4_assembly_decontamination/{SAMPLE}.pure.fa"
    log:
        f"{OUT_DIR}/4_assembly_decontamination/decontamination.log"
    shell:
        r"""
        set -euo pipefail
        (
        echo "Removing $(wc -l < {input.final_cont_ctgs}) contaminant contigs..."
        echo "seqkit command:"
        set -x
        seqkit grep -v -f {input.final_cont_ctgs} {input.ctg} > {output.pure_ctg}
        ) &>> {log}
        echo "All done!"
        """
