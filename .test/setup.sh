#!/usr/bin/env bash
# Create the empty placeholder inputs that config/nohic.yaml in this directory points at.
# They only have to exist: the workflow is run with --dry-run, so nothing is ever read.
set -euo pipefail
cd "$(dirname "$0")"

touch reads.fastq.gz graph.gbz graph.hapl donor.fa contigs.fa adapters.fa organelles.fa
mkdir -p kraken2_db env/bin

echo "Placeholder inputs ready in $(pwd)"
