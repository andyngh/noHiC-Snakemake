#! /bin/bash

# Create directories for the required environments
mkdir -p $PWD/workflow/envs/noHiC
mkdir -p $PWD/workflow/envs/compleasm

# Download the environments
wget https://zenodo.org/records/22880706/files/noHiC.tar.gz
wget https://zenodo.org/records/22880706/files/compleasm.tar.gz

# Decompress the environments
echo "Decompressing the downloaded environments..."
tar -xzf noHiC.tar.gz -C $PWD/workflow/envs/noHiC
tar -xzf compleasm.tar.gz -C $PWD/workflow/envs/compleasm

# Unpack the environments
echo "Unpacking the environments..."
source $PWD/workflow/envs/noHiC/bin/activate
conda-unpack
source $PWD/workflow/envs/noHiC/bin/deactivate
source $PWD/workflow/envs/compleasm/bin/activate
conda-unpack
source $PWD/workflow/envs/compleasm/bin/deactivate

# Update the env path
echo "Update noHiC environment path."
sed -i "s|/path/to/envs/noHiC|${PWD}/workflow/envs/noHiC|" config/nohic.yaml
